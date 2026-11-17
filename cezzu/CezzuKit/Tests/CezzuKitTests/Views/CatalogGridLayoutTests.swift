import CoreGraphics
import Testing
@testable import CezzuKit

@Suite("CatalogGrid layout")
struct CatalogGridLayoutTests {
    @Test("falls back to one column when width is unknown or non-positive")
    func fallsBackForInvalidWidth() {
        #expect(CatalogGridLayout.columnCount(forWidth: 0) == 1)
        #expect(CatalogGridLayout.columnCount(forWidth: -10) == 1)
        #expect(CatalogGridLayout.columnCount(forWidth: .nan) == 1)
        #expect(CatalogGridLayout.columnCount(forWidth: .infinity) == 1)
    }

    @Test("fits a single preferred card on narrow phones")
    func singleColumnOnNarrowWidth() {
        let justOne = CatalogGridLayout.preferredItemWidth
        #expect(CatalogGridLayout.columnCount(forWidth: justOne) == 1)

        let almostTwo = 2 * CatalogGridLayout.preferredItemWidth
            + CatalogGridLayout.horizontalSpacing
            - 1
        #expect(CatalogGridLayout.columnCount(forWidth: almostTwo) == 1)
    }

    @Test("grows columns as the container gets wider")
    func growsWithWidth() {
        let spacing = CatalogGridLayout.horizontalSpacing
        let preferred = CatalogGridLayout.preferredItemWidth

        // 刚好塞下 3 列：3 * preferred + 2 * spacing
        let threeColumnWidth = 3 * preferred + 2 * spacing
        #expect(CatalogGridLayout.columnCount(forWidth: threeColumnWidth) == 3)

        // 差 1pt 不够 4 列，仍是 3
        let almostFour = 4 * preferred + 3 * spacing - 1
        #expect(CatalogGridLayout.columnCount(forWidth: almostFour) == 3)

        // 刚好 4 列
        let fourColumnWidth = 4 * preferred + 3 * spacing
        #expect(CatalogGridLayout.columnCount(forWidth: fourColumnWidth) == 4)

        // 宽屏 Mac 窗口可到 7 列
        let wide: CGFloat = 1200
        #expect(CatalogGridLayout.columnCount(forWidth: wide) == 7)
    }

    @Test("adaptive column config uses preferred min/max widths")
    func adaptiveColumnsUsePreferredBounds() {
        #expect(CatalogGridLayout.columns.count == 1)
        guard case let .adaptive(minimum: minimum, maximum: maximum) = CatalogGridLayout.columns[0].size else {
            Issue.record("expected a single adaptive GridItem")
            return
        }
        #expect(minimum == CatalogGridLayout.preferredItemWidth)
        #expect(maximum == CatalogGridLayout.maximumItemWidth)
    }

    @Test("actual cell width stays at least preferred when columns fit")
    func cellWidthAtLeastPreferredWhenFit() {
        let spacing = CatalogGridLayout.horizontalSpacing
        let preferred = CatalogGridLayout.preferredItemWidth
        let width: CGFloat = 4 * preferred + 3 * spacing + 20
        let columns = CatalogGridLayout.columnCount(forWidth: width)
        let cellWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        #expect(cellWidth + 0.001 >= preferred)
    }
}
