import Foundation

/// 目录元数据的抽象：首页、搜索、详情页都经它取数。注入用 protocol，方便单测。
/// 生产实现是 `RefCatalogAPI`：数据来自当前 ref，ref 没提供的部分返回空。
/// 首页的一个分区：标题、副标题、可浏览的 tag（没有就不显示「查看全部」）和卡片。
public struct CatalogHomeSection: Hashable, Sendable {
    public let title: String
    public let subtitle: String?
    public let tag: String?
    public let items: [CatalogItem]

    public init(title: String, subtitle: String? = nil, tag: String? = nil, items: [CatalogItem]) {
        self.title = title
        self.subtitle = subtitle
        self.tag = tag
        self.items = items
    }
}

public protocol CatalogAPIClientProtocol: Sendable {
    /// 首页分区，完全由当前 ref 决定；ref 没提供首页时为空。
    func homeSections() async throws -> [CatalogHomeSection]
    /// 首页榜单（ref 的 `home()` 拍平）。
    func trending(limit: Int, offset: Int) async throws -> [CatalogItem]
    /// 按 tag 浏览（ref 的 `browse()`）。
    func search(tag: String, limit: Int, offset: Int) async throws -> [CatalogItem]
    /// 按关键字搜索。`query` 是用户在 ref 声明的排序 / 筛选里的选择；关键字可以为空（只按筛选找）。
    /// ref 的搜索不分页，这里在客户端切页。
    func search(
        keyword: String,
        query: RefSearchQuery,
        limit: Int,
        offset: Int
    ) async throws -> [CatalogItem]
    func searchPage(
        keyword: String,
        query: RefSearchQuery,
        limit: Int,
        offset: Int
    ) async throws -> CatalogSearchPage
    /// 当前 ref 声明的搜索排序 / 筛选；没声明或没有 ref 时为空。
    func searchSpec() async -> RefSearchSpec
    func fetchSubject(subjectID: Int) async throws -> CatalogItem
    func fetchTags(subjectID: Int) async throws -> [CatalogTag]
    func fetchCharacters(subjectID: Int) async throws -> [CatalogRelatedCharacter]
    func fetchPersons(subjectID: Int) async throws -> [CatalogRelatedPerson]
    func fetchComments(subjectID: Int) async throws -> [CatalogSubjectComment]
    func fetchReviews(subjectID: Int) async throws -> [CatalogSubjectReview]
    func fetchEpisodes(subjectID: Int) async throws -> [CatalogEpisode]
    func fetchEpisodeComments(episodeID: Int) async throws -> [CatalogEpisodeComment]
}

extension CatalogAPIClientProtocol {
    public func homeSections() async throws -> [CatalogHomeSection] { [] }

    public func searchPage(
        keyword: String,
        query: RefSearchQuery,
        limit: Int,
        offset: Int
    ) async throws -> CatalogSearchPage {
        let items = try await search(keyword: keyword, query: query, limit: limit, offset: offset)
        return CatalogSearchPage(items: items, nextOffset: offset + items.count, hasMore: items.count == limit)
    }

    public func searchSpec() async -> RefSearchSpec { .none }
}

public enum CatalogAPIError: Error, Hashable, Sendable {
    case invalidURL
    case transport(message: String)
    case http(status: Int)
    case decoding(message: String)
    case timeout
    case cancelled
    /// ref 自己报告的错误（脚本抛出、未配置等），原样显示给用户。
    case refFailed(message: String)
    /// 当前没有选中的 ref。
    case noActiveRef
    /// 这个条目不是本次运行中从 ref 拿到的，无法回查详情。
    case unknownSubject

    public var userMessage: String {
        switch self {
        case .invalidURL: return "URL 无效"
        case .transport(let m): return "网络错误：\(m)"
        case .http(let s): return "HTTP \(s)"
        case .decoding: return "返回数据无法解析"
        case .timeout: return "请求超时"
        case .cancelled: return "已取消"
        case .refFailed(let m): return m
        case .noActiveRef: return "还没有选择 ref，请先在设置里添加"
        case .unknownSubject: return "暂时无法获取这个条目的详情"
        }
    }

    static func wrap(_ error: Error) -> CatalogAPIError {
        switch error {
        case let error as CatalogAPIError: return error
        case is CancellationError: return .cancelled
        case RefError.timeout: return .timeout
        case RefError.invalidResult(let message): return .decoding(message: message)
        case RefError.scriptError(let message): return .refFailed(message: message)
        default: return .transport(message: error.localizedDescription)
        }
    }
}

/// 把当前 ref 适配成 `CatalogAPIClientProtocol`。
///
/// 条目 id 是 `Int`（沿用追剧 / 历史的存储结构），ref 的 id 是字符串：
/// 这里用 `refID + itemID` 的 FNV-1a 哈希做稳定的 `Int` id，并记住反查表，
/// 所以跨启动同一个条目的 id 不变。
public actor RefCatalogAPI: CatalogAPIClientProtocol {
    private let store: RefStore
    private var lookup: [Int: (refID: String, itemID: String)] = [:]

    public init(store: RefStore) {
        self.store = store
    }

    public static func stableID(refID: String, itemID: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (refID + "\u{1F}" + itemID).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Int(hash & 0x3FFF_FFFF_FFFF_FFFF) // 正数，且不溢出 SwiftData 的 Int
    }

    // MARK: - 列表

    public func homeSections() async throws -> [CatalogHomeSection] {
        let ref = try await currentRef()
        do {
            return try await ref.home().map { section in
                CatalogHomeSection(
                    title: section.title, subtitle: section.subtitle, tag: section.tag,
                    items: map(section.items, ref: ref))
            }
        } catch { throw CatalogAPIError.wrap(error) }
    }

    public func trending(limit: Int, offset: Int) async throws -> [CatalogItem] {
        let ref = try await currentRef()
        do {
            var seen = Set<String>()
            var items: [RefSearchItem] = []
            for section in try await ref.home() {
                for item in section.items where seen.insert(item.id).inserted { items.append(item) }
            }
            return page(map(items, ref: ref), limit: limit, offset: offset)
        } catch { throw CatalogAPIError.wrap(error) }
    }

    public func search(tag: String, limit: Int, offset: Int) async throws -> [CatalogItem] {
        let ref = try await currentRef()
        let pageNumber = limit > 0 ? offset / limit + 1 : 1
        do {
            return map(try await ref.browse(tag: tag, page: pageNumber), ref: ref)
        } catch { throw CatalogAPIError.wrap(error) }
    }

    public func search(
        keyword: String, query: RefSearchQuery, limit: Int, offset: Int
    ) async throws -> [CatalogItem] {
        let ref = try await currentRef()
        do {
            let items = map(try await ref.search(keyword, query: query), ref: ref)
            return page(items, limit: limit, offset: offset)
        } catch { throw CatalogAPIError.wrap(error) }
    }

    public func searchSpec() async -> RefSearchSpec {
        await store.current?.manifest.search ?? .none
    }

    // MARK: - 详情

    public func fetchSubject(subjectID: Int) async throws -> CatalogItem {
        let (ref, itemID) = try await refAndItemID(for: subjectID)
        do {
            guard let detail = try await ref.detail(id: itemID) else { throw CatalogAPIError.unknownSubject }
            return map([detail], ref: ref)[0]
        } catch { throw CatalogAPIError.wrap(error) }
    }

    public func fetchTags(subjectID: Int) async throws -> [CatalogTag] {
        try await fetchSubject(subjectID: subjectID).tags
    }

    // ref 协议没有这些内容：角色、人员、评论、分集信息、分集吐槽。界面上对应位置留空。
    public func fetchCharacters(subjectID: Int) async throws -> [CatalogRelatedCharacter] { [] }
    public func fetchPersons(subjectID: Int) async throws -> [CatalogRelatedPerson] { [] }
    public func fetchComments(subjectID: Int) async throws -> [CatalogSubjectComment] { [] }
    public func fetchReviews(subjectID: Int) async throws -> [CatalogSubjectReview] { [] }
    public func fetchEpisodes(subjectID: Int) async throws -> [CatalogEpisode] { [] }
    public func fetchEpisodeComments(episodeID: Int) async throws -> [CatalogEpisodeComment] { [] }

    // MARK: - 内部

    private func currentRef() async throws -> any Ref {
        guard let ref = await store.current else { throw CatalogAPIError.noActiveRef }
        return ref
    }

    private func refAndItemID(for subjectID: Int) async throws -> (any Ref, String) {
        let ref = try await currentRef()
        guard let known = lookup[subjectID], known.refID == ref.manifest.id else {
            throw CatalogAPIError.unknownSubject
        }
        return (ref, known.itemID)
    }

    private func page(_ items: [CatalogItem], limit: Int, offset: Int) -> [CatalogItem] {
        guard offset < items.count else { return [] }
        return Array(items[offset..<min(items.count, offset + max(limit, 0))])
    }

    private func map(_ items: [RefSearchItem], ref: any Ref) -> [CatalogItem] {
        items.map { item in
            let id = Self.stableID(refID: ref.manifest.id, itemID: item.id)
            lookup[id] = (ref.manifest.id, item.id)
            let cover = item.cover ?? ""
            return CatalogItem(
                id: id,
                name: item.title,
                nameCn: item.title,
                summary: item.summary ?? "",
                airDate: item.airDate ?? "",
                rank: item.rank ?? 0,
                ratingScore: item.rating ?? 0,
                images: CatalogImages(large: cover, common: cover, medium: cover, small: cover, grid: cover),
                tags: (item.tags ?? []).map { CatalogTag(name: $0, count: 0) },
                ratingTotal: item.ratingTotal ?? 0,
                eps: item.totalEpisodes ?? 0,
                info: item.info ?? "",
                totalEpisodes: item.totalEpisodes ?? 0,
                heat: item.heat ?? 0
            )
        }
    }
}
