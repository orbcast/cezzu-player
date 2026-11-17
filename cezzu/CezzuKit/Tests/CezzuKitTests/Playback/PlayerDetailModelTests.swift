import Foundation
import Testing

@testable import CezzuKit

/// 播放页详情栏：当前源预置、从当前 ref 找备选源、拉选集、请求里带 refID。
@Suite("PlayerDetailModel")
@MainActor
struct PlayerDetailModelTests {
    /// 只实现详情栏会用到的部分；其余按协议给空实现。
    struct StubAPI: CatalogAPIClientProtocol {
        func trending(limit: Int, offset: Int) async throws -> [CatalogItem] { [] }
        func search(tag: String, limit: Int, offset: Int) async throws -> [CatalogItem] { [] }
        func search(keyword: String, query: RefSearchQuery, limit: Int, offset: Int)
            async throws -> [CatalogItem] { [] }
        func fetchSubject(subjectID: Int) async throws -> CatalogItem { throw CatalogAPIError.unknownSubject }
        func fetchTags(subjectID: Int) async throws -> [CatalogTag] { [] }
        func fetchCharacters(subjectID: Int) async throws -> [CatalogRelatedCharacter] { [] }
        func fetchPersons(subjectID: Int) async throws -> [CatalogRelatedPerson] { [] }
        func fetchComments(subjectID: Int) async throws -> [CatalogSubjectComment] { [] }
        func fetchReviews(subjectID: Int) async throws -> [CatalogSubjectReview] { [] }
        func fetchEpisodes(subjectID: Int) async throws -> [CatalogEpisode] { [] }
        func fetchEpisodeComments(episodeID: Int) async throws -> [CatalogEpisodeComment] { [] }
    }

    struct FakeRef: Ref {
        let manifest = RefManifest(id: "demo", name: "Demo", version: "1", allowedHosts: ["example.invalid"])
        var results: [String: [RefSearchItem]] = [:]
        var roads: [String: [RefRoad]] = [:]

        func search(_ keyword: String) async throws -> [RefSearchItem] { results[keyword] ?? [] }
        func episodes(id: String) async throws -> [RefRoad] { roads[id] ?? [] }
        func resolve(episodeID: String) async throws -> RefMedia { throw RefError.timeout }
    }

    @Test("sync keeps current request available before remote source search")
    func syncSeedsCurrentSource() throws {
        let request = Self.makeRequest(group: "SiteA", episodeIndex: 1)
        let model = PlayerDetailModel(currentRequest: request, backend: nil, api: StubAPI())

        #expect(model.sources.map(\.ruleName) == ["SiteA"])
        #expect(model.selectedSource?.ruleName == "SiteA")
        #expect(model.selectedRoadIndex == 0)

        let selected = try #require(model.playbackRequest(episodeIndex: 1)).episode
        #expect(selected.title == "第 2 集")
    }

    @Test("loadSourcesIfNeeded finds alternate sources in the current ref and fetches their episodes")
    func loadFindsAlternateSources() async throws {
        var ref = FakeRef()
        ref.results["孤独摇滚"] = [RefSearchItem(id: "alt-1", title: "孤独摇滚", group: "SiteB")]
        ref.roads["alt-1"] = [RefRoad(name: "线路 A", episodes: [RefEpisode(id: "ep-1", title: "第 1 集")])]

        let model = PlayerDetailModel(
            currentRequest: Self.makeRequest(group: "SiteA", episodeIndex: 0),
            backend: RefSourceBackend(ref: ref),
            api: StubAPI()
        )

        await model.loadSourcesIfNeeded()
        #expect(model.sources.map(\.ruleName).contains("SiteB"))

        let alternate = try #require(model.sources.first(where: { $0.ruleName == "SiteB" }))
        await model.selectSource(alternate.id)
        let request = try #require(model.playbackRequest(episodeIndex: 0))

        #expect(request.refID == "demo")
        #expect(request.anime.ruleName == "SiteB")
        let episodeTarget = try #require(RefURL.parse(request.episode.url))
        #expect(episodeTarget.id == "ep-1")
    }

    @Test("requests built for the current source keep the playing request's ref")
    func requestKeepsRefID() throws {
        let model = PlayerDetailModel(
            currentRequest: Self.makeRequest(group: "SiteA", episodeIndex: 0), backend: nil, api: StubAPI())
        let request = try #require(model.playbackRequest(episodeIndex: 1))
        #expect(request.refID == "demo")
    }

    // MARK: - Helpers

    private static func makeRequest(group: String, episodeIndex: Int) -> PlaybackRequest {
        let item = CatalogItem(
            id: 1, name: "Bocchi the Rock!", nameCn: "孤独摇滚", summary: "", airDate: "",
            rank: 0, ratingScore: 0, images: .empty, tags: [])
        let detail = AnimeDetail(
            title: "孤独摇滚",
            detailURL: RefURL.make(refID: "demo", id: "cur-1"),
            ruleName: group,
            roads: [
                EpisodeRoad(
                    index: 0, label: "线路 1",
                    episodes: (0..<2).map {
                        Episode(title: "第 \($0 + 1) 集", url: RefURL.make(refID: "demo", id: "cur-ep-\($0 + 1)"), index: $0)
                    })
            ]
        )
        return PlaybackRequest(anime: detail, roadIndex: 0, episodeIndex: episodeIndex, refID: "demo", item: item)
    }
}
