import Foundation
import Testing
@testable import CezzuKit

@Suite("DanmakuProvider")
struct DanmakuProviderTests {

    private func request(episodeTitles: [String], episodeIndex: Int) -> PlaybackRequest {
        let detail = AnimeDetail(
            title: "测试剧集",
            detailURL: RefURL.make(refID: "demo", id: "item"),
            ruleName: "demo",
            roads: [
                EpisodeRoad(
                    index: 0, label: "线路 1",
                    episodes: episodeTitles.enumerated().map {
                        Episode(title: $1, url: RefURL.make(refID: "demo", id: "e\($0)"), index: $0)
                    })
            ])
        return PlaybackRequest(anime: detail, roadIndex: 0, episodeIndex: episodeIndex, refID: "demo")
    }

    @Test("episode matcher prefers number parsed from title")
    func episodeMatcherParsesTitle() {
        #expect(DanmakuEpisodeMatcher.episodeNumber(for: request(episodeTitles: ["第12集"], episodeIndex: 0)) == 12)
    }

    @Test("episode matcher falls back to one based episode index")
    func episodeMatcherFallsBackToIndex() {
        #expect(DanmakuEpisodeMatcher.episodeNumber(for: request(episodeTitles: ["正片", "正片"], episodeIndex: 1)) == 2)
    }

    @Test("comment payload decodes Dandan p field")
    func commentPayloadDecoding() {
        let comment = DanmakuComment(payload: "12.5,1,16777215,DanDanPlay", text: "测试弹幕")

        #expect(comment != nil)
        #expect(comment?.text == "测试弹幕")
        #expect(comment?.time == 12.5)
        #expect(comment?.type == 1)
        #expect(comment?.colorRGB == 16_777_215)
        #expect(comment?.source == "DanDanPlay")
    }

    @Test("episode search tolerates error envelope without animes field")
    func searchMissingField() throws {
        let data = Data(#"{"errorCode":1,"success":false}"#.utf8)
        #expect(try DanmakuResponseParser.searchResults(from: data).isEmpty)
    }

    @Test("episode search decodes anime episodes and tolerates missing episode list")
    func searchDecodesEpisodes() throws {
        let data = Data(#"{"animes":[{"animeId":1,"episodes":[{"episodeId":17580001,"episodeTitle":"第1话 起"}]},{"animeId":2}]}"#.utf8)
        let animes = try DanmakuResponseParser.searchResults(from: data)

        #expect(animes.count == 2)
        #expect(animes[0].episodes.first?.episodeID == 17580001)
        #expect(animes[1].episodes.isEmpty)
    }

    @Test("comment response tolerates missing comments field")
    func commentsMissingField() throws {
        let data = Data(#"{"errorCode":0,"success":true,"count":0}"#.utf8)

        #expect(try DanmakuResponseParser.comments(from: data).isEmpty)
    }

    @Test("comment response decodes and sorts by time")
    func commentsDecodeSorted() throws {
        let data = Data(
            #"{"comments":[{"p":"20.0,1,16777215,a","m":"后"},{"p":"5.0,1,16777215,a","m":"先"}]}"#.utf8
        )
        let comments = try DanmakuResponseParser.comments(from: data)

        #expect(comments.map(\.text) == ["先", "后"])
    }

    @Test("malformed payload surfaces readable danmaku error")
    func malformedPayloadThrowsReadableError() {
        let data = Data("<html>502 Bad Gateway</html>".utf8)

        let thrown = #expect(throws: DanmakuError.self) {
            _ = try DanmakuResponseParser.comments(from: data)
        }
        #expect(thrown?.errorDescription == "DanDanPlay 返回的数据无法解析，本集暂无弹幕。")
    }

    @Test("custom credentials override built-in when toggle is on")
    func customCredentialsOverrideBuiltIn() {
        let snapshot = DanDanPlayCredentialsStore.Snapshot(
            useCustom: true,
            appID: "user-id",
            appSecret: "user-secret"
        )
        let credentials = DanDanPlayCredentials(
            bundle: .main,
            environment: ["DANDANPLAY_APP_ID": "builtin-id", "DANDANPLAY_APP_SECRET": "builtin-secret"],
            storeSnapshot: snapshot
        )

        #expect(credentials?.appID == "user-id")
        #expect(credentials?.appSecret == "user-secret")
    }

    @Test("custom credentials fall back to built-in when toggle is off")
    func customCredentialsFallbackToBuiltIn() {
        let snapshot = DanDanPlayCredentialsStore.Snapshot(
            useCustom: false,
            appID: "user-id",
            appSecret: "user-secret"
        )
        let credentials = DanDanPlayCredentials(
            bundle: .main,
            environment: ["DANDANPLAY_APP_ID": "builtin-id", "DANDANPLAY_APP_SECRET": "builtin-secret"],
            storeSnapshot: snapshot
        )

        #expect(credentials?.appID == "builtin-id")
        #expect(credentials?.appSecret == "builtin-secret")
    }

    @Test("custom credentials ignored when toggle on but fields empty")
    func customCredentialsIgnoredWhenEmpty() {
        let snapshot = DanDanPlayCredentialsStore.Snapshot(
            useCustom: true,
            appID: "   ",
            appSecret: ""
        )
        let credentials = DanDanPlayCredentials(
            bundle: .main,
            environment: ["DANDANPLAY_APP_ID": "builtin-id", "DANDANPLAY_APP_SECRET": "builtin-secret"],
            storeSnapshot: snapshot
        )

        #expect(credentials?.appID == "builtin-id")
        #expect(credentials?.appSecret == "builtin-secret")
    }

    @Test("proxy snapshot resolves valid https URL")
    func proxySnapshotResolvesValidURL() {
        let snapshot = DanmakuProxyStore.Snapshot(
            useProxy: true,
            proxyURL: "https://proxy.example.com/"
        )
        #expect(snapshot.resolvedBaseURL?.absoluteString == "https://proxy.example.com")
    }

    @Test("proxy snapshot returns nil when toggle is off")
    func proxySnapshotDisabled() {
        let snapshot = DanmakuProxyStore.Snapshot(
            useProxy: false,
            proxyURL: "https://proxy.example.com"
        )
        #expect(snapshot.resolvedBaseURL == nil)
    }

    @Test("proxy snapshot rejects malformed URLs")
    func proxySnapshotRejectsMalformed() {
        let cases = ["", "   ", "not-a-url", "ftp://example.com", "http://"]
        for raw in cases {
            let snapshot = DanmakuProxyStore.Snapshot(useProxy: true, proxyURL: raw)
            #expect(snapshot.resolvedBaseURL == nil, "should reject \(raw)")
        }
    }

    @Test("credentials init returns nil when no source provides values")
    func credentialsNilWhenNothingConfigured() {
        let snapshot = DanDanPlayCredentialsStore.Snapshot(useCustom: false, appID: "", appSecret: "")
        let credentials = DanDanPlayCredentials(
            bundle: .main,
            environment: [:],
            storeSnapshot: snapshot
        )

        #expect(credentials == nil)
    }
}
