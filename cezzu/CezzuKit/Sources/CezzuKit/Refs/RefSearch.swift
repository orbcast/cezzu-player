import Foundation

/// ref 在清单里声明的搜索能力。声明了什么，界面就只提供什么；没声明的（排序、筛选）界面上不存在。
///
/// ```json
/// "search": {
///   "sorts":   [{ "id": "hot", "label": "热度" }],
///   "filters": [{ "key": "year", "label": "年份",
///                 "options": [{ "value": "2025", "label": "2025" }] }]
/// }
/// ```
/// 筛选一律是「一组候选值里单选」—— 年份、地区、类型都是同一种形态，播放器不认识它们的含义。
public struct RefSearchSpec: Codable, Hashable, Sendable {
    public struct Sort: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String

        public init(id: String, label: String? = nil) {
            self.id = id
            self.label = label ?? id
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        }

        private enum CodingKeys: String, CodingKey { case id, label }
    }

    public struct Option: Codable, Hashable, Sendable, Identifiable {
        public var value: String
        public var label: String
        public var id: String { value }

        public init(value: String, label: String? = nil) {
            self.value = value
            self.label = label ?? value
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.value = try c.decode(String.self, forKey: .value)
            self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? value
        }

        private enum CodingKeys: String, CodingKey { case value, label }
    }

    public struct Facet: Codable, Hashable, Sendable, Identifiable {
        public var key: String
        public var label: String
        public var options: [Option]
        public var id: String { key }

        public init(key: String, label: String? = nil, options: [Option]) {
            self.key = key
            self.label = label ?? key
            self.options = options
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.key = try c.decode(String.self, forKey: .key)
            self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
            self.options = try c.decode([Option].self, forKey: .options)
        }

        private enum CodingKeys: String, CodingKey { case key, label, options }
    }

    /// 排序方式；第一项是默认排序。为空表示 ref 不提供排序。
    public var sorts: [Sort]
    public var filters: [Facet]

    public static let none = RefSearchSpec()

    public init(sorts: [Sort] = [], filters: [Facet] = []) {
        self.sorts = sorts
        self.filters = filters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sorts = try c.decodeIfPresent([Sort].self, forKey: .sorts) ?? []
        self.filters = try c.decodeIfPresent([Facet].self, forKey: .filters) ?? []
    }

    private enum CodingKeys: String, CodingKey { case sorts, filters }

    public var isEmpty: Bool { sorts.isEmpty && filters.isEmpty }

    func validate() throws {
        guard sorts.allSatisfy({ !$0.id.isEmpty }), Set(sorts.map(\.id)).count == sorts.count else {
            throw RefError.invalidManifest("search.sorts 的 id 不能为空或重复")
        }
        guard filters.allSatisfy({ !$0.key.isEmpty }), Set(filters.map(\.key)).count == filters.count else {
            throw RefError.invalidManifest("search.filters 的 key 不能为空或重复")
        }
        for facet in filters {
            guard !facet.options.isEmpty,
                facet.options.allSatisfy({ !$0.value.isEmpty }),
                Set(facet.options.map(\.value)).count == facet.options.count
            else {
                throw RefError.invalidManifest("search.filters「\(facet.key)」的 options 不能为空，value 不能为空或重复")
            }
        }
    }
}

/// 一次搜索的筛选条件，原样交给 ref 的 `search(keyword, query)`。
public struct RefSearchQuery: Hashable, Sendable {
    /// 选中的排序 id；`nil` 表示用 ref 的默认排序。
    public var sort: String?
    /// 筛选组 key → 选中的 option value。没选的组不出现。
    public var filters: [String: String]

    public static let empty = RefSearchQuery()

    public init(sort: String? = nil, filters: [String: String] = [:]) {
        self.sort = sort
        self.filters = filters
    }

    public var hasFilters: Bool { !filters.isEmpty }

    /// 传给 JS 的形态：`{ sort: "hot" | null, filters: { year: "2025" } }`。
    var jsValue: [String: Any] {
        ["sort": sort as Any? ?? NSNull(), "filters": filters]
    }
}
