import CryptoKit
import Foundation
@preconcurrency import JavaScriptCore

/// 跑在 JavaScriptCore 沙箱里的 ref。
///
/// 脚本里定义三个全局函数（可返回 Promise）：
/// `search(keyword)`、`episodes(id)`、`resolve(episodeID)`。
/// 脚本只能看到宿主 API：`http`、`html`、`crypto`（需声明）、`log`、`now`。
/// 没有文件、没有 DOM、没有任意网络。
///
/// 已知限制：JavaScriptCore 没有公开的 CPU / 内存上限接口，同步死循环无法中断，
/// 只能靠每次调用的超时把调用方放走，该 ref 的专用队列会被占住直到进程结束。
public final class JSRef: Ref, @unchecked Sendable {
    public let manifest: RefManifest

    private let queue: DispatchQueue
    private let context: JSContext
    private let host: RefHost
    private let callTimeout: Duration

    public init(
        manifest: RefManifest,
        script: String,
        config: [String: String] = [:],
        session: URLSession? = nil,
        callTimeout: Duration = .seconds(30)
    ) throws {
        try manifest.validate()
        self.manifest = manifest
        self.callTimeout = callTimeout
        self.queue = DispatchQueue(label: "cezzu.ref.\(manifest.id)")
        guard let context = JSContext() else {
            throw RefError.scriptError("无法创建 JSContext")
        }
        self.context = context
        self.host = RefHost(manifest: manifest, config: config, session: session)

        var loadError: RefError?
        queue.sync {
            let recorder = ExceptionRecorder()
            context.exceptionHandler = { _, exception in
                recorder.message = exception?.toString()
            }
            host.install(into: context, queue: queue)
            context.evaluateScript(script)
            if let message = recorder.message {
                loadError = .scriptError(message)
            }
        }
        if let loadError { throw loadError }
    }

    public func search(_ keyword: String) async throws -> [RefSearchItem] {
        let data = try await call("search", argument: keyword)
        return try decode([RefSearchItem].self, from: data, what: "search")
    }

    public func home() async throws -> [RefSection] {
        guard let data = try await call("home", argument: "", optional: true) else { return [] }
        return try decode([RefSection].self, from: data, what: "home")
    }

    public func browse(tag: String, page: Int) async throws -> [RefSearchItem] {
        guard let data = try await call("browse", argument: ["tag": tag, "page": page], optional: true) else { return [] }
        return try decode([RefSearchItem].self, from: data, what: "browse")
    }

    public func detail(id: String) async throws -> RefSearchItem? {
        guard let data = try await call("detail", argument: id, optional: true) else { return nil }
        return try decode(RefSearchItem?.self, from: data, what: "detail")
    }

    public func episodes(id: String) async throws -> [RefRoad] {
        let data = try await call("episodes", argument: id)
        return try decode([RefRoad].self, from: data, what: "episodes")
    }

    public func resolve(episodeID: String) async throws -> RefMedia {
        let data = try await call("resolve", argument: episodeID)
        let raw = try decode(RawMedia.self, from: data, what: "resolve")
        if let sniff = raw.sniff {
            guard manifest.capabilities.contains(.sniff) else {
                throw RefError.capabilityNotDeclared("sniff")
            }
            guard let page = URL(string: sniff), let host = page.host, manifest.allows(host: host) else {
                throw RefError.hostNotAllowed(sniff)
            }
            return .sniff(
                page: page,
                headers: raw.headers ?? [:],
                options: RefSniffOptions(
                    userAgent: raw.userAgent ?? "",
                    referer: raw.referer ?? "",
                    cookies: raw.cookies ?? "",
                    videoURLPattern: raw.videoURLPattern ?? ""))
        }
        guard let urlString = raw.url, let url = URL(string: urlString) else {
            throw RefError.invalidResult("resolve 必须返回 url 或 sniff")
        }
        let kind: RefMediaKind
        switch raw.kind?.lowercased() {
        case "hls", "m3u8": kind = .hls
        case "mp4": kind = .mp4
        default: kind = url.path.lowercased().hasSuffix(".m3u8") ? .hls : .mp4
        }
        return .direct(
            url: url,
            kind: kind,
            headers: raw.headers ?? [:],
            expiresAt: raw.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    // MARK: - 调用

    private struct RawMedia: Decodable {
        var url: String?
        var kind: String?
        var headers: [String: String]?
        var sniff: String?
        var userAgent: String?
        var referer: String?
        var cookies: String?
        var videoURLPattern: String?
        /// 毫秒时间戳。
        var expiresAt: Double?
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RefError.invalidResult("\(what) 返回值不符合协议：\(error.localizedDescription)")
        }
    }

    private func call(_ function: String, argument: Any) async throws -> Data {
        // 必选函数缺失会在 invoke 里抛 missingFunction，所以这里一定有值。
        try await call(function, argument: argument, optional: false)!
    }

    /// `optional` 为 true 且脚本没定义该函数（或返回 null）时得到 nil。
    private func call(_ function: String, argument: Any, optional: Bool) async throws -> Data? {
        let gate = ResumeOnce<Data?>()
        nonisolated(unsafe) let argument = argument
        let timeout = callTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                gate.install(continuation)
                Task {
                    try? await Task.sleep(for: timeout)
                    gate.fail(RefError.timeout)
                }
                queue.async { [self] in
                    invoke(function, argument: argument, optional: optional, gate: gate)
                }
            }
        } onCancel: {
            gate.fail(CancellationError())
        }
    }

    /// 必须在 `queue` 上调用。
    private func invoke(_ function: String, argument: Any, optional: Bool, gate: ResumeOnce<Data?>) {
        let recorder = ExceptionRecorder()
        context.exceptionHandler = { _, exception in
            recorder.message = exception?.toString()
        }

        guard let fn = context.objectForKeyedSubscript(function), fn.isObject,
            !(fn.isUndefined)
        else {
            if optional { gate.succeed(nil) } else { gate.fail(RefError.missingFunction(function)) }
            return
        }

        let outcome = fn.call(withArguments: [argument])
        if let message = recorder.message {
            gate.fail(Self.map(message))
            return
        }
        guard let outcome else {
            gate.fail(RefError.invalidResult("\(function) 没有返回值"))
            return
        }

        let finish: @convention(block) (JSValue) -> Void = { value in
            guard let json = self.context.objectForKeyedSubscript("__toJSON")?
                .call(withArguments: [value])?.toString(),
                json != "undefined"
            else {
                gate.fail(RefError.invalidResult("\(function) 返回了无法序列化的值"))
                return
            }
            gate.succeed(json == "null" && optional ? nil : Data(json.utf8))
        }
        let fail: @convention(block) (JSValue) -> Void = { error in
            let message = error.objectForKeyedSubscript("message")?.toString() ?? error.toString() ?? "unknown"
            gate.fail(Self.map(message))
        }

        let thenable = outcome.objectForKeyedSubscript("then")
        if let thenable, thenable.isObject {
            outcome.invokeMethod("then", withArguments: [
                unsafeBitCast(finish, to: AnyObject.self),
                unsafeBitCast(fail, to: AnyObject.self),
            ])
        } else {
            finish(outcome)
        }
    }

    private static func map(_ message: String) -> RefError {
        if message.contains("captchaRequired") { return .captchaRequired }
        if message.hasPrefix("Error: hostNotAllowed:") || message.contains("hostNotAllowed:") {
            return .hostNotAllowed(message)
        }
        return .scriptError(message)
    }
}

private final class ExceptionRecorder: @unchecked Sendable {
    var message: String?
}

/// 保证 continuation 只被恢复一次（成功 / 失败 / 超时 / 取消谁先到算谁）。
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingFailure: Error?
    private var done = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pendingFailure, !done {
            done = true
            lock.unlock()
            continuation.resume(throwing: pendingFailure)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func succeed(_ value: T) {
        resume { $0.resume(returning: value) }
    }

    func fail(_ error: Error) {
        lock.lock()
        if continuation == nil, !done {
            pendingFailure = error
            lock.unlock()
            return
        }
        lock.unlock()
        resume { $0.resume(throwing: error) }
    }

    private func resume(_ body: (CheckedContinuation<T, Error>) -> Void) {
        lock.lock()
        guard !done, let continuation else {
            lock.unlock()
            return
        }
        done = true
        self.continuation = nil
        lock.unlock()
        body(continuation)
    }
}
