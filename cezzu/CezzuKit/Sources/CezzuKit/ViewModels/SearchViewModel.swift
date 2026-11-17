import Foundation
import Observation

/// Catalog 搜索页的 view model。
@MainActor
@Observable
public final class SearchViewModel {
    public var text: String = ""
    /// 当前 ref 声明的排序 / 筛选。界面只渲染这里有的东西。
    public private(set) var spec: RefSearchSpec = .none
    /// 选中的排序 id；`nil` 表示 ref 的默认排序。
    public var selectedSort: String?
    /// 筛选组 key → 选中的 option value。没选的组不出现。
    public private(set) var selections: [String: String] = [:]

    public private(set) var isSearching: Bool = false
    public private(set) var results: [CatalogItem] = []
    public private(set) var lastError: CatalogAPIError?
    public private(set) var hasSearched: Bool = false
    public private(set) var hasMore: Bool = false
    public private(set) var isLoadingMore: Bool = false

    private static let pageSize: Int = 20
    /// 触发实时搜索的最小关键字长度（trim 后）。
    /// 1 个字符的查询既贵又噪声大，门槛设到 2。
    public static let liveSearchMinLength: Int = 2

    private let api: CatalogAPIClientProtocol
    /// 可变：iOS Root 会先注入 empty session 的 store，再在 persistent session 就绪后 `bindHistory` 切过去。
    private var history: SearchHistoryStoring?
    private let debounceMilliseconds: UInt64
    private var currentTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var nextOffset: Int = 0
    private var lastSubmittedKeyword: String = ""
    private var lastSubmittedQuery: RefSearchQuery = .empty

    /// 是否有任何筛选生效（排序不算）。
    public var hasActiveFilter: Bool { !selections.isEmpty }

    private var query: RefSearchQuery {
        RefSearchQuery(sort: selectedSort, filters: selections)
    }

    public init(
        api: CatalogAPIClientProtocol,
        history: SearchHistoryStoring? = nil,
        debounceMilliseconds: UInt64 = 350
    ) {
        self.api = api
        self.history = history
        self.debounceMilliseconds = debounceMilliseconds
    }

    /// 切换底层历史 store（不重置搜索态）。
    /// iOS 启动路径：empty → persistent 时由 Root 调用，避免历史写进会被丢弃的内存 store。
    public func bindHistory(_ history: SearchHistoryStoring?) {
        self.history = history
    }

    /// 历史关键字（最近在前），UI 直接绑定渲染。
    public var historyKeywords: [String] {
        history?.recent ?? []
    }

    public func submit() async {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = self.query
        guard !keyword.isEmpty || query.hasFilters else { return }
        debounceTask?.cancel()
        currentTask?.cancel()
        results = []
        isSearching = true
        isLoadingMore = false
        lastError = nil
        hasSearched = true
        nextOffset = 0
        lastSubmittedKeyword = keyword
        lastSubmittedQuery = query

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await api.searchPage(
                    keyword: keyword,
                    query: query,
                    limit: Self.pageSize,
                    offset: 0
                )
                self.results = page.items
                self.nextOffset = page.nextOffset
                self.hasMore = page.hasMore
                self.lastError = nil
                if !keyword.isEmpty {
                    self.history?.record(keyword: keyword)
                }
            } catch let error as CatalogAPIError {
                self.results = []
                self.hasMore = false
                self.lastError = error
            } catch {
                self.results = []
                self.hasMore = false
                self.lastError = .transport(message: error.localizedDescription)
            }
            self.isSearching = false
        }
        await currentTask?.value
    }

    public func loadMoreIfNeeded(currentItem item: CatalogItem) async {
        guard hasMore, !isSearching, !isLoadingMore else { return }
        guard item.id == results.last?.id else { return }

        let keyword = lastSubmittedKeyword
        let query = lastSubmittedQuery
        guard !keyword.isEmpty || query.hasFilters else { return }
        let offset = nextOffset
        isLoadingMore = true

        do {
            let page = try await api.searchPage(
                keyword: keyword,
                query: query,
                limit: Self.pageSize,
                offset: offset
            )
            results.append(contentsOf: page.items)
            nextOffset = page.nextOffset
            hasMore = page.hasMore
        } catch let error as CatalogAPIError {
            lastError = error
        } catch {
            lastError = .transport(message: error.localizedDescription)
        }

        isLoadingMore = false
    }

    public func cancel() {
        debounceTask?.cancel()
        currentTask?.cancel()
        isSearching = false
        isLoadingMore = false
    }

    /// 详情页点了一个标签：ref 没有「按标签筛选」这回事，就把标签当关键词搜。
    public func applyTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = trimmed
        selections = [:]
        debounceTask?.cancel()
    }

    /// 向当前 ref 要它声明的排序 / 筛选，并丢掉新声明里已经不存在的旧选择（换 ref 之后）。
    public func refreshSpec() async {
        let latest = await api.searchSpec()
        guard latest != spec else { return }
        spec = latest
        selections = selections.filter { key, value in
            latest.filters.first { $0.key == key }?.options.contains { $0.value == value } ?? false
        }
        if let selectedSort, !latest.sorts.contains(where: { $0.id == selectedSort }) {
            self.selectedSort = nil
        }
    }

    /// 选中（或用 `nil` 清除）一个筛选组的值；已经有搜索上下文时立即重搜。
    public func select(_ value: String?, forFilter key: String) {
        if let value {
            guard selections[key] != value else { return }
            selections[key] = value
        } else {
            guard selections[key] != nil else { return }
            selections[key] = nil
        }
        filterChanged()
    }

    /// 一键清掉所有筛选（排序保留）。
    public func resetFilters() {
        guard hasActiveFilter else { return }
        selections = [:]
        filterChanged()
    }

    /// 筛选变化后：已经有过一次有效搜索，或当前条件足够搜了，就立即重搜。
    public func filterChanged() {
        let hasContext = !lastSubmittedKeyword.isEmpty || lastSubmittedQuery.hasFilters
        let canSubmitNow = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasActiveFilter
        guard hasContext || canSubmitNow else { return }
        scheduleImmediateSubmit()
    }

    /// 完全清空搜索框并取消任何挂起的请求。给 UI 上的清空按钮。
    public func clearText() {
        text = ""
        debounceTask?.cancel()
    }

    /// 用户从历史记录里点了一条 —— 写回输入框并立即搜索（绕过 debounce）。
    public func applyHistory(_ keyword: String) async {
        text = keyword
        debounceTask?.cancel()
        await submit()
    }

    /// 删除一条历史记录。
    public func deleteHistory(_ keyword: String) {
        history?.delete(keyword: keyword)
    }

    /// 清空全部历史。
    public func clearHistory() {
        history?.clearAll()
    }

    /// 输入框文本变化时由 View 调用。会以 `debounceMilliseconds` 防抖后自动 submit。
    /// trim 后短于 `liveSearchMinLength` 的 keyword 不触发实时搜索（同时取消挂起请求）。
    public func textChanged() {
        debounceTask?.cancel()
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.count < Self.liveSearchMinLength && !hasActiveFilter {
            // 关键字过短且没有任何筛选兜底：取消挂起，不触发请求。
            return
        }
        let delay = debounceMilliseconds
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.submit()
        }
    }

    /// 排序变化时由 View 调用。如果已经有已生效的搜索上下文，立即重搜；否则什么都不做。
    public func sortChanged() {
        let hasContext = !lastSubmittedKeyword.isEmpty || lastSubmittedQuery.hasFilters
        guard hasContext else { return }
        scheduleImmediateSubmit()
    }

    /// 把一次"立即 submit"包到 `debounceTask` 上，保证 `waitForIdle()` 能等到它完成。
    /// 调用方负责确认上下文（keyword 或 tag）非空。
    private func scheduleImmediateSubmit() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            await self?.submit()
        }
    }

    /// 仅供测试 / UI 等候动画用，等待挂起的 debounce + 当前请求完成。
    public func waitForIdle() async {
        await debounceTask?.value
        await currentTask?.value
    }
}
