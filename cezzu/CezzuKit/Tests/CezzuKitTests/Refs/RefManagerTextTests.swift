import Testing
@testable import CezzuKit

@Suite("RefManagerText")
struct RefManagerTextTests {
    @Test("a script ref shows version, kind and how many hosts it may reach")
    func scriptSummary() {
        let manifest = RefManifest(
            id: "a", name: "A", version: "0.2", allowedHosts: ["a.example.invalid", "b.example.invalid"])
        #expect(RefManagerText.summary(for: manifest) == "v0.2 · 脚本 · 可访问 2 个域名")
    }

    @Test("a legacy rule set does not claim a host count, and a ref with config says so")
    func legacyAndConfigSummary() {
        let legacy = RefManifest(kind: .legacyRules, id: "l", name: "L", version: "1", allowedHosts: [])
        #expect(RefManagerText.summary(for: legacy) == "v1 · 规则集")

        let configured = RefManifest(
            id: "c", name: "C", version: "3", allowedHosts: [], config: [.init(key: "k")])
        #expect(RefManagerText.summary(for: configured) == "v3 · 脚本 · 需要配置")
    }
}
