import CryptoKit
import Foundation
@preconcurrency import JavaScriptCore
import OSLog

/// 注入到 ref 沙箱里的宿主 API。所有块都在该 ref 的专用队列上被 JS 调用。
final class RefHost: @unchecked Sendable {
    private let manifest: RefManifest
    private let session: URLSession
    private let logger: Logger

    // 只在 ref 的专用队列上访问。
    private var documents: [Int: XPathHTMLDocument] = [:]
    private var nodes: [Int: XPathHTMLNode] = [:]
    private var nextHandle = 1

    private let config: [String: String]

    init(manifest: RefManifest, config: [String: String] = [:], session: URLSession?) {
        self.manifest = manifest
        // 只暴露清单里声明过的键：脚本拿不到没声明的东西。
        let declared = Set(manifest.config.map(\.key))
        self.config = config.filter { declared.contains($0.key) }
        self.logger = Logger(subsystem: "cezzu.ref", category: manifest.id)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 40
            config.httpCookieStorage = HTTPCookieStorage()
            self.session = URLSession(
                configuration: config,
                delegate: RedirectGuard(manifest: manifest),
                delegateQueue: nil
            )
        }
    }

    func install(into context: JSContext, queue: DispatchQueue) {
        installHTTP(into: context, queue: queue)
        installHTML(into: context)
        if manifest.capabilities.contains(.crypto) {
            installCrypto(into: context)
        }

        let log: @convention(block) (String) -> Void = { [logger] message in
            logger.debug("\(message, privacy: .private)")
        }
        context.setObject(log, forKeyedSubscript: "log" as NSString)

        let now: @convention(block) () -> Double = { Date().timeIntervalSince1970 * 1000 }
        context.setObject(now, forKeyedSubscript: "now" as NSString)

        context.evaluateScript(Self.shim)
        installConfig(into: context)
    }

    /// 只读的 `config` 全局对象：键来自清单声明，值来自用户填写。
    private func installConfig(into context: JSContext) {
        let json = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        context.setObject(json, forKeyedSubscript: "__config_json" as NSString)
        context.evaluateScript("""
        (function (g) {
          var values = JSON.parse(g.__config_json);
          delete g.__config_json;
          Object.defineProperty(g, "config", { value: Object.freeze(values) });
        })(this);
        """)
    }

    // MARK: - http

    private struct HTTPOptions: Decodable {
        var method: String?
        var url: String
        var headers: [String: String]?
        var query: [String: String]?
        var body: String?
    }

    private struct HTTPResult: Encodable {
        var status: Int
        var headers: [String: String]
        var text: String
    }

    private func installHTTP(into context: JSContext, queue: DispatchQueue) {
        let request: @convention(block) (String, JSValue) -> Void = { [self] optionsJSON, callback in
            func reply(error: String?, result: String?) {
                queue.async {
                    callback.call(withArguments: [error as Any? ?? NSNull(), result as Any? ?? NSNull()])
                }
            }
            guard let options = try? JSONDecoder().decode(HTTPOptions.self, from: Data(optionsJSON.utf8)),
                var components = URLComponents(string: options.url)
            else {
                reply(error: "invalid http options", result: nil)
                return
            }
            if let query = options.query, !query.isEmpty {
                var items = components.queryItems ?? []
                for key in query.keys.sorted() { items.append(URLQueryItem(name: key, value: query[key])) }
                components.queryItems = items
            }
            guard let url = components.url, let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https", let host = url.host
            else {
                reply(error: "invalid url", result: nil)
                return
            }
            guard manifest.allows(host: host) else {
                reply(error: "hostNotAllowed:\(host)", result: nil)
                return
            }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = (options.method ?? "GET").uppercased()
            for (key, value) in options.headers ?? [:] { urlRequest.setValue(value, forHTTPHeaderField: key) }
            if let body = options.body { urlRequest.httpBody = Data(body.utf8) }

            let session = self.session
            Task {
                do {
                    let (data, response) = try await session.data(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        reply(error: "non-http response", result: nil)
                        return
                    }
                    var headers: [String: String] = [:]
                    for (key, value) in http.allHeaderFields {
                        if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
                    }
                    let text = String(data: data, encoding: .utf8)
                        ?? String(decoding: data, as: UTF8.self)
                    let payload = HTTPResult(status: http.statusCode, headers: headers, text: text)
                    let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
                    reply(error: nil, result: json)
                } catch {
                    reply(error: error.localizedDescription, result: nil)
                }
            }
        }
        context.setObject(request, forKeyedSubscript: "__http" as NSString)
    }

    // MARK: - html

    private func installHTML(into context: JSContext) {
        let parse: @convention(block) (String) -> Int = { [self] text in
            guard let document = try? KannaXPathHTMLDocument(html: text) else { return -1 }
            if documents.count > 64 {
                documents.removeAll()
                nodes.removeAll()
            }
            let handle = nextHandle
            nextHandle += 1
            documents[handle] = document
            return handle
        }
        context.setObject(parse, forKeyedSubscript: "__html_parse" as NSString)

        // owner == -1 表示在文档根上求值，否则是某个节点句柄。
        let xpath: @convention(block) (Int, Int, String) -> [Int] = { [self] doc, owner, expression in
            let found: [XPathHTMLNode]
            if owner >= 0 {
                found = nodes[owner]?.xpath(expression) ?? []
            } else {
                found = documents[doc]?.xpath(expression) ?? []
            }
            return found.map { node in
                let handle = nextHandle
                nextHandle += 1
                nodes[handle] = node
                return handle
            }
        }
        context.setObject(xpath, forKeyedSubscript: "__html_xpath" as NSString)

        let text: @convention(block) (Int) -> String? = { [self] node in nodes[node]?.text }
        context.setObject(text, forKeyedSubscript: "__node_text" as NSString)

        let attribute: @convention(block) (Int, String) -> String? = { [self] node, name in nodes[node]?[name] }
        context.setObject(attribute, forKeyedSubscript: "__node_attr" as NSString)
    }

    // MARK: - crypto

    private func installCrypto(into context: JSContext) {
        let hmac: @convention(block) (String, String) -> String = { key, message in
            let code = HMAC<SHA256>.authenticationCode(
                for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))
            return Data(code).hex
        }
        let sha256: @convention(block) (String) -> String = { Data(SHA256.hash(data: Data($0.utf8))).hex }
        let md5: @convention(block) (String) -> String = { Data(Insecure.MD5.hash(data: Data($0.utf8))).hex }
        let randomHex: @convention(block) (Int) -> String = { count in
            var generator = SystemRandomNumberGenerator()
            return (0..<max(0, min(count, 1024))).map { _ in
                String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
            }.joined()
        }
        let b64e: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let b64d: @convention(block) (String) -> String? = { text in
            Data(base64Encoded: text).flatMap { String(data: $0, encoding: .utf8) }
        }
        context.setObject(hmac, forKeyedSubscript: "__hmacSHA256" as NSString)
        context.setObject(sha256, forKeyedSubscript: "__sha256" as NSString)
        context.setObject(md5, forKeyedSubscript: "__md5" as NSString)
        context.setObject(randomHex, forKeyedSubscript: "__randomHex" as NSString)
        context.setObject(b64e, forKeyedSubscript: "__b64e" as NSString)
        context.setObject(b64d, forKeyedSubscript: "__b64d" as NSString)
    }

    // MARK: - JS 侧外壳

    /// 把宿主原语包成对脚本友好的对象；`__` 前缀的原语随后被藏起来。
    private static let shim = """
    (function (g) {
      var http = Object.freeze({
        request: function (o) {
          return new Promise(function (resolve, reject) {
            g.__http(JSON.stringify(o), function (err, res) {
              if (err) reject(new Error(err)); else resolve(JSON.parse(res));
            });
          });
        }
      });
      function node(doc, id) {
        return {
          get text() { return g.__node_text(id); },
          attr: function (name) { return g.__node_attr(id, name); },
          xpath: function (e) { return g.__html_xpath(doc, id, e).map(function (n) { return node(doc, n); }); }
        };
      }
      var html = Object.freeze({
        parse: function (text) {
          var doc = g.__html_parse(text);
          if (doc < 0) throw new Error("html parse failed");
          return { xpath: function (e) { return g.__html_xpath(doc, -1, e).map(function (n) { return node(doc, n); }); } };
        }
      });
      var crypto = g.__hmacSHA256 ? Object.freeze({
        hmacSHA256: g.__hmacSHA256, sha256: g.__sha256, md5: g.__md5,
        randomHex: g.__randomHex, base64Encode: g.__b64e, base64Decode: g.__b64d
      }) : undefined;
      Object.defineProperty(g, "http", { value: http });
      Object.defineProperty(g, "html", { value: html });
      if (crypto) Object.defineProperty(g, "crypto", { value: crypto });
      Object.defineProperty(g, "__toJSON", { value: function (v) { return JSON.stringify(v); } });
      ["__http", "__html_parse", "__html_xpath", "__node_text", "__node_attr",
       "__hmacSHA256", "__sha256", "__md5", "__randomHex", "__b64e", "__b64d"].forEach(function (k) {
        if (k in g) { Object.defineProperty(g, k, { enumerable: false }); }
      });
    })(this);
    """
}

/// 重定向后的目标也必须落在 `allowedHosts` 内。
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let manifest: RefManifest

    init(manifest: RefManifest) {
        self.manifest = manifest
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let host = request.url?.host, manifest.allows(host: host) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

extension Sequence where Element == UInt8 {
    fileprivate var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
