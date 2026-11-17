import Foundation

/// 把旧的 XPath / JSONPath 规则集适配成一个 `Ref`。
///
/// 对外仍是统一的 `search / episodes / resolve`：
/// - `search` 并发跑集合内全部规则，每条结果带 `group = 规则名`；
/// - `episodes` 按结果 id 找回规则，抓详情页；
/// - `resolve` 返回 `.sniff`，把嗅探交给宿主 WebView，并带上规则里的 Referer / UA / cookies / 过滤正则。
public final class LegacyRuleRef: Ref, Sendable {
    public let manifest: RefManifest
    private let rules: [CezzuRule]
    private let engine: RuleEngine
    private let coordinator: SearchCoordinator

    public init(
        manifest: RefManifest,
        rules: [CezzuRule],
        engine: RuleEngine = LiveRuleEngine()
    ) throws {
        try manifest.validate()
        self.manifest = manifest
        self.rules = rules
        self.engine = engine
        self.coordinator = SearchCoordinator(engine: engine)
    }

    public static func decodeRules(from data: Data) throws -> [CezzuRule] {
        do {
            return try JSONDecoder().decode([CezzuRule].self, from: data)
        } catch {
            throw RefError.invalidManifest("规则集无法解析：\(error.localizedDescription)")
        }
    }

    public func search(_ keyword: String) async throws -> [RefSearchItem] {
        var items: [RefSearchItem] = []
        var captcha: RefError?
        for await update in coordinator.search(keyword: keyword, rules: rules) {
            switch update {
            case .ruleResults(_, let results):
                items += results.map {
                    RefSearchItem(
                        id: Self.encode(rule: $0.ruleName, url: $0.detailURL),
                        title: $0.title,
                        group: $0.ruleName
                    )
                }
            case .ruleCaptchaRequired(_, let url, let userAgent):
                captcha = captcha ?? .captchaChallenge(url: url, userAgent: userAgent)
            case .ruleStarted, .ruleFailed, .finished:
                break
            }
        }
        if items.isEmpty, let captcha { throw captcha }
        return items
    }

    public func episodes(id: String) async throws -> [RefRoad] {
        let (rule, url) = try decode(id)
        let roads = try await engine.fetchEpisodes(detailURL: url, with: rule)
        return roads.map { road in
            RefRoad(
                name: road.label,
                episodes: road.episodes.map {
                    RefEpisode(id: Self.encode(rule: rule.name, url: $0.url), title: $0.title)
                }
            )
        }
    }

    public func resolve(episodeID: String) async throws -> RefMedia {
        let (rule, page) = try decode(episodeID)
        var headers: [String: String] = [:]
        if rule.needsHeaderInjection {
            if !rule.referer.isEmpty { headers["Referer"] = rule.referer }
            headers["User-Agent"] = rule.userAgent.isEmpty ? RandomUA.next() : rule.userAgent
        }
        return .sniff(
            page: page,
            headers: headers,
            options: RefSniffOptions(
                userAgent: rule.userAgent,
                referer: rule.referer,
                cookies: rule.cookies,
                videoURLPattern: rule.videoURLPattern
            )
        )
    }

    // MARK: - id 编码

    private static let separator: Character = "\u{1F}"

    private static func encode(rule: String, url: URL) -> String {
        "\(rule)\(separator)\(url.absoluteString)"
    }

    private func decode(_ id: String) throws -> (CezzuRule, URL) {
        let parts = id.split(separator: Self.separator, maxSplits: 1).map(String.init)
        guard parts.count == 2, let url = URL(string: parts[1]),
            let rule = rules.first(where: { $0.name == parts[0] })
        else {
            throw RefError.invalidResult("无法识别的条目 id")
        }
        return (rule, url)
    }
}
