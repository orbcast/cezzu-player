import Foundation
import Testing

@testable import CezzuKit

@Suite("Ref search declaration")
struct RefSearchTests {
    private func decode(_ searchJSON: String?) throws -> RefManifest {
        let search = searchJSON.map { ", \"search\": \($0)" } ?? ""
        let json = """
        { "refsApi": 1, "id": "demo", "name": "Demo", "version": "1",
          "allowedHosts": ["example.invalid"]\(search) }
        """
        return try JSONDecoder().decode(RefManifest.self, from: Data(json.utf8))
    }

    @Test("a manifest without `search` declares no sort and no filter")
    func absentMeansNone() throws {
        let manifest = try decode(nil)
        #expect(manifest.search.isEmpty)
        try manifest.validate()
    }

    @Test("sorts and filters decode, labels fall back to the id / value")
    func decodesDeclaration() throws {
        let manifest = try decode("""
        { "sorts": [{ "id": "hot", "label": "热度" }, { "id": "new" }],
          "filters": [{ "key": "year", "label": "年份",
                        "options": [{ "value": "2025", "label": "2025 年" }, { "value": "2024" }] }] }
        """)
        try manifest.validate()
        #expect(manifest.search.sorts.map(\.label) == ["热度", "new"])
        #expect(manifest.search.filters.first?.label == "年份")
        #expect(manifest.search.filters.first?.options.map(\.label) == ["2025 年", "2024"])
    }

    @Test("duplicate or empty ids are rejected instead of silently merged")
    func invalidDeclarationIsRejected() throws {
        let duplicateSort = try decode(#"{ "sorts": [{ "id": "a" }, { "id": "a" }] }"#)
        #expect(throws: RefError.self) { try duplicateSort.validate() }

        let duplicateKey = try decode("""
        { "filters": [{ "key": "k", "options": [{ "value": "1" }] },
                      { "key": "k", "options": [{ "value": "1" }] }] }
        """)
        #expect(throws: RefError.self) { try duplicateKey.validate() }

        let emptyOptions = try decode(#"{ "filters": [{ "key": "k", "options": [] }] }"#)
        #expect(throws: RefError.self) { try emptyOptions.validate() }

        let duplicateValue = try decode("""
        { "filters": [{ "key": "k", "options": [{ "value": "1" }, { "value": "1" }] }] }
        """)
        #expect(throws: RefError.self) { try duplicateValue.validate() }
    }

    @Test("a filter without options fails to decode")
    func missingOptionsFails() {
        #expect(throws: DecodingError.self) {
            _ = try self.decode(#"{ "filters": [{ "key": "k" }] }"#)
        }
    }

    @Test("the script receives { sort, filters } as the second argument")
    func scriptReceivesQuery() async throws {
        let script = """
        function search(keyword, query) {
          return [{ id: "1", title: keyword + "|" + query.sort + "|" + JSON.stringify(query.filters) }];
        }
        """
        let ref = try JSRef(
            manifest: RefManifest(id: "demo", name: "Demo", version: "1", allowedHosts: ["example.invalid"]),
            script: script)

        let items = try await ref.search("k", query: RefSearchQuery(sort: "hot", filters: ["year": "2025"]))
        #expect(items.first?.title == #"k|hot|{"year":"2025"}"#)

        let defaults = try await ref.search("k", query: .empty)
        #expect(defaults.first?.title == "k|null|{}", "没选排序就是 null，不是某个默认 id")
    }

    @Test("a script that only takes the keyword keeps working")
    func oldScriptIgnoresQuery() async throws {
        let ref = try JSRef(
            manifest: RefManifest(id: "demo", name: "Demo", version: "1", allowedHosts: ["example.invalid"]),
            script: #"function search(keyword) { return [{ id: "1", title: keyword }]; }"#)
        let items = try await ref.search("abc", query: RefSearchQuery(filters: ["x": "y"]))
        #expect(items.map(\.title) == ["abc"])
    }
}
