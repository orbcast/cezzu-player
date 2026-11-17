import Foundation

/// cezzu-refs 清单。一个 ref = 清单 + 一段 JS 脚本（或旧规则适配）。
/// 协议的唯一权威定义在 cezzu-refs 仓库的 spec，这里只做解码与校验。
public struct RefManifest: Codable, Hashable, Sendable, Identifiable {
    /// 播放器当前支持的协议版本。清单声明的 `refsApi` 高于它时拒绝加载。
    public static let supportedAPI = 1

    public enum Capability: String, Codable, Hashable, Sendable {
        /// 开放 `crypto.*`（HMAC / 哈希 / 随机数 / base64）。
        case crypto
        /// 允许 `resolve` 返回 `{sniff: 页面URL}`，交给宿主 WebView 嗅探。
        case sniff
    }

    public enum Kind: String, Codable, Hashable, Sendable {
        /// `entry` 是一段 JS 脚本。
        case script
        /// `entry` 是一个规则集 JSON（旧 XPath/JSONPath 规则的数组），由内置适配层解释。
        /// 规则集天然跨多个站点，所以不受 `allowedHosts` 逐域名约束。
        case legacyRules = "legacy-rules"
    }

    /// ref 需要用户提供的配置项（只声明名字，值由用户在添加时填写，存在本机）。
    public struct ConfigField: Codable, Hashable, Sendable {
        public var key: String
        public var label: String
        /// 敏感值：界面用密码框，且不在任何地方回显。
        public var secret: Bool
        public var required: Bool

        public init(key: String, label: String? = nil, secret: Bool = false, required: Bool = true) {
            self.key = key
            self.label = label ?? key
            self.secret = secret
            self.required = required
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.key = try c.decode(String.self, forKey: .key)
            self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
            self.secret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? false
            self.required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        }

        private enum CodingKeys: String, CodingKey { case key, label, secret, required }
    }

    public var refsApi: Int
    public var kind: Kind
    public var id: String
    public var name: String
    public var version: String
    /// 脚本相对清单 URL 的路径。
    public var entry: String
    /// 脚本只能请求这些域名（含其子域）。
    public var allowedHosts: [String]
    public var capabilities: [Capability]
    public var config: [ConfigField]
    /// 声明支持的搜索排序 / 筛选；没声明就是只有关键词搜索。
    public var search: RefSearchSpec

    public init(
        refsApi: Int = RefManifest.supportedAPI,
        kind: Kind = .script,
        id: String,
        name: String,
        version: String,
        entry: String = "main.js",
        allowedHosts: [String],
        capabilities: [Capability] = [],
        config: [ConfigField] = [],
        search: RefSearchSpec = .none
    ) {
        self.refsApi = refsApi
        self.kind = kind
        self.id = id
        self.name = name
        self.version = version
        self.entry = entry
        self.allowedHosts = allowedHosts
        self.capabilities = capabilities
        self.config = config
        self.search = search
    }

    private enum CodingKeys: String, CodingKey {
        case refsApi, kind, id, name, version, entry, allowedHosts, capabilities, config, search
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.refsApi = try c.decode(Int.self, forKey: .refsApi)
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .script
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.version = try c.decode(String.self, forKey: .version)
        self.entry = try c.decodeIfPresent(String.self, forKey: .entry) ?? "main.js"
        self.allowedHosts = try c.decodeIfPresent([String].self, forKey: .allowedHosts) ?? []
        self.capabilities = try c.decodeIfPresent([Capability].self, forKey: .capabilities) ?? []
        self.config = try c.decodeIfPresent([ConfigField].self, forKey: .config) ?? []
        self.search = try c.decodeIfPresent(RefSearchSpec.self, forKey: .search) ?? .none
    }

    public func validate() throws {
        guard refsApi <= Self.supportedAPI else {
            throw RefError.unsupportedAPI(required: refsApi, supported: Self.supportedAPI)
        }
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw RefError.invalidManifest("id 只能包含字母、数字、- 和 _")
        }
        for field in config {
            guard !field.key.isEmpty, field.key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                !(field.key.first?.isNumber ?? false)
            else {
                throw RefError.invalidManifest("config 的 key 只能是字母、数字、下划线，且不能以数字开头：\(field.key)")
            }
        }
        guard Set(config.map(\.key)).count == config.count else {
            throw RefError.invalidManifest("config 的 key 不能重复")
        }
        try search.validate()
        guard kind == .legacyRules || !allowedHosts.isEmpty else {
            throw RefError.invalidManifest("allowedHosts 不能为空")
        }
    }

    /// `host` 是否被 `allowedHosts` 允许（精确匹配或子域）。
    public func allows(host: String) -> Bool {
        let host = host.lowercased()
        return allowedHosts.contains { entry in
            let entry = entry.lowercased()
            return host == entry || host.hasSuffix("." + entry)
        }
    }
}
