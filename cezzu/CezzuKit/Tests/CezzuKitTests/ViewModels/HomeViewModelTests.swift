import Foundation
import Testing
@testable import CezzuKit

@Suite("HomeViewModel")
@MainActor
struct HomeViewModelTests {

    /// 一个内存版 Catalog client，给 view model 单测用。
    /// 计数器用锁保护：`HomeViewModel.reload` 会并发打多个分区。
    final class FakeCatalogAPI: CatalogAPIClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        /// 首页分区由 ref 给；默认没有分区。
        var layoutResult: Result<[CatalogHomeSection], CatalogAPIError> = .success([])
        private(set) var layoutCalls: Int = 0
        var trendingResult: Result<[CatalogItem], CatalogAPIError> = .success([])
        var searchResult: Result<[CatalogItem], CatalogAPIError> = .success([])
        var keywordSearchResult: Result<[CatalogItem], CatalogAPIError> = .success([])
        /// 按 tag 覆盖 search 返回；未命中时回落到 `searchResult`。
        var searchResultsByTag: [String: Result<[CatalogItem], CatalogAPIError>] = [:]
        private(set) var trendingCalls: Int = 0
        private(set) var trendingLimits: [Int] = []
        private(set) var searchCalls: [String] = []
        private(set) var searchOffsets: [Int] = []
        private(set) var searchLimits: [Int] = []
        private(set) var keywordSearchCalls: [(String, CatalogSearchSort, Int)] = []
        private(set) var keywordSearchFilters: [CatalogSearchFilter] = []

        func homeSections() async throws -> [CatalogHomeSection] {
            let result = recordLayout()
            switch result {
            case .success(let sections): return sections
            case .failure(let error): throw error
            }
        }

        func trending(limit: Int, offset: Int) async throws -> [CatalogItem] {
            switch recordTrending(limit: limit) {
            case .success(let items): return items
            case .failure(let error): throw error
            }
        }

        func search(tag: String, limit: Int, offset: Int) async throws -> [CatalogItem] {
            switch recordSearch(tag: tag, limit: limit, offset: offset) {
            case .success(let items): return items
            case .failure(let error): throw error
            }
        }

        func search(
            keyword: String,
            sort: CatalogSearchSort,
            filter: CatalogSearchFilter,
            limit: Int,
            offset: Int
        ) async throws -> [CatalogItem] {
            switch recordKeywordSearch(keyword: keyword, sort: sort, filter: filter, offset: offset) {
            case .success(let items): return items
            case .failure(let error): throw error
            }
        }

        private func recordLayout() -> Result<[CatalogHomeSection], CatalogAPIError> {
            lock.lock()
            defer { lock.unlock() }
            layoutCalls += 1
            return layoutResult
        }

        private func recordTrending(limit: Int) -> Result<[CatalogItem], CatalogAPIError> {
            lock.lock()
            defer { lock.unlock() }
            trendingCalls += 1
            trendingLimits.append(limit)
            return trendingResult
        }

        private func recordSearch(
            tag: String,
            limit: Int,
            offset: Int
        ) -> Result<[CatalogItem], CatalogAPIError> {
            lock.lock()
            defer { lock.unlock() }
            searchCalls.append(tag)
            searchOffsets.append(offset)
            searchLimits.append(limit)
            return searchResultsByTag[tag] ?? searchResult
        }

        private func recordKeywordSearch(
            keyword: String,
            sort: CatalogSearchSort,
            filter: CatalogSearchFilter,
            offset: Int
        ) -> Result<[CatalogItem], CatalogAPIError> {
            lock.lock()
            defer { lock.unlock() }
            keywordSearchCalls.append((keyword, sort, offset))
            keywordSearchFilters.append(filter)
            return keywordSearchResult
        }

        func fetchSubject(subjectID: Int) async throws -> CatalogItem {
            CatalogItem(
                id: subjectID, name: "", nameCn: "", summary: "", airDate: "",
                rank: 0, ratingScore: 0, images: .empty, tags: []
            )
        }
        func fetchTags(subjectID: Int) async throws -> [CatalogTag] { [] }
        func fetchCharacters(subjectID: Int) async throws -> [CatalogRelatedCharacter] { [] }
        func fetchPersons(subjectID: Int) async throws -> [CatalogRelatedPerson] { [] }
        func fetchComments(subjectID: Int) async throws -> [CatalogSubjectComment] { [] }
        func fetchReviews(subjectID: Int) async throws -> [CatalogSubjectReview] { [] }
        func fetchEpisodes(subjectID: Int) async throws -> [CatalogEpisode] { [] }
        func fetchEpisodeComments(episodeID: Int) async throws -> [CatalogEpisodeComment] { [] }
    }

    static func makeItem(id: Int, name: String) -> CatalogItem {
        CatalogItem(
            id: id, name: name, nameCn: name,
            summary: "", airDate: "", rank: 0, ratingScore: 0,
            images: .empty, tags: []
        )
    }

    private func tempStore(seed: [CatalogItem] = []) -> (HomeBannerStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cezzu-vm-banner-\(UUID().uuidString).json")
        let store = HomeBannerStore(fileURL: url)
        if !seed.isEmpty { #expect(store.updateIfNeeded(from: seed) == true) }
        return (store, url)
    }

    private func section(_ title: String, ids: ClosedRange<Int>, tag: String? = nil, subtitle: String? = nil)
        -> CatalogHomeSection
    {
        CatalogHomeSection(title: title, subtitle: subtitle, tag: tag, items: ids.map { Self.makeItem(id: $0, name: "\(title)\($0)") })
    }

    @Test("sections come entirely from the ref: titles, order, subtitles and browse tags")
    func sectionsComeFromTheRef() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakeCatalogAPI()
        api.layoutResult = .success([
            section("热播", ids: 1...6, tag: "hot", subtitle: "NOW"),
            section("电影", ids: 10...12),
        ])
        let vm = HomeViewModel(api: api, bannerStore: store)
        #expect(vm.sections.isEmpty, "分区要等 ref 回应才知道有哪些，不能先摆一套固定的")

        await vm.loadInitialIfNeeded()

        #expect(vm.sections.map(\.section.title) == ["热播", "电影"])
        #expect(vm.sections[0].section.subtitle == "NOW")
        #expect(vm.sections[0].section.canBrowse)
        #expect(!vm.sections[1].section.canBrowse, "ref 没给 tag 就没有「查看全部」")
        #expect(vm.sections[0].items.count == 6)
        #expect(vm.hasLoadedLayout && vm.layoutError == nil)
        #expect(api.trendingCalls == 0 && api.searchCalls.isEmpty, "不再有固定的热门 / 标签请求")
    }

    @Test("banner is the first non-empty section and is cached")
    func bannerFollowsFirstSection() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakeCatalogAPI()
        api.layoutResult = .success([
            CatalogHomeSection(title: "空", items: []),
            section("热播", ids: 1...8),
        ])
        let vm = HomeViewModel(api: api, bannerStore: store)

        await vm.loadInitialIfNeeded()

        #expect(vm.sections.map(\.section.title) == ["热播"], "空分区不显示")
        #expect(vm.bannerItems.map(\.id) == [1, 2, 3, 4, 5])
        #expect(store.load().map(\.id) == [1, 2, 3, 4, 5])
    }

    @Test("a ref without a home yields no sections and no banner, without an error")
    func noHomeIsEmptyNotError() async {
        let (store, url) = tempStore(seed: (90...94).map { Self.makeItem(id: $0, name: "stale\($0)") })
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakeCatalogAPI()
        let vm = HomeViewModel(api: api, bannerStore: store)
        #expect(vm.bannerItems.count == 5, "首帧先用缓存")

        await vm.loadInitialIfNeeded()

        #expect(vm.sections.isEmpty)
        #expect(vm.bannerItems.isEmpty, "ref 说没有首页，旧缓存就不能再挂在屏幕上")
        #expect(vm.hasLoadedLayout)
        #expect(vm.layoutError == nil)
    }

    @Test("a failing home surfaces the error and clears stale content")
    func failingHomeSurfacesError() async {
        let (store, url) = tempStore(seed: (90...94).map { Self.makeItem(id: $0, name: "stale\($0)") })
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakeCatalogAPI()
        api.layoutResult = .failure(.refFailed(message: "未配置"))
        let vm = HomeViewModel(api: api, bannerStore: store)

        await vm.loadInitialIfNeeded()

        #expect(vm.sections.isEmpty && vm.bannerItems.isEmpty)
        #expect(vm.layoutError == .refFailed(message: "未配置"))
    }

    @Test("retry and reload ask the ref again")
    func retryAndReloadRefetch() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakeCatalogAPI()
        api.layoutResult = .failure(.timeout)
        let vm = HomeViewModel(api: api, bannerStore: store)
        await vm.loadInitialIfNeeded()
        #expect(vm.layoutError == .timeout)

        api.layoutResult = .success([section("热播", ids: 1...3)])
        await vm.retrySection("热播")
        #expect(vm.layoutError == nil)
        #expect(vm.sections.count == 1)

        await vm.reload()
        #expect(api.layoutCalls == 3)
    }

    @Test("loadInitialIfNeeded does not refetch once the layout is loaded")
    func initialLoadIsIdempotent() async {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakeCatalogAPI()
        api.layoutResult = .success([section("热播", ids: 1...3)])
        let vm = HomeViewModel(api: api, bannerStore: store)

        await vm.loadInitialIfNeeded()
        await vm.loadInitialIfNeeded()
        await vm.loadSectionIfNeeded("热播")

        #expect(api.layoutCalls == 1)
    }

    @Test("init hydrates banner from disk cache without network")
    func initHydratesBannerCache() {
        let (store, url) = tempStore(seed: (1...5).map { Self.makeItem(id: $0, name: "C\($0)") })
        defer { try? FileManager.default.removeItem(at: url) }

        let api = FakeCatalogAPI()
        let vm = HomeViewModel(api: api, bannerStore: store)

        #expect(vm.bannerItems.map(\.id) == [1, 2, 3, 4, 5])
        #expect(api.layoutCalls == 0)
    }

    @Test("banner updates when the first section's top five ids change")
    func bannerUpdatesOnIDChange() async {
        let (store, url) = tempStore(seed: (1...5).map { Self.makeItem(id: $0, name: "O\($0)") })
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakeCatalogAPI()
        api.layoutResult = .success([section("热播", ids: 10...20)])
        let vm = HomeViewModel(api: api, bannerStore: store)
        #expect(vm.bannerItems.map(\.id) == [1, 2, 3, 4, 5])

        await vm.loadInitialIfNeeded()

        #expect(vm.bannerItems.map(\.id) == [10, 11, 12, 13, 14])
        #expect(store.load().map(\.id) == [10, 11, 12, 13, 14])
    }

    @Test("same top five ids keep the cached banner")
    func sameIDsKeepCache() async {
        let (store, url) = tempStore(seed: (1...5).map { Self.makeItem(id: $0, name: "old\($0)") })
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakeCatalogAPI()
        api.layoutResult = .success([section("热播", ids: 1...5)])
        let vm = HomeViewModel(api: api, bannerStore: store)

        await vm.loadInitialIfNeeded()

        #expect(vm.bannerItems.map(\.id) == [1, 2, 3, 4, 5])
        #expect(vm.bannerItems.first?.displayName == "old1")
    }

    @Test("setActiveBannerIndex clamps to range")
    func setActiveBannerIndexClamps() async {
        let (store, url) = tempStore(seed: (1...3).map { Self.makeItem(id: $0, name: "B\($0)") })
        defer { try? FileManager.default.removeItem(at: url) }
        let api = FakeCatalogAPI()
        api.layoutResult = .success([section("热播", ids: 1...3)])
        let vm = HomeViewModel(api: api, bannerStore: store)
        await vm.loadInitialIfNeeded()
        vm.setActiveBannerIndex(99)
        #expect(vm.activeBannerIndex == 2)
        vm.setActiveBannerIndex(-3)
        #expect(vm.activeBannerIndex == 0)
    }

    // MARK: - banner 缓存按 ref 隔离

    @Test("banner cache is isolated per ref and disabled without a ref")
    func bannerCacheIsPerRef() {
        let items = (1...5).map { Self.makeItem(id: $0, name: "x\($0)") }
        let idA = "test-a-\(UUID().uuidString)"
        let idB = "test-b-\(UUID().uuidString)"
        let a = HomeBannerStore(refID: idA)
        let b = HomeBannerStore(refID: idB)
        let none = HomeBannerStore(refID: nil)
        defer {
            for id in [idA, idB] {
                try? FileManager.default.removeItem(
                    at: HomeBannerStore.defaultFileURL().deletingLastPathComponent()
                        .appendingPathComponent("home-banner-\(id).json"))
            }
        }

        #expect(a.updateIfNeeded(from: items) == true)
        #expect(a.load().count == 5)
        #expect(b.load().isEmpty, "换 ref 不能看到别家的榜单")
        #expect(HomeBannerStore(refID: idA).load().count == 5, "同一个 ref 重开能读回")

        #expect(none.updateIfNeeded(from: items) == false)
        #expect(none.load().isEmpty, "没选 ref 时不读也不写")
    }
}
