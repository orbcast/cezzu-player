import Foundation

/// 当前 ref 作为「播放源」的后端：给定标题关键字，搜出可播放的条目；给定条目，抓选集。
///
/// 对外保持 `SearchCoordinator.Update` 的形状，所以详情页 / 播放页原有的「按源分组、
/// 逐源出结果、单源失败不影响其他源、验证码重试」这套状态机不用改。
/// 一个 ref 内部有几个站点由 ref 自己决定：结果的 `group` 就是原来的「源名」。
public final class RefSourceBackend: Sendable {
    public let refID: String
    /// 在「源」这一级展示的名字：ref 没有分组时用它。
    public let name: String
    private let searchImpl: @Sendable ([String]) -> AsyncStream<SearchCoordinator.Update>
    private let episodesImpl: @Sendable (URL) async throws -> [EpisodeRoad]

    public init(ref: any Ref, timeoutSeconds: TimeInterval = 12) {
        let refID = ref.manifest.id
        let name = ref.manifest.name
        self.refID = refID
        self.name = name
        self.searchImpl = { keywords in
            Self.search(ref: ref, name: name, keywords: keywords, timeout: timeoutSeconds)
        }
        self.episodesImpl = { detailURL in
            try await Self.episodes(ref: ref, detailURL: detailURL, timeout: timeoutSeconds * 2)
        }
    }

    /// 测试用：直接注入搜索流和选集抓取。
    init(
        refID: String, name: String,
        search: @escaping @Sendable ([String]) -> AsyncStream<SearchCoordinator.Update>,
        episodes: @escaping @Sendable (URL) async throws -> [EpisodeRoad]
    ) {
        self.refID = refID
        self.name = name
        self.searchImpl = search
        self.episodesImpl = episodes
    }

    /// 多关键字并发搜索，结果流式推回。
    public func searchAll(keywords: [String]) -> AsyncStream<SearchCoordinator.Update> {
        searchImpl(keywords)
    }

    /// 抓某个搜索结果的选集：线路 × 集。集的 `url` 是 `RefURL`，播放时由 ref 解析成真正的流。
    public func fetchEpisodes(detailURL: URL) async throws -> [EpisodeRoad] {
        try await episodesImpl(detailURL)
    }

    private static func search(
        ref: any Ref, name: String, keywords: [String], timeout: TimeInterval
    ) -> AsyncStream<SearchCoordinator.Update> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.ruleStarted(name: name))
                await withTaskGroup(of: Void.self) { group in
                    for keyword in keywords {
                        group.addTask {
                            do {
                                let items = try await withTimeout(timeout) { try await ref.search(keyword) }
                                let results = items.map { item in
                                    SearchResult(
                                        title: item.title,
                                        detailURL: RefURL.make(refID: ref.manifest.id, id: item.id),
                                        ruleName: item.group ?? name)
                                }
                                continuation.yield(.ruleResults(name: name, results: results))
                            } catch is CancellationError {
                            } catch RefError.captchaChallenge(let url, let userAgent) {
                                continuation.yield(.ruleCaptchaRequired(name: name, url: url, userAgent: userAgent))
                            } catch {
                                continuation.yield(.ruleFailed(name: name, message: "\(error)"))
                            }
                        }
                    }
                }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func episodes(ref: any Ref, detailURL: URL, timeout: TimeInterval) async throws -> [EpisodeRoad] {
        guard let target = RefURL.parse(detailURL) else {
            throw RefError.invalidResult("无法识别的条目地址")
        }
        let roads = try await withTimeout(timeout) { try await ref.episodes(id: target.id) }
        return roads.enumerated().map { roadIndex, road in
            EpisodeRoad(
                index: roadIndex,
                label: road.name.isEmpty ? "线路 \(roadIndex + 1)" : road.name,
                episodes: road.episodes.enumerated().map { index, episode in
                    Episode(
                        title: episode.title,
                        url: RefURL.make(refID: ref.manifest.id, id: episode.id),
                        index: index)
                })
        }
    }

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw RefError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

extension RefStore {
    /// 当前 ref 的播放源后端；没有选中 ref 时为 nil。
    public func sourceBackend() -> RefSourceBackend? {
        current.map { RefSourceBackend(ref: $0) }
    }
}
