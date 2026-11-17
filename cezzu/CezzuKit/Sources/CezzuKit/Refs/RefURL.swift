import Foundation

/// 把 `(refID, 条目或集的 id)` 编码成 URL，让原有以 `URL` 传递详情页 / 播放页的路径
/// （`SearchResult.detailURL`、`Episode.url`）不用改类型。id 对播放器是不透明的。
public enum RefURL {
    static let scheme = "cezzu-ref"

    public static func make(refID: String, id: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.percentEncodedPath = "/" + encode(refID) + "/" + encode(id)
        return components.url ?? URL(string: "\(scheme):///")!
    }

    public static func parse(_ url: URL) -> (refID: String, id: String)? {
        guard url.scheme == scheme,
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
        else { return nil }
        // 去掉开头的 "/"，只切第一个 "/"：id 可以是空串。
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, let refID = parts[0].removingPercentEncoding,
            let id = parts[1].removingPercentEncoding
        else { return nil }
        return (refID, id)
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}
