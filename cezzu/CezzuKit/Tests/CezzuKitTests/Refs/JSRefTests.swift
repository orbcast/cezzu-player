import Foundation
import Testing

@testable import CezzuKit

/// 用 URLProtocol 拦截 ref 沙箱发出的请求；域名一律用 example.invalid。
private final class MockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (404, "")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockProtocol.self]
    return URLSession(configuration: config)
}

private func manifest(
    hosts: [String] = ["example.invalid"],
    capabilities: [RefManifest.Capability] = []
) -> RefManifest {
    RefManifest(id: "demo", name: "Demo", version: "1", allowedHosts: hosts, capabilities: capabilities)
}

@Suite("JSRef sandbox", .serialized)
struct JSRefTests {
    @Test func searchUsesHttpAndHtmlHostAPIs() async throws {
        MockProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://example.invalid/s?q=abc")
            return (200, "<html><body><ul><li><a href='/v/1'>One</a></li><li><a href='/v/2'>Two</a></li></ul></body></html>")
        }
        let script = """
        async function search(keyword) {
          const res = await http.request({ url: "https://example.invalid/s", query: { q: keyword } });
          return html.parse(res.text).xpath("//li").map(function (li) {
            const a = li.xpath("//a")[0];
            return { id: a.attr("href"), title: a.text, group: "demo" };
          });
        }
        """
        let ref = try JSRef(manifest: manifest(), script: script, session: mockSession())
        let items = try await ref.search("abc")
        #expect(items.map(\.title) == ["One", "Two"])
        #expect(items.map(\.id) == ["/v/1", "/v/2"])
        #expect(items.first?.group == "demo")
    }

    @Test func cryptoMatchesKnownVectors() async throws {
        let script = """
        function search() {
          return [
            { id: crypto.hmacSHA256("key", "The quick brown fox jumps over the lazy dog"), title: "hmac" },
            { id: crypto.sha256("abc"), title: "sha256" },
            { id: crypto.md5("abc"), title: "md5" },
            { id: String(crypto.randomHex(8).length), title: "rand" },
            { id: crypto.base64Decode(crypto.base64Encode("héllo")), title: "b64" },
          ];
        }
        """
        let ref = try JSRef(manifest: manifest(capabilities: [.crypto]), script: script, session: mockSession())
        let byTitle = Dictionary(uniqueKeysWithValues: try await ref.search("").map { ($0.title, $0.id) })
        #expect(byTitle["hmac"] == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        #expect(byTitle["sha256"] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(byTitle["md5"] == "900150983cd24fb0d6963f7d28e17f72")
        #expect(byTitle["rand"] == "16")
        #expect(byTitle["b64"] == "héllo")
    }

    @Test func cryptoIsAbsentWithoutCapability() async throws {
        let script = "function search() { return [{ id: typeof crypto, title: 't' }]; }"
        let ref = try JSRef(manifest: manifest(), script: script, session: mockSession())
        #expect(try await ref.search("").first?.id == "undefined")
    }

    @Test func hostOutsideAllowListIsRejected() async throws {
        MockProtocol.handler = { _ in (200, "should not be reached") }
        let script = """
        async function search() {
          await http.request({ url: "https://other.invalid/" });
          return [];
        }
        """
        let ref = try JSRef(manifest: manifest(), script: script, session: mockSession())
        await #expect(throws: RefError.self) { try await ref.search("") }
    }

    @Test func sandboxExposesNoNodeOrFileGlobals() async throws {
        let script = """
        function search() {
          return [{ id: [typeof require, typeof process, typeof fetch, typeof XMLHttpRequest, typeof setTimeout].join(","), title: "g" }];
        }
        """
        let ref = try JSRef(manifest: manifest(), script: script, session: mockSession())
        #expect(try await ref.search("").first?.id == "undefined,undefined,undefined,undefined,undefined")
    }

    @Test func resolveDirectInfersKindAndExpiry() async throws {
        let script = """
        function resolve(id) {
          return { url: "https://example.invalid/" + id + ".m3u8", headers: { Referer: "https://example.invalid/" }, expiresAt: 1700000000000 };
        }
        """
        let ref = try JSRef(manifest: manifest(), script: script, session: mockSession())
        let media = try await ref.resolve(episodeID: "e1")
        guard case let .direct(url, kind, headers, expiresAt) = media else {
            Issue.record("expected direct")
            return
        }
        #expect(url.absoluteString == "https://example.invalid/e1.m3u8")
        #expect(kind == .hls)
        #expect(headers["Referer"] == "https://example.invalid/")
        #expect(expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func sniffRequiresCapabilityAndAllowedHost() async throws {
        let script = "function resolve() { return { sniff: 'https://example.invalid/play/1' }; }"

        let denied = try JSRef(manifest: manifest(), script: script, session: mockSession())
        await #expect(throws: RefError.capabilityNotDeclared("sniff")) {
            try await denied.resolve(episodeID: "x")
        }

        let allowed = try JSRef(manifest: manifest(capabilities: [.sniff]), script: script, session: mockSession())
        let media = try await allowed.resolve(episodeID: "x")
        #expect(media == .sniff(page: URL(string: "https://example.invalid/play/1")!, headers: [:], options: RefSniffOptions()))
    }

    @Test func missingFunctionAndScriptErrorsAreReported() async throws {
        let ref = try JSRef(manifest: manifest(), script: "function search() { throw new Error('boom'); }", session: mockSession())
        await #expect(throws: RefError.missingFunction("episodes")) { try await ref.episodes(id: "1") }
        await #expect(throws: RefError.self) { try await ref.search("") }
    }

    @Test func captchaErrorIsMapped() async throws {
        let ref = try JSRef(
            manifest: manifest(), script: "function search() { throw new Error('captchaRequired'); }",
            session: mockSession())
        await #expect(throws: RefError.captchaRequired) { try await ref.search("") }
    }

    @Test func callTimeoutReleasesCaller() async throws {
        let script = "function search() { return new Promise(function () {}); }"
        let ref = try JSRef(manifest: manifest(), script: script, session: mockSession(), callTimeout: .milliseconds(200))
        await #expect(throws: RefError.timeout) { try await ref.search("") }
    }

    @Test func manifestRejectsNewerAPIAndEmptyHosts() throws {
        #expect(throws: RefError.unsupportedAPI(required: 99, supported: 1)) {
            try RefManifest(refsApi: 99, id: "a", name: "a", version: "1", allowedHosts: ["x"]).validate()
        }
        #expect(throws: RefError.self) {
            try RefManifest(id: "a", name: "a", version: "1", allowedHosts: []).validate()
        }
        #expect(manifest(hosts: ["example.invalid"]).allows(host: "cdn.example.invalid"))
        #expect(!manifest(hosts: ["example.invalid"]).allows(host: "evilexample.invalid"))
    }

    @Test func optionalFunctionsReturnEmptyWhenAbsent() async throws {
        let ref = try JSRef(manifest: manifest(), script: "function search(){return []}", session: mockSession())
        #expect(try await ref.home().isEmpty)
        #expect(try await ref.browse(tag: "x", page: 1).isEmpty)
        #expect(try await ref.detail(id: "1") == nil)
    }

    @Test func optionalFunctionsDecodeRichItems() async throws {
        let script = """
        function search() { return []; }
        function home() { return [{ title: "热播", items: [{ id: "1", title: "A", rating: 8.5, tags: ["x"], heat: 3 }] }]; }
        function browse(args) { return [{ id: args.tag + args.page, title: "B" }]; }
        function detail(id) { return id === "none" ? null : { id: id, title: "D", summary: "S", totalEpisodes: 12 }; }
        """
        let ref = try JSRef(manifest: manifest(), script: script, session: mockSession())

        let sections = try await ref.home()
        #expect(sections.first?.title == "热播")
        #expect(sections.first?.items.first?.rating == 8.5)
        #expect(sections.first?.items.first?.heat == 3)
        #expect(try await ref.browse(tag: "anime", page: 2).first?.id == "anime2")
        #expect(try await ref.detail(id: "7")?.totalEpisodes == 12)
        #expect(try await ref.detail(id: "none") == nil)
    }
}

@Suite("JSRef config", .serialized)
struct JSRefConfigTests {
    private func manifest(_ fields: [RefManifest.ConfigField]) -> RefManifest {
        RefManifest(id: "demo", name: "Demo", version: "1", allowedHosts: ["example.invalid"], config: fields)
    }

    private func read(_ ref: JSRef) async throws -> String {
        try await ref.search("").first?.id ?? ""
    }

    @Test func scriptReadsDeclaredValues() async throws {
        let script = "function search() { return [{ id: config.secret + '|' + config.region, title: 't' }]; }"
        let ref = try JSRef(
            manifest: manifest([.init(key: "secret", secret: true), .init(key: "region", required: false)]),
            script: script, config: ["secret": "s3", "region": "eu"])
        #expect(try await read(ref) == "s3|eu")
    }

    @Test func undeclaredKeysAreNotExposed() async throws {
        let script = "function search() { return [{ id: String(config.other) + '|' + Object.keys(config).join(','), title: 't' }]; }"
        let ref = try JSRef(
            manifest: manifest([.init(key: "secret")]), script: script,
            config: ["secret": "s", "other": "leak"])
        #expect(try await read(ref) == "undefined|secret")
    }

    @Test func configIsReadOnly() async throws {
        let script = """
        function search() {
          try { config.secret = "changed"; } catch (e) {}
          try { delete config.secret; } catch (e) {}
          return [{ id: config.secret, title: 't' }];
        }
        """
        let ref = try JSRef(manifest: manifest([.init(key: "secret")]), script: script, config: ["secret": "orig"])
        #expect(try await read(ref) == "orig")
    }

    @Test func configExistsEvenWhenNothingIsDeclared() async throws {
        let script = "function search() { return [{ id: typeof config + ':' + Object.keys(config).length, title: 't' }]; }"
        let ref = try JSRef(manifest: manifest([]), script: script, config: ["x": "y"])
        #expect(try await read(ref) == "object:0")
    }

    @Test func manifestRejectsBadConfigKeys() {
        for bad in ["", "1abc", "a-b", "a b"] {
            #expect(throws: RefError.self) { try manifest([.init(key: bad)]).validate() }
        }
        #expect(throws: RefError.self) { try manifest([.init(key: "a"), .init(key: "a")]).validate() }
        #expect(throws: Never.self) { try manifest([.init(key: "client_name2")]).validate() }
    }

    @Test func manifestDecodesConfigDefaults() throws {
        let json = #"{"refsApi":1,"id":"d","name":"D","version":"1","allowedHosts":["x"],"config":[{"key":"k"},{"key":"s","secret":true,"required":false,"label":"S"}]}"#
        let m = try JSONDecoder().decode(RefManifest.self, from: Data(json.utf8))
        #expect(m.config[0] == .init(key: "k", label: "k", secret: false, required: true))
        #expect(m.config[1] == .init(key: "s", label: "S", secret: true, required: false))
    }
}
