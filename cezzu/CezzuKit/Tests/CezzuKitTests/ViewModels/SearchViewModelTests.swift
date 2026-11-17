import Testing
@testable import CezzuKit

@Suite("SearchViewModel")
@MainActor
struct SearchViewModelTests {

    private static func makeItem(id: Int, name: String) -> CatalogItem {
        CatalogItem(
            id: id,
            name: name,
            nameCn: name,
            summary: "",
            airDate: "",
            rank: 0,
            ratingScore: 0,
            images: .empty,
            tags: []
        )
    }

    private static let spec = RefSearchSpec(
        sorts: [.init(id: "hot", label: "热度"), .init(id: "new", label: "最新")],
        filters: [
            .init(key: "year", label: "年份", options: [.init(value: "2025"), .init(value: "2024")]),
            .init(key: "area", label: "地区", options: [.init(value: "cn", label: "大陆")]),
        ])

    @Test("submit searches Catalog with selected sort")
    func submitUsesSelectedSort() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .success([
            Self.makeItem(id: 1, name: "Frieren")
        ])
        let vm = SearchViewModel(api: api)
        vm.text = "芙莉莲"
        vm.selectedSort = "new"

        await vm.submit()

        #expect(vm.results.count == 1)
        #expect(vm.results[0].id == 1)
        #expect(vm.lastError == nil)
        #expect(api.keywordSearchCalls.count == 1)
        #expect(api.keywordSearchCalls[0].0 == "芙莉莲")
        #expect(api.keywordSearchCalls[0].1.sort == "new")
        #expect(api.keywordSearchCalls[0].2 == 0)
    }

    @Test("loadMoreIfNeeded appends the next Catalog search page")
    func loadMoreAppendsNextPage() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .success((1...20).map { Self.makeItem(id: $0, name: "Item \($0)") })
        let vm = SearchViewModel(api: api)
        vm.text = "机动战士"

        await vm.submit()

        api.keywordSearchResult = .success((21...24).map { Self.makeItem(id: $0, name: "Item \($0)") })
        await vm.loadMoreIfNeeded(currentItem: vm.results[19])

        #expect(vm.results.count == 24)
        #expect(vm.results.last?.id == 24)
        #expect(vm.hasMore == false)
        #expect(api.keywordSearchCalls.count == 2)
        #expect(api.keywordSearchCalls[1].2 == 20)
    }

    @Test("submit records the trimmed keyword to history on success")
    func submitRecordsHistoryOnSuccess() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .success([Self.makeItem(id: 1, name: "X")])
        let history = InMemorySearchHistoryStore()
        let vm = SearchViewModel(api: api, history: history)
        vm.text = "  海贼王  "

        await vm.submit()

        #expect(history.recent == ["海贼王"])
    }

    @Test("submit does not record history when the request fails")
    func submitSkipsHistoryOnFailure() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .failure(.timeout)
        let history = InMemorySearchHistoryStore()
        let vm = SearchViewModel(api: api, history: history)
        vm.text = "海贼王"

        await vm.submit()

        #expect(vm.lastError == .timeout)
        #expect(history.recent.isEmpty)
    }

    @Test("submit with only a filter searches with an empty keyword and writes no history")
    func submitWithOnlyFilterSkipsHistory() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.spec = Self.spec
        api.keywordSearchResult = .success([])
        let history = InMemorySearchHistoryStore()
        let vm = SearchViewModel(api: api, history: history)
        await vm.refreshSpec()
        vm.select("2025", forFilter: "year")
        await vm.waitForIdle()

        #expect(api.keywordSearchCalls.count == 1)
        #expect(api.keywordSearchCalls[0].0 == "")
        #expect(api.keywordSearchCalls[0].1.filters == ["year": "2025"])
        #expect(history.recent.isEmpty)
    }

    @Test("applyTag turns the tag into a keyword search and drops filters")
    func applyTagBecomesKeyword() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.spec = Self.spec
        api.keywordSearchResult = .success([])
        let vm = SearchViewModel(api: api, debounceMilliseconds: 5)
        await vm.refreshSpec()
        vm.select("2024", forFilter: "year")
        await vm.waitForIdle()

        vm.applyTag("  悬疑  ")
        await vm.submit()

        #expect(vm.text == "悬疑")
        #expect(vm.selections.isEmpty)
        #expect(api.keywordSearchCalls.last?.0 == "悬疑")
        #expect(api.keywordSearchCalls.last?.1.hasFilters == false)
    }

    @Test("textChanged debounces and triggers submit when keyword crosses min length")
    func textChangedDebouncesAndSubmits() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .success([Self.makeItem(id: 7, name: "X")])
        let vm = SearchViewModel(api: api, debounceMilliseconds: 5)

        vm.text = "海贼王"
        vm.textChanged()
        await vm.waitForIdle()

        #expect(api.keywordSearchCalls.count == 1)
        #expect(api.keywordSearchCalls[0].0 == "海贼王")
        #expect(vm.results.count == 1)
    }

    @Test("textChanged ignores keywords shorter than the minimum length")
    func textChangedIgnoresShortKeyword() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .success([Self.makeItem(id: 1, name: "X")])
        let vm = SearchViewModel(api: api, debounceMilliseconds: 5)

        vm.text = "X"
        vm.textChanged()
        await vm.waitForIdle()

        #expect(api.keywordSearchCalls.isEmpty)
    }

    @Test("rapid textChanged collapses to a single submit")
    func textChangedCollapsesRapidEdits() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .success([])
        let vm = SearchViewModel(api: api, debounceMilliseconds: 30)

        vm.text = "海贼"
        vm.textChanged()
        vm.text = "海贼王"
        vm.textChanged()
        vm.text = "海贼王女"
        vm.textChanged()
        await vm.waitForIdle()

        #expect(api.keywordSearchCalls.count == 1)
        #expect(api.keywordSearchCalls[0].0 == "海贼王女")
    }

    @Test("sortChanged re-submits when there is a prior search context")
    func sortChangedResearches() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .success([Self.makeItem(id: 1, name: "X")])
        let vm = SearchViewModel(api: api, debounceMilliseconds: 5)
        vm.text = "海贼王"

        await vm.submit()
        #expect(api.keywordSearchCalls.count == 1)

        vm.selectedSort = "new"
        vm.sortChanged()
        await vm.waitForIdle()

        #expect(api.keywordSearchCalls.count == 2)
        #expect(api.keywordSearchCalls[1].1.sort == "new")
    }

    @Test("sortChanged is a no-op before the first search")
    func sortChangedNoopBeforeFirstSearch() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .success([])
        let vm = SearchViewModel(api: api, debounceMilliseconds: 5)

        vm.selectedSort = "new"
        vm.sortChanged()
        await vm.waitForIdle()

        #expect(api.keywordSearchCalls.isEmpty)
    }

    @Test("applyHistory writes the keyword and submits immediately")
    func applyHistorySubmits() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .success([Self.makeItem(id: 1, name: "X")])
        let history = InMemorySearchHistoryStore(seed: ["海贼王"])
        let vm = SearchViewModel(api: api, history: history)

        await vm.applyHistory("海贼王")

        #expect(vm.text == "海贼王")
        #expect(api.keywordSearchCalls.count == 1)
        #expect(api.keywordSearchCalls[0].0 == "海贼王")
    }

    @Test("clearText empties the input and cancels pending debounce")
    func clearTextCancelsDebounce() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .success([])
        let vm = SearchViewModel(api: api, debounceMilliseconds: 50)

        vm.text = "海贼王"
        vm.textChanged()
        vm.clearText()
        await vm.waitForIdle()

        #expect(vm.text.isEmpty)
        #expect(api.keywordSearchCalls.isEmpty)
    }

    @Test("deleteHistory and clearHistory delegate to the store")
    func historyMutationsDelegate() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        let history = InMemorySearchHistoryStore(seed: ["海贼王", "鬼灭"])
        let vm = SearchViewModel(api: api, history: history)

        vm.deleteHistory("海贼王")
        #expect(vm.historyKeywords == ["鬼灭"])

        vm.clearHistory()
        #expect(vm.historyKeywords.isEmpty)
    }

    @Test("bindHistory switches store without resetting search text")
    func bindHistorySwitchesStore() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .success([Self.makeItem(id: 1, name: "X")])
        let emptyStore = InMemorySearchHistoryStore(seed: ["旧"])
        let persistentStore = InMemorySearchHistoryStore()
        let vm = SearchViewModel(api: api, history: emptyStore)
        vm.text = "海贼王"
        #expect(vm.historyKeywords == ["旧"])

        // 模拟 iOS Root：empty session → persistent session 后重绑
        vm.bindHistory(persistentStore)
        #expect(vm.historyKeywords.isEmpty)
        #expect(vm.text == "海贼王")

        await vm.submit()
        #expect(persistentStore.recent == ["海贼王"])
        #expect(emptyStore.recent == ["旧"])
    }

    @Test("a ref without declared search options shows none and sends an empty query")
    func noSpecMeansKeywordOnly() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.keywordSearchResult = .success([])
        let vm = SearchViewModel(api: api)
        await vm.refreshSpec()
        vm.text = "海贼王"

        await vm.submit()

        #expect(vm.spec.isEmpty)
        #expect(api.keywordSearchCalls[0].1 == .empty)
    }

    @Test("submit forwards the selected sort and filters to the ref")
    func submitForwardsQuery() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.spec = Self.spec
        api.keywordSearchResult = .success([])
        let vm = SearchViewModel(api: api)
        await vm.refreshSpec()
        vm.text = "海贼王"
        vm.selectedSort = "hot"
        vm.select("cn", forFilter: "area")
        await vm.waitForIdle()
        api.keywordSearchResult = .success([])

        await vm.submit()

        let query = api.keywordSearchCalls.last?.1
        #expect(query?.sort == "hot")
        #expect(query?.filters == ["area": "cn"])
    }

    @Test("select(nil) clears one group and re-runs the search")
    func clearingAFilterResearches() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.spec = Self.spec
        api.keywordSearchResult = .success([])
        let vm = SearchViewModel(api: api, debounceMilliseconds: 5)
        await vm.refreshSpec()
        vm.text = "海贼王"
        vm.select("2025", forFilter: "year")
        vm.select("cn", forFilter: "area")
        await vm.waitForIdle()
        let before = api.keywordSearchCalls.count

        vm.select(nil, forFilter: "year")
        await vm.waitForIdle()

        #expect(api.keywordSearchCalls.count == before + 1)
        #expect(api.keywordSearchCalls.last?.1.filters == ["area": "cn"])
    }

    @Test("resetFilters clears every group but keeps the sort")
    func resetFiltersKeepsSort() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.spec = Self.spec
        api.keywordSearchResult = .success([])
        let vm = SearchViewModel(api: api, debounceMilliseconds: 5)
        await vm.refreshSpec()
        vm.text = "海贼王"
        vm.selectedSort = "new"
        vm.select("2025", forFilter: "year")
        await vm.waitForIdle()

        vm.resetFilters()
        await vm.waitForIdle()

        #expect(vm.selections.isEmpty)
        #expect(vm.selectedSort == "new")
        #expect(api.keywordSearchCalls.last?.1 == RefSearchQuery(sort: "new"))
    }

    @Test("filterChanged is a no-op when nothing would be sent")
    func filterChangedNoopWithoutContext() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        let vm = SearchViewModel(api: api, debounceMilliseconds: 5)

        vm.filterChanged()
        await vm.waitForIdle()

        #expect(api.keywordSearchCalls.isEmpty)
    }

    @Test("textChanged triggers even when the keyword is short but a filter is active")
    func textChangedRespectsActiveFilter() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.spec = Self.spec
        api.keywordSearchResult = .success([])
        let vm = SearchViewModel(api: api, debounceMilliseconds: 5)
        await vm.refreshSpec()
        vm.select("2025", forFilter: "year")
        await vm.waitForIdle()
        let before = api.keywordSearchCalls.count

        vm.text = "X"
        vm.textChanged()
        await vm.waitForIdle()

        #expect(api.keywordSearchCalls.count == before + 1)
        #expect(api.keywordSearchCalls.last?.1.filters == ["year": "2025"])
    }

    @Test("switching ref drops selections the new ref does not declare")
    func refreshSpecPrunesStaleSelections() async {
        let api = HomeViewModelTests.FakeCatalogAPI()
        api.spec = Self.spec
        let vm = SearchViewModel(api: api)
        await vm.refreshSpec()
        vm.selectedSort = "new"
        vm.select("2025", forFilter: "year")
        vm.select("cn", forFilter: "area")

        api.spec = RefSearchSpec(
            sorts: [.init(id: "rank")],
            filters: [.init(key: "year", options: [.init(value: "2025")])])
        await vm.refreshSpec()

        #expect(vm.selections == ["year": "2025"], "地区这一组新 ref 没有，选择要丢掉；年份还在就保留")
        #expect(vm.selectedSort == nil, "旧的排序 id 新 ref 不认识")

        api.spec = .none
        await vm.refreshSpec()
        #expect(vm.selections.isEmpty)
    }

    /// 第一页会被补充通道插进额外条目，此时 `results.count` 不等于下一页的 offset。
    /// VM 必须用 page 带回来的游标，否则翻页会跳过若干条结果。
    @Test("paging follows the page cursor, not the rendered result count")
    func pagingUsesPageCursorNotResultCount() async {
        let api = PagingCursorAPI()
        let vm = SearchViewModel(api: api)
        vm.text = "受限条目"

        await vm.submit()
        // 21 条 = 20 条主结果 + 1 条补充通道插入的。
        #expect(vm.results.count == 21)
        #expect(vm.hasMore)

        await vm.loadMoreIfNeeded(currentItem: vm.results[20])
        #expect(api.offsets == [0, 20])
    }

    /// 第一页返回的条目数多于游标推进量，模拟补充通道的插入。
    private final class PagingCursorAPI: CatalogAPIClientProtocol, @unchecked Sendable {
        private(set) var offsets: [Int] = []

        static func item(id: Int, name: String) -> CatalogItem {
            CatalogItem(
                id: id, name: name, nameCn: name, summary: "", airDate: "",
                rank: 0, ratingScore: 0, images: .empty, tags: []
            )
        }

        func searchPage(
            keyword: String,
            query: RefSearchQuery,
            limit: Int,
            offset: Int
        ) async throws -> CatalogSearchPage {
            offsets.append(offset)
            let promoted = offset == 0 ? [Self.item(id: 999, name: "受限条目")] : []
            let regular = (1...limit).map { Self.item(id: offset + $0, name: "Item \($0)") }
            return CatalogSearchPage(
                items: promoted + regular,
                nextOffset: offset + regular.count,
                hasMore: true
            )
        }

        func search(
            keyword: String, query: RefSearchQuery,
            limit: Int, offset: Int
        ) async throws -> [CatalogItem] {
            try await searchPage(
                keyword: keyword, query: query, limit: limit, offset: offset
            ).items
        }

        func trending(limit: Int, offset: Int) async throws -> [CatalogItem] { [] }
        func search(tag: String, limit: Int, offset: Int) async throws -> [CatalogItem] { [] }
        func fetchSubject(subjectID: Int) async throws -> CatalogItem {
            throw CatalogAPIError.http(status: 404)
        }
        func fetchTags(subjectID: Int) async throws -> [CatalogTag] { [] }
        func fetchCharacters(subjectID: Int) async throws -> [CatalogRelatedCharacter] { [] }
        func fetchPersons(subjectID: Int) async throws -> [CatalogRelatedPerson] { [] }
        func fetchComments(subjectID: Int) async throws -> [CatalogSubjectComment] { [] }
        func fetchReviews(subjectID: Int) async throws -> [CatalogSubjectReview] { [] }
        func fetchEpisodes(subjectID: Int) async throws -> [CatalogEpisode] { [] }
        func fetchEpisodeComments(episodeID: Int) async throws -> [CatalogEpisodeComment] { [] }
    }
}
