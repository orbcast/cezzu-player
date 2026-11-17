import Testing
@testable import CezzuKit

@Suite("RefGate")
struct RefGateTests {
    @Test("no installed ref blocks the app, any installed ref lets it through")
    func gate() {
        #expect(RefGate.isRequired(installed: []))
        let one = RefManifest(id: "a", name: "A", version: "1", allowedHosts: [])
        #expect(!RefGate.isRequired(installed: [one]))
    }
}
