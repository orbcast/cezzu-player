import Foundation
import Testing

@testable import CezzuKit

private struct StubRef: Ref {
    let manifest = RefManifest(id: "demo", name: "Stub", version: "1", allowedHosts: ["example.invalid"])
    var media: @Sendable (String) throws -> RefMedia

    func search(_ keyword: String) async throws -> [RefSearchItem] { [] }
    func episodes(id: String) async throws -> [RefRoad] { [] }
    func resolve(episodeID: String) async throws -> RefMedia { try media(episodeID) }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

@Suite("PlaybackCoordinator")
@MainActor
struct PlaybackCoordinatorTests {
    @Test("resolve failures surface as a failed phase, not a crash")
    func resolveFailureBecomesFailedPhase() async {
        let coordinator = PlaybackCoordinator()
        let ref = StubRef { _ in throw RefError.timeout }

        await coordinator.startPlayback(PlaybackRequestTests.makeRequest(episodeIndex: 0), ref: ref, resume: false)

        guard case .failed(let message) = coordinator.phase else {
            Issue.record("expected failed, got \(coordinator.phase)")
            return
        }
        #expect(message.contains("超时"))
    }

    @Test("the episode id decoded from the episode URL is what reaches the ref")
    func resolveReceivesEpisodeID() async {
        let coordinator = PlaybackCoordinator()
        let seen = Seen()
        let ref = StubRef { id in
            seen.append(id)
            throw RefError.invalidResult("stop here")
        }

        await coordinator.startPlayback(
            PlaybackRequestTests.makeRequest(episodeIndex: 1, roadIndex: 1), ref: ref, resume: false)

        #expect(seen.values == ["b2"])
    }

    @Test("a failed episode is re-resolved on retry instead of reusing a stale result")
    func retryAfterFailureResolvesAgain() async {
        let coordinator = PlaybackCoordinator()
        let seen = Seen()
        let ref = StubRef { id in
            seen.append(id)
            throw RefError.timeout
        }
        let request = PlaybackRequestTests.makeRequest(episodeIndex: 0)

        await coordinator.startPlayback(request, ref: ref, resume: false)
        await coordinator.startPlayback(request, ref: ref, resume: false)

        #expect(seen.values == ["a1", "a1"])
    }

    @Test("an episode URL that is not a ref URL fails cleanly")
    func nonRefURLFails() async {
        let coordinator = PlaybackCoordinator()
        let ref = StubRef { _ in throw RefError.timeout }
        var request = PlaybackRequestTests.makeRequest(episodeIndex: 0)
        request.anime.roads[0].episodes[0].url = URL(string: "https://example.invalid/x")!

        await coordinator.startPlayback(request, ref: ref, resume: false)

        guard case .failed = coordinator.phase else {
            Issue.record("expected failed")
            return
        }
    }
}
