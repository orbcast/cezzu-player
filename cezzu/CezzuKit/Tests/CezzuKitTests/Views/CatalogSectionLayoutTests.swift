import CoreGraphics
import Testing
@testable import CezzuKit

@Suite("CatalogSectionLayout")
struct CatalogSectionLayoutTests {

    @Test("cardHeight is cover (3:4) plus the title block")
    func cardHeightComposition() {
        let width: CGFloat = 130
        let expected = width / CatalogCardLayout.coverAspectRatio
            + CatalogCardLayout.spacing
            + CatalogCardLayout.titleHeight
        #expect(CatalogSectionLayout.cardHeight(cardWidth: width) == expected)
    }

    @Test("the default cardHeight matches the compact card width")
    func defaultMatchesCompactWidth() {
        #expect(
            CatalogSectionLayout.cardHeight
                == CatalogSectionLayout.cardHeight(cardWidth: CatalogSectionLayout.cardWidth)
        )
    }

    @Test("the wide-screen card is taller than the compact one")
    func regularCardIsLarger() {
        #expect(CatalogSectionLayout.regularCardWidth > CatalogSectionLayout.cardWidth)
        #expect(
            CatalogSectionLayout.cardHeight(cardWidth: CatalogSectionLayout.regularCardWidth)
                > CatalogSectionLayout.cardHeight
        )
    }

    @Test("a zero width degenerates to the title block only")
    func zeroWidth() {
        #expect(
            CatalogSectionLayout.cardHeight(cardWidth: 0)
                == CatalogCardLayout.spacing + CatalogCardLayout.titleHeight
        )
    }
}
