import Foundation
import Observation

/// 已安装 ref 的配置存储。只存「装了哪些 ref、当前选哪个」，不存任何用户数据：
/// 目录里的内容都是 ref 的清单和脚本，删掉后重新添加即可。
@MainActor
@Observable
public final class RefStore {
    public struct Pending: Sendable {
        public let manifest: RefManifest
        let entry: Data
    }

    public private(set) var installed: [RefManifest] = []
    public var currentID: String? {
        didSet { defaults.set(currentID, forKey: Self.currentKey) }
    }

    private static let currentKey = "refs.currentID"
    private let root: URL
    private let defaults: UserDefaults
    private let session: URLSession
    private var live: [String: any Ref] = [:]

    public init(
        root: URL = RefStore.defaultRoot,
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        self.root = root
        self.defaults = defaults
        self.session = session
        self.currentID = defaults.string(forKey: Self.currentKey)
        reload()
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cezzu-player/refs", isDirectory: true)
    }

    public var current: (any Ref)? {
        currentID.flatMap { ref(for: $0) }
    }

    public func ref(for id: String) -> (any Ref)? {
        if let existing = live[id] { return existing }
        guard installed.contains(where: { $0.id == id }),
            let manifest = try? Self.readManifest(at: directory(for: id)),
            let entry = try? Data(contentsOf: directory(for: id).appendingPathComponent(manifest.entry)),
            let ref = try? RefFactory.make(manifest: manifest, entry: entry, config: config(for: id))
        else { return nil }
        live[id] = ref
        return ref
    }

    // MARK: - 添加 / 删除

    /// 读取清单和脚本但不落盘。UI 拿 `Pending.manifest` 给用户确认域名和权限。
    /// `url` 可以是清单 JSON 的地址，也可以是包含 `manifest.json` 的本地目录。
    public func prepare(from url: URL) async throws -> Pending {
        var manifestURL = url
        if url.isFileURL, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            manifestURL = url.appendingPathComponent("manifest.json")
        }
        let manifestData = try await fetch(manifestURL)
        let manifest: RefManifest
        do {
            manifest = try JSONDecoder().decode(RefManifest.self, from: manifestData)
        } catch {
            throw RefError.invalidManifest("清单无法解析：\(error.localizedDescription)")
        }
        try manifest.validate()
        try Self.validateEntryPath(manifest.entry)

        let entryURL = manifestURL.deletingLastPathComponent().appendingPathComponent(manifest.entry)
        let entry = try await fetch(entryURL)
        // 提前构造一次，脚本语法错误在确认前就暴露，而不是装完才发现。
        _ = try RefFactory.make(manifest: manifest, entry: entry)
        return Pending(manifest: manifest, entry: entry)
    }

    /// `config` 是用户按清单声明填写的值。必填项缺失时拒绝安装，值只写进本机的 ref 目录。
    public func install(_ pending: Pending, config: [String: String] = [:]) throws {
        let manifest = pending.manifest
        try Self.validate(config: config, for: manifest)
        let directory = directory(for: manifest.id)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try pending.entry.write(to: directory.appendingPathComponent(manifest.entry), options: .atomic)
        try writeConfig(config, for: manifest, to: directory)
        live[manifest.id] = nil
        reload()
        if currentID == nil || !installed.contains(where: { $0.id == currentID }) {
            currentID = manifest.id
        }
    }

    /// 已保存的配置值（只含清单声明过的键）。
    public func config(for id: String) -> [String: String] {
        guard let data = try? Data(contentsOf: directory(for: id).appendingPathComponent(Self.configFile)),
            let values = try? JSONDecoder().decode([String: String].self, from: data),
            let manifest = installed.first(where: { $0.id == id })
        else { return [:] }
        let declared = Set(manifest.config.map(\.key))
        return values.filter { declared.contains($0.key) }
    }

    /// 修改已安装 ref 的配置。
    public func updateConfig(id: String, values: [String: String]) throws {
        guard let manifest = installed.first(where: { $0.id == id }) else { throw RefError.unknownRef(id) }
        try Self.validate(config: values, for: manifest)
        try writeConfig(values, for: manifest, to: directory(for: id))
        live[id] = nil
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: directory(for: id))
        live[id] = nil
        reload()
        if currentID == id { currentID = installed.first?.id }
    }

    // MARK: - 内部

    static let configFile = "config.json"

    static func validate(config: [String: String], for manifest: RefManifest) throws {
        for field in manifest.config where field.required {
            let value = config[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty { throw RefError.invalidManifest("缺少必填配置：\(field.label)") }
        }
    }

    /// 配置可能含密钥：只有本进程用户可读写，且只保存清单声明过的键。
    private func writeConfig(_ values: [String: String], for manifest: RefManifest, to directory: URL) throws {
        let url = directory.appendingPathComponent(Self.configFile)
        guard !manifest.config.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let declared = Set(manifest.config.map(\.key))
        let kept = values.filter { declared.contains($0.key) }
        try JSONEncoder().encode(kept).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func directory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        installed = dirs.compactMap { try? Self.readManifest(at: $0) }
            .filter { (try? $0.validate()) != nil }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        if let currentID, !installed.contains(where: { $0.id == currentID }) {
            self.currentID = installed.first?.id
        }
    }

    private static func readManifest(at directory: URL) throws -> RefManifest {
        try JSONDecoder().decode(
            RefManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    /// `entry` 只能是清单同级或其子目录下的相对路径。
    static func validateEntryPath(_ entry: String) throws {
        let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
        guard !entry.isEmpty, !entry.hasPrefix("/"), !parts.contains(".."), !entry.contains("://") else {
            throw RefError.invalidManifest("entry 必须是清单同级的相对路径")
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        if url.isFileURL {
            do { return try Data(contentsOf: url) } catch {
                throw RefError.invalidManifest("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RefError.invalidManifest("下载失败（HTTP \(http.statusCode)）：\(url.lastPathComponent)")
        }
        return data
    }
}

/// 清单 + 入口文件 → 可运行的 `Ref`。
public enum RefFactory {
    public static func make(manifest: RefManifest, entry: Data, config: [String: String] = [:]) throws -> any Ref {
        switch manifest.kind {
        case .script:
            guard let script = String(data: entry, encoding: .utf8) else {
                throw RefError.invalidManifest("脚本不是 UTF-8 文本")
            }
            return try JSRef(manifest: manifest, script: script, config: config)
        case .legacyRules:
            return try LegacyRuleRef(manifest: manifest, rules: LegacyRuleRef.decodeRules(from: entry))
        }
    }
}
