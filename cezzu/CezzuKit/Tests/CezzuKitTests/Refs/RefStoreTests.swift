import Foundation
import Testing

@testable import CezzuKit

@MainActor
@Suite("RefStore", .serialized)
struct RefStoreTests {
    private func makeStore() throws -> (RefStore, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("installed")
        let source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return (RefStore(root: root, defaults: defaults), source, root)
    }

    private func writeRef(into dir: URL, id: String = "demo", entry: String = "main.js", script: String = "function search(){return []}") throws {
        let manifest = """
        {"refsApi":1,"id":"\(id)","name":"Demo","version":"1","entry":"\(entry)","allowedHosts":["example.invalid"]}
        """
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try script.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
    }

    @Test func prepareThenInstallPersistsAndSelects() async throws {
        let (store, source, root) = try makeStore()
        try writeRef(into: source)

        let pending = try await store.prepare(from: source)
        #expect(pending.manifest.id == "demo")
        #expect(store.installed.isEmpty, "prepare 不能落盘")

        try store.install(pending)
        #expect(store.installed.map(\.id) == ["demo"])
        #expect(store.currentID == "demo")
        #expect(store.current != nil)

        let reopened = RefStore(root: root, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(reopened.installed.map(\.id) == ["demo"])
    }

    @Test func removeFallsBackToRemainingRef() async throws {
        let (store, source, _) = try makeStore()
        try writeRef(into: source, id: "a")
        try store.install(try await store.prepare(from: source))
        try writeRef(into: source, id: "b")
        try store.install(try await store.prepare(from: source))
        store.currentID = "b"

        store.remove("b")
        #expect(store.installed.map(\.id) == ["a"])
        #expect(store.currentID == "a")
    }

    @Test func entryPathTraversalIsRejected() async throws {
        let (store, source, _) = try makeStore()
        try writeRef(into: source, entry: "../evil.js")
        await #expect(throws: RefError.self) { try await store.prepare(from: source) }
    }

    @Test func brokenScriptIsCaughtBeforeInstall() async throws {
        let (store, source, _) = try makeStore()
        try writeRef(into: source, script: "function search( {")
        await #expect(throws: RefError.self) { try await store.prepare(from: source) }
        #expect(store.installed.isEmpty)
    }

    @Test func legacyRuleSetLoadsThroughTheSameContract() async throws {
        let (store, source, _) = try makeStore()
        let manifest = #"{"refsApi":1,"kind":"legacy-rules","id":"rules","name":"Rules","version":"1","entry":"rules.json"}"#
        try manifest.write(to: source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "[]".write(to: source.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)

        let pending = try await store.prepare(from: source)
        try store.install(pending)
        #expect(store.current?.manifest.kind == .legacyRules)
    }
}

@Suite("RefURL")
struct RefURLTests {
    @Test func roundTripsArbitraryIDs() throws {
        for id in ["plain", "a/b?c=d&e#f", "中文 空格", "t1|L1", "resolve://ticket", ""] {
            let url = RefURL.make(refID: "my-ref_1", id: id)
            let parsed = try #require(RefURL.parse(url))
            #expect(parsed.refID == "my-ref_1")
            #expect(parsed.id == id)
        }
    }

    @Test func rejectsForeignURLs() {
        #expect(RefURL.parse(URL(string: "https://example.invalid/a/b")!) == nil)
        #expect(RefURL.parse(URL(string: "cezzu-ref:///only-one")!) == nil)
    }
}

@Suite("RefCatalogAPI", .serialized)
@MainActor
struct RefCatalogAPITests {
    private struct FakeRef: Ref {
        let manifest = RefManifest(id: "demo", name: "Demo", version: "1", allowedHosts: ["example.invalid"])
        func search(_ keyword: String) async throws -> [RefSearchItem] {
            [RefSearchItem(id: "s1", title: keyword, cover: "https://img.invalid/c.jpg")]
        }
        func episodes(id: String) async throws -> [RefRoad] { [] }
        func resolve(episodeID: String) async throws -> RefMedia { throw RefError.timeout }
        func home() async throws -> [RefSection] {
            [RefSection(title: "A", items: [RefSearchItem(id: "1", title: "x", rating: 7.5, tags: ["t"], totalEpisodes: 12),
                                            RefSearchItem(id: "2", title: "y")]),
             RefSection(title: "B", items: [RefSearchItem(id: "1", title: "x")])]
        }
        func detail(id: String) async throws -> RefSearchItem? { RefSearchItem(id: id, title: "full", summary: "S") }
    }

    private func makeStore() throws -> RefStore {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RefStore(root: base, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return store
    }

    @Test func noActiveRefIsAReadableError() async throws {
        let api = RefCatalogAPI(store: try makeStore())
        await #expect(throws: CatalogAPIError.noActiveRef) { try await api.trending(limit: 10, offset: 0) }
    }

    @Test func stableIDIsDeterministicAndPositive() {
        let a = RefCatalogAPI.stableID(refID: "demo", itemID: "1")
        #expect(a == RefCatalogAPI.stableID(refID: "demo", itemID: "1"))
        #expect(a != RefCatalogAPI.stableID(refID: "demo", itemID: "2"))
        #expect(a != RefCatalogAPI.stableID(refID: "other", itemID: "1"))
        #expect(a > 0)
    }

    @Test func errorsAreMappedToCatalogErrors() {
        #expect(CatalogAPIError.wrap(RefError.timeout) == .timeout)
        #expect(CatalogAPIError.wrap(CancellationError()) == .cancelled)
        #expect(CatalogAPIError.wrap(RefError.invalidResult("x")) == .decoding(message: "x"))
        #expect(CatalogAPIError.wrap(RefError.scriptError("未配置")) == .refFailed(message: "未配置"))
        #expect(CatalogAPIError.refFailed(message: "未配置").userMessage == "未配置")
        #expect(CatalogAPIError.noActiveRef.userMessage.contains("ref"))
    }
}

@MainActor
@Suite("RefStore config", .serialized)
struct RefStoreConfigTests {
    private func makeStore() throws -> (RefStore, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("installed")
        let source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return (RefStore(root: root, defaults: UserDefaults(suiteName: UUID().uuidString)!), source, root)
    }

    private func writeRef(into dir: URL) throws {
        let manifest = """
        {"refsApi":1,"id":"cfg","name":"Cfg","version":"1","allowedHosts":["example.invalid"],
         "config":[{"key":"secret","label":"密钥","secret":true},{"key":"note","required":false}]}
        """
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "function search(){ return [{ id: config.secret, title: 't' }]; }"
            .write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
    }

    @Test func missingRequiredConfigBlocksInstall() async throws {
        let (store, source, _) = try makeStore()
        try writeRef(into: source)
        let pending = try await store.prepare(from: source)

        #expect(throws: RefError.self) { try store.install(pending, config: [:]) }
        #expect(throws: RefError.self) { try store.install(pending, config: ["secret": "   "]) }
        #expect(store.installed.isEmpty, "校验失败不能留下半装的 ref")
    }

    @Test func installedConfigReachesTheScriptAndPersists() async throws {
        let (store, source, root) = try makeStore()
        try writeRef(into: source)
        try store.install(try await store.prepare(from: source), config: ["secret": "abc", "junk": "x"])

        #expect(try await store.current?.search("").first?.id == "abc")
        #expect(store.config(for: "cfg") == ["secret": "abc"], "只保存清单声明过的键")

        let reopened = RefStore(root: root, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(reopened.config(for: "cfg")["secret"] == "abc")
        #expect(try await reopened.ref(for: "cfg")?.search("").first?.id == "abc")
    }

    @Test func configFileIsOwnerOnly() async throws {
        let (store, source, root) = try makeStore()
        try writeRef(into: source)
        try store.install(try await store.prepare(from: source), config: ["secret": "abc"])

        let path = root.appendingPathComponent("cfg/config.json").path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func updateConfigValidatesAndTakesEffect() async throws {
        let (store, source, _) = try makeStore()
        try writeRef(into: source)
        try store.install(try await store.prepare(from: source), config: ["secret": "one"])
        #expect(try await store.current?.search("").first?.id == "one")

        #expect(throws: RefError.self) { try store.updateConfig(id: "cfg", values: ["secret": ""]) }
        #expect(store.config(for: "cfg")["secret"] == "one", "失败的修改不能破坏原值")

        try store.updateConfig(id: "cfg", values: ["secret": "two"])
        #expect(try await store.current?.search("").first?.id == "two", "改完要用新的值重建 ref")
        #expect(throws: RefError.self) { try store.updateConfig(id: "missing", values: [:]) }
    }

    @Test func removeDeletesTheConfigWithIt() async throws {
        let (store, source, root) = try makeStore()
        try writeRef(into: source)
        try store.install(try await store.prepare(from: source), config: ["secret": "abc"])
        store.remove("cfg")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cfg").path))
        #expect(store.config(for: "cfg").isEmpty)
    }
}
