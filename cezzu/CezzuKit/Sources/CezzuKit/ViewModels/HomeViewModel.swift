import Foundation
import Observation

/// 首页一个分区的标识。分区由当前 ref 的 `home()` 决定，不再有固定清单。
public struct HomeSection: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    /// 非空表示这个分区可以「查看全部」（走 ref 的 `browse`）。
    public let tag: String

    public init(id: String, title: String, subtitle: String? = nil, tag: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.tag = tag
    }

    public var canBrowse: Bool { !tag.isEmpty }
}

/// 首页分区的运行时状态（items + loading）。
public struct HomeSectionContent: Identifiable, Sendable {
    public var id: String { section.id }
    public let section: HomeSection
    public var items: [CatalogItem]
    public var isLoading: Bool
    public var loadFailed: Bool
    public var lastError: CatalogAPIError?
    /// 是否已完成至少一次请求（成功空列表也算），避免 LazyVStack 反复触发加载。
    public var hasLoaded: Bool

    public init(
        section: HomeSection,
        items: [CatalogItem] = [],
        isLoading: Bool = false,
        loadFailed: Bool = false,
        lastError: CatalogAPIError? = nil,
        hasLoaded: Bool = false
    ) {
        self.section = section
        self.items = items
        self.isLoading = isLoading
        self.loadFailed = loadFailed
        self.lastError = lastError
        self.hasLoaded = hasLoaded
    }
}

/// 主页 view model —— 按分区横向展示「热门 + 各 tag」，每区默认预览 N 条。
///
/// 顶部沉浸式 Banner 取自热门前 5 的磁盘缓存，仅 id 序列变化时刷新。
/// 不再维护单一 currentTag / 下拉切换；「查看全部」由 `TagBrowseViewModel` 接管。
@MainActor
@Observable
public final class HomeViewModel {
    /// 每个分区首页预览条数。
    public static let previewPageSize: Int = 20

    public private(set) var sections: [HomeSectionContent] = []
    /// 是否至少有一个分区已成功拉过数据（用于 loadInitialIfNeeded 短路）。
    public private(set) var hasLoadedAny: Bool = false
    /// 首页分区是否已经向 ref 请求过（成功空列表也算）。
    public private(set) var hasLoadedLayout: Bool = false
    public private(set) var isLoadingLayout: Bool = false
    /// 请求首页失败时的原因；成功（哪怕没有分区）为 nil。
    public private(set) var layoutError: CatalogAPIError?
    private var layoutGeneration = 0

    /// 沉浸式 Banner 条目（热门前 5，来自缓存 / 同步）。
    public private(set) var bannerItems: [CatalogItem] = []
    /// 当前 Banner 页 index（驱动全页渐变）。
    public var activeBannerIndex: Int = 0
    /// subject id → 封面色板。
    public private(set) var bannerPalettes: [Int: CoverColorPalette] = [:]

    /// 当前页对应色板（无数据时用 fallback）。
    public var activeBannerPalette: CoverColorPalette {
        guard bannerItems.indices.contains(activeBannerIndex) else {
            return .fallback
        }
        let id = bannerItems[activeBannerIndex].id
        return bannerPalettes[id] ?? .fallback
    }

    private let api: CatalogAPIClientProtocol
    private let bannerStore: HomeBannerStore
    private let paletteStore: BannerPaletteStore
    /// 正在取色的 subject，避免重复下载。
    private var paletteTasks: Set<Int> = []

    public init(
        api: CatalogAPIClientProtocol,
        bannerStore: HomeBannerStore = HomeBannerStore(),
        paletteStore: BannerPaletteStore = BannerPaletteStore()
    ) {
        self.api = api
        self.bannerStore = bannerStore
        self.paletteStore = paletteStore
        // 首帧即可用：骨架 + Banner 磁盘缓存 + 上次算好的色板，避免空黑屏等 .task
        bannerPalettes = paletteStore.load()
        ensureSectionsReady()
    }

    /// 首帧即可用：灌入 Banner 磁盘缓存（不发网络请求）。分区要等 ref 回应才知道有哪些。
    public func ensureSectionsReady() {
        if bannerItems.isEmpty {
            let cached = bannerStore.load()
            if !cached.isEmpty {
                bannerItems = cached
                clampActiveBannerIndex()
            }
        }
    }

    /// 启动时调用 —— 向当前 ref 要首页分区，Banner 取第一个有内容的分区。
    public func loadInitialIfNeeded() async {
        ensureSectionsReady()
        if !hasLoadedLayout { await loadLayout() }
        // 当前页色板优先；其余后台预取，不挡首屏
        if let first = bannerItems.first {
            await loadPaletteIfNeeded(for: first)
        }
        Task { await prefetchRemainingBannerPalettes() }
    }

    /// 强制重拉首页（下拉刷新）。
    public func reload() async {
        await loadLayout()
    }

    /// 分区是 ref 一次性给全的，不再按视口懒加载；保留这个入口只为让视图的 `.task` 不用改。
    public func loadSectionIfNeeded(_ sectionID: String, force: Bool = false) async {
        ensureSectionsReady()
        if force { await loadLayout() }
    }

    /// 分区失败后手动重试：整页重新向 ref 请求。
    public func retrySection(_ sectionID: String) async {
        await loadLayout()
    }

    private func loadLayout() async {
        layoutGeneration += 1
        let generation = layoutGeneration
        isLoadingLayout = true
        layoutError = nil

        let result: Result<[CatalogHomeSection], CatalogAPIError>
        do {
            result = .success(try await api.homeSections())
        } catch let error as CatalogAPIError {
            result = .failure(error)
        } catch {
            result = .failure(.transport(message: error.localizedDescription))
        }

        // 过期世代（换 ref / 再次刷新）：丢弃，别把旧结果写回去。
        guard generation == layoutGeneration, !Task.isCancelled else { return }
        isLoadingLayout = false
        hasLoadedLayout = true
        switch result {
        case .success(let layout):
            var seen = Set<String>()
            sections = layout.enumerated().compactMap { index, entry -> HomeSectionContent? in
                guard !entry.items.isEmpty else { return nil }
                var id = entry.title
                if !seen.insert(id).inserted { id = "\(entry.title)#\(index)" }
                return HomeSectionContent(
                    section: HomeSection(
                        id: id, title: entry.title, subtitle: entry.subtitle, tag: entry.tag ?? ""),
                    items: entry.items, hasLoaded: true)
            }
            hasLoadedAny = !sections.isEmpty
            if let first = sections.first {
                syncBanner(from: first.items)
            } else {
                bannerItems = []
                clampActiveBannerIndex()
            }
        case .failure(let error):
            sections = []
            bannerItems = []
            hasLoadedAny = false
            layoutError = error
        }
    }

    public func cancel() {
        // 抬高世代，使进行中的请求结果被丢弃。
        layoutGeneration += 1
        isLoadingLayout = false
    }

    /// Banner 轮播切页。
    public func setActiveBannerIndex(_ index: Int) {
        guard !bannerItems.isEmpty else {
            activeBannerIndex = 0
            return
        }
        activeBannerIndex = min(max(0, index), bannerItems.count - 1)
        let item = bannerItems[activeBannerIndex]
        Task { await loadPaletteIfNeeded(for: item) }
    }

    /// 为 Banner 条目取封面色（已有则跳过）。
    /// 网络 / 解码在后台跑；写入 `bannerPalettes` 回主线程。
    public func loadPaletteIfNeeded(for item: CatalogItem) async {
        if bannerPalettes[item.id] != nil { return }
        guard !paletteTasks.contains(item.id) else { return }
        paletteTasks.insert(item.id)
        defer { paletteTasks.remove(item.id) }

        // 取色用小图：grid/small/medium，避免下 large 原图
        guard let urlString = paletteURLString(for: item),
              let url = URL(string: urlString)
        else {
            bannerPalettes[item.id] = .fallback
            return
        }

        let palette = await CoverColorExtractor.loadAndExtract(from: url) ?? .fallback
        bannerPalettes[item.id] = palette
        paletteStore.store(palette, for: item.id)
    }

    /// 预热全部 Banner 色板（首张优先已在 `loadInitialIfNeeded` 完成时调用其余）。
    public func prefetchBannerPalettes() async {
        if let first = bannerItems.first {
            await loadPaletteIfNeeded(for: first)
        }
        await prefetchRemainingBannerPalettes()
    }

    // MARK: - private

    /// 其余页色板：并发后台，不阻塞首屏。
    private func prefetchRemainingBannerPalettes() async {
        let rest = Array(bannerItems.dropFirst().prefix(HomeBannerStore.maxCount))
        guard !rest.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for item in rest {
                group.addTask { await self.loadPaletteIfNeeded(for: item) }
            }
        }
    }

    private func paletteURLString(for item: CatalogItem) -> String? {
        // 小 → 大：色板不需要高清
        let candidates = [
            item.images.grid,
            item.images.small,
            item.images.medium,
            item.images.common,
            item.images.listBest,
            item.images.best,
        ]
        for raw in candidates {
            if let s = nonEmptyURL(raw) { return s }
        }
        return nil
    }

    private func syncBanner(from trending: [CatalogItem]) {
        let didUpdate = bannerStore.updateIfNeeded(from: trending)
        let next = bannerStore.load()
        if didUpdate || bannerItems.isEmpty {
            bannerItems = next
            clampActiveBannerIndex()
            if let first = bannerItems.first {
                Task { await loadPaletteIfNeeded(for: first) }
            }
            Task { await prefetchRemainingBannerPalettes() }
        }
    }

    private func clampActiveBannerIndex() {
        if bannerItems.isEmpty {
            activeBannerIndex = 0
        } else {
            activeBannerIndex = min(activeBannerIndex, bannerItems.count - 1)
        }
    }

    private func nonEmptyURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
