import Testing
@testable import CezzuKit

@Suite("Search chrome 筛选摘要与文案")
struct SearchChromeTests {
    private let spec = RefSearchSpec(filters: [
        .init(key: "year", label: "年份", options: [.init(value: "2025", label: "2025 年")]),
        .init(key: "area", label: "地区", options: [.init(value: "cn", label: "大陆")]),
    ])

    @Test("没有任何筛选时摘要为空")
    func activeFilterChipsEmpty() {
        #expect(SearchActiveFilter.chips(spec: spec, selections: [:]).isEmpty)
        #expect(SearchActiveFilter.chips(spec: .none, selections: [:]).isEmpty)
    }

    @Test("摘要按 ref 声明的顺序排列，而不是选择的先后")
    func activeFilterChipsFollowSpecOrder() {
        let chips = SearchActiveFilter.chips(spec: spec, selections: ["area": "cn", "year": "2025"])
        #expect(chips.map(\.title) == ["年份 · 2025 年", "地区 · 大陆"])
        #expect(chips.map(\.id) == ["year", "area"])
    }

    @Test("选中的值已不在声明里（换了 ref）时不显示")
    func activeFilterChipsIgnoreStaleSelections() {
        let chips = SearchActiveFilter.chips(spec: spec, selections: ["year": "1999", "gone": "x"])
        #expect(chips.isEmpty)
    }

    @Test("结果计数：有关键词时带上关键词，还有下一页时加 +")
    func resultsSummary() {
        #expect(SearchResultsSummary.text(count: 20, hasMore: true, keyword: "轻音") == "“轻音” · 20+ 条结果")
        #expect(SearchResultsSummary.text(count: 3, hasMore: false, keyword: "轻音") == "“轻音” · 3 条结果")
    }

    @Test("结果计数：只按筛选搜（关键词空白）时不显示空引号")
    func resultsSummaryWithoutKeyword() {
        #expect(SearchResultsSummary.text(count: 0, hasMore: false, keyword: "   ") == "共 0 条结果")
        #expect(SearchResultsSummary.text(count: 40, hasMore: true, keyword: "") == "共 40+ 条结果")
    }
}
