import SwiftUI

/// 剧集宫格布局参数。按「固定 item 首选宽度」让 `LazyVGrid` 自适应列数。
enum CatalogGridLayout {
    static let horizontalSpacing: CGFloat = 14
    static let verticalSpacing: CGFloat = 18
    /// 单卡最小宽度。列数 = 容器能放下多少个 ≥ 此宽度的 cell。
    static let preferredItemWidth: CGFloat = 150
    /// 单卡最大宽度。剩余空间不够再塞一列时，cell 最多涨到这里，避免被拉成海报墙。
    static let maximumItemWidth: CGFloat = 200

    static var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: preferredItemWidth, maximum: maximumItemWidth),
                spacing: horizontalSpacing,
                alignment: .top
            )
        ]
    }

    /// 根据容器可用宽度估算列数（测试 / 调试用；真实布局交给 `GridItem.adaptive`）。
    ///
    /// 公式：`n * preferred + (n - 1) * spacing ≤ width`
    /// → `n ≤ (width + spacing) / (preferred + spacing)`
    static func columnCount(forWidth width: CGFloat) -> Int {
        let minimumColumnCount = 1
        guard width.isFinite, width > 0 else { return minimumColumnCount }
        let unit = preferredItemWidth + horizontalSpacing
        let raw = Int(floor((width + horizontalSpacing) / unit))
        return max(minimumColumnCount, raw)
    }
}

/// 响应式剧集宫格。用 `GridItem.adaptive` 按首选宽度自动算列数；
/// footer 放在 grid 下方，避免再依赖 GeometryReader 量宽（ScrollView 里容易量错、锁死 2 列）。
public struct CatalogGrid<Footer: View>: View {
    private let items: [CatalogItem]
    private let onTapItem: (CatalogItem) -> Void
    private let onLoadMore: (CatalogItem) async -> Void
    private let footer: Footer

    public init(
        items: [CatalogItem],
        onTapItem: @escaping (CatalogItem) -> Void,
        onLoadMore: @escaping (CatalogItem) async -> Void,
        @ViewBuilder footer: () -> Footer
    ) {
        self.items = items
        self.onTapItem = onTapItem
        self.onLoadMore = onLoadMore
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CatalogGridLayout.verticalSpacing) {
            LazyVGrid(
                columns: CatalogGridLayout.columns,
                alignment: .leading,
                spacing: CatalogGridLayout.verticalSpacing
            ) {
                ForEach(items) { item in
                    Button {
                        onTapItem(item)
                    } label: {
                        CatalogCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .catalogPeek(item: item) { onTapItem(item) }
                    .task {
                        await onLoadMore(item)
                    }
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
