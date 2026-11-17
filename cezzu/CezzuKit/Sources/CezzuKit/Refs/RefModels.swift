import Foundation

/// 搜索结果 / 首页卡片 / 详情的统一条目。除 `id`、`title` 外全部可选：
/// ref 没给的字段，界面上对应位置就空着或隐藏。
public struct RefSearchItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var cover: String?
    /// 可选分组名（例如 ref 内部的站点名）。播放器只负责展示。
    public var group: String?
    public var summary: String?
    /// 首播 / 上映日期，建议 `YYYY-MM-DD`。
    public var airDate: String?
    public var rating: Double?
    public var ratingTotal: Int?
    public var rank: Int?
    public var tags: [String]?
    /// 单行简介，例如 `14 话 / 2026 年 7 月`。
    public var info: String?
    public var heat: Int?
    public var totalEpisodes: Int?

    public init(
        id: String, title: String, cover: String? = nil, group: String? = nil,
        summary: String? = nil, airDate: String? = nil, rating: Double? = nil,
        ratingTotal: Int? = nil, rank: Int? = nil, tags: [String]? = nil,
        info: String? = nil, heat: Int? = nil, totalEpisodes: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.cover = cover
        self.group = group
        self.summary = summary
        self.airDate = airDate
        self.rating = rating
        self.ratingTotal = ratingTotal
        self.rank = rank
        self.tags = tags
        self.info = info
        self.heat = heat
        self.totalEpisodes = totalEpisodes
    }
}

/// 首页的一个分区。
public struct RefSection: Codable, Hashable, Sendable {
    public var title: String
    public var subtitle: String?
    /// 给了就表示这个分区可以「查看全部」：播放器会用它调用 `browse({ tag })`。
    public var tag: String?
    public var items: [RefSearchItem]

    public init(title: String, subtitle: String? = nil, tag: String? = nil, items: [RefSearchItem]) {
        self.title = title
        self.subtitle = subtitle
        self.tag = tag
        self.items = items
    }
}

public struct RefEpisode: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// 一条线路及其剧集。
public struct RefRoad: Codable, Hashable, Sendable {
    public var name: String
    public var episodes: [RefEpisode]

    public init(name: String, episodes: [RefEpisode]) {
        self.name = name
        self.episodes = episodes
    }
}

public enum RefMediaKind: String, Codable, Hashable, Sendable {
    case hls
    case mp4
}

/// `resolve` 的结果：要么是直链，要么要求宿主去页面里嗅探。
public enum RefMedia: Hashable, Sendable {
    case direct(url: URL, kind: RefMediaKind, headers: [String: String], expiresAt: Date?)
    /// `headers` 是嗅探命中之后播放要带的头；`options` 约束嗅探过程本身。
    case sniff(page: URL, headers: [String: String], options: RefSniffOptions)
}

/// 宿主 WebView 嗅探时的可选约束。全部可省略。
public struct RefSniffOptions: Hashable, Sendable {
    public var userAgent: String
    public var referer: String
    /// `"k=v; k2=v2"`，加载页面前写入 WebView。
    public var cookies: String
    /// 对嗅探命中做正则过滤，命名组 `v` 取真实地址。
    public var videoURLPattern: String

    public init(userAgent: String = "", referer: String = "", cookies: String = "", videoURLPattern: String = "") {
        self.userAgent = userAgent
        self.referer = referer
        self.cookies = cookies
        self.videoURLPattern = videoURLPattern
    }
}

public enum RefError: Error, Equatable, Sendable {
    case invalidManifest(String)
    case unsupportedAPI(required: Int, supported: Int)
    case scriptError(String)
    case missingFunction(String)
    case invalidResult(String)
    case hostNotAllowed(String)
    case capabilityNotDeclared(String)
    case timeout
    case captchaRequired
    /// 站点要求人工验证；`url` 是该在 WebView 里打开的页面。
    case captchaChallenge(url: URL, userAgent: String)
    case unknownRef(String)
}

/// cezzu-refs 的运行时契约：三个必选函数。
public protocol Ref: Sendable {
    var manifest: RefManifest { get }
    func search(_ keyword: String) async throws -> [RefSearchItem]
    func episodes(id: String) async throws -> [RefRoad]
    func resolve(episodeID: String) async throws -> RefMedia

    // 可选：ref 没实现时返回空，界面对应位置留空。
    /// 首页分区。
    func home() async throws -> [RefSection]
    /// 按标签 / 分类浏览。`tag` 为空表示不限。
    func browse(tag: String, page: Int) async throws -> [RefSearchItem]
    /// 单个条目的完整资料。
    func detail(id: String) async throws -> RefSearchItem?
}

extension Ref {
    public func home() async throws -> [RefSection] { [] }
    public func browse(tag: String, page: Int) async throws -> [RefSearchItem] { [] }
    public func detail(id: String) async throws -> RefSearchItem? { nil }
}
