import Foundation
import Testing
@testable import CezzuKit

@Suite("PlaybackRequest")
struct PlaybackRequestTests {
    @Test("exposes previous and next episode requests on the same road")
    func neighborEpisodeRequests() throws {
        let request = Self.makeRequest(episodeIndex: 1)

        let previous = try #require(request.previousEpisodeRequest)
        let next = try #require(request.nextEpisodeRequest)

        #expect(previous.episodeIndex == 0)
        #expect(previous.episode.title == "第 1 集")
        #expect(next.episodeIndex == 2)
        #expect(next.episode.title == "第 3 集")
    }

    @Test("returns nil at both road boundaries")
    func neighborRequestsStopAtEdges() {
        let first = Self.makeRequest(episodeIndex: 0)
        let last = Self.makeRequest(episodeIndex: 2)

        #expect(first.previousEpisodeRequest == nil)
        #expect(first.hasPreviousEpisode == false)
        #expect(last.nextEpisodeRequest == nil)
        #expect(last.hasNextEpisode == false)
    }

    static func makeRequest(episodeIndex: Int, roadIndex: Int = 0) -> PlaybackRequest {
        func road(_ index: Int, prefix: String) -> EpisodeRoad {
            EpisodeRoad(
                index: index, label: "线路 \(index + 1)",
                episodes: (0..<3).map {
                    Episode(title: "第 \($0 + 1) 集", url: RefURL.make(refID: "demo", id: "\(prefix)\($0 + 1)"), index: $0)
                })
        }
        let detail = AnimeDetail(
            title: "测试剧集",
            detailURL: RefURL.make(refID: "demo", id: "item-1"),
            ruleName: "demo",
            roads: [road(0, prefix: "a"), road(1, prefix: "b")]
        )
        return PlaybackRequest(anime: detail, roadIndex: roadIndex, episodeIndex: episodeIndex, refID: "demo")
    }
}
