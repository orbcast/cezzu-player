import SwiftUI

// MARK: - 视觉令牌

/// 搜索页的视觉令牌。与首页 / 详情页同属影院式外观：暗底 + 顶部一层色光，
/// 分层靠字重和间距，不再堆亮色面板。
enum SearchStyle {
    static let background = RegularShellLayout.cinemaBackground
    /// 顶部光晕，取首页 banner 缺图时的同一支色，保证两页调子一致。
    static let glow = CoverColorPalette.fallback.lifted.color

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.70)
    static let textTertiary = Color.white.opacity(0.46)
    static let surface = Color.white.opacity(0.08)
    static let surfaceRaised = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.12)

    static let facetPanelRadius: CGFloat = 18
    static let panelTransition: Animation = .easeOut(duration: 0.22)
}

/// 宽窄屏的尺度差异集中在这里，其余元件共用。
struct SearchMetrics {
    let horizontalPadding: CGFloat
    let titleSize: CGFloat
    let fieldHeight: CGFloat
    let sectionSpacing: CGFloat
    let cardWidth: CGFloat

    static let compact = SearchMetrics(
        horizontalPadding: 20,
        titleSize: 30,
        fieldHeight: 52,
        sectionSpacing: 22,
        cardWidth: CatalogSectionLayout.cardWidth
    )

    static let regular = SearchMetrics(
        horizontalPadding: RegularHomeHeroLayout.horizontalPadding,
        titleSize: 42,
        fieldHeight: 60,
        sectionSpacing: 30,
        cardWidth: CatalogSectionLayout.regularCardWidth
    )
}

// MARK: - 纯数据：筛选摘要与文案

/// 已启用筛选的摘要 chip（不含排序 —— 排序永远有值，不算"筛选"）。
struct SearchActiveFilter: Identifiable, Equatable {
    /// 筛选组 key，摘掉它就清掉这一组。
    let id: String
    let title: String

    /// 按 ref 声明的顺序列出选中的筛选：`年份 · 2025`。选中的值已不在声明里时不显示。
    static func chips(spec: RefSearchSpec, selections: [String: String]) -> [SearchActiveFilter] {
        spec.filters.compactMap { facet in
            guard let value = selections[facet.key],
                let option = facet.options.first(where: { $0.value == value })
            else { return nil }
            return SearchActiveFilter(id: facet.key, title: "\(facet.label) · \(option.label)")
        }
    }
}

/// 结果区那行计数文案。
enum SearchResultsSummary {
    static func text(count: Int, hasMore: Bool, keyword: String) -> String {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = "\(count)\(hasMore ? "+" : "")"
        guard !trimmed.isEmpty else { return "共 \(amount) 条结果" }
        return "“\(trimmed)” · \(amount) 条结果"
    }
}

/// 筛选条上可展开的面。同一时刻只展开一个。
enum SearchFacet: Hashable {
    case sort
    case filter(key: String)

    var systemImage: String {
        switch self {
        case .sort: return "arrow.up.arrow.down"
        case .filter: return "line.3.horizontal.decrease"
        }
    }
}

// MARK: - 元件

/// 整页底：影院黑 + 顶部一层色光。
struct SearchAmbientBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            SearchStyle.background
            LinearGradient(
                colors: [
                    SearchStyle.glow.opacity(0.34),
                    SearchStyle.glow.opacity(0.10),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 360)
        }
        .ignoresSafeArea()
    }
}

/// 分区标题：拉丁小字 eyebrow + 中文粗标题，和首页分区行同一套排版。
struct SearchSectionHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(SearchStyle.textPrimary)
            Text(eyebrow)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(SearchStyle.textTertiary)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SearchSectionHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String) {
        self.init(eyebrow: eyebrow, title: title) { EmptyView() }
    }
}

/// chip 的纯外观层。Button / 展开面板都套它，保证选中态一致。
struct SearchChipLabel: View {
    let title: String
    var systemImage: String? = nil
    var detail: String? = nil
    var isSelected: Bool = false
    var isRemovable: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
            }
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
            if let detail {
                Text(detail)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .black.opacity(0.6) : SearchStyle.textPrimary)
            }
            if isRemovable {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.black) : AnyShapeStyle(SearchStyle.textSecondary))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            Capsule(style: .continuous)
                .fill(isSelected ? Color.white : SearchStyle.surface)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(isSelected ? Color.clear : SearchStyle.hairline, lineWidth: 1)
                }
        }
        .contentShape(Capsule(style: .continuous))
    }
}

/// 可点的 chip。
struct SearchChip: View {
    let title: String
    var systemImage: String? = nil
    var detail: String? = nil
    var isSelected: Bool = false
    var isRemovable: Bool = false
    var accessibilityTitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SearchChipLabel(
                title: title,
                systemImage: systemImage,
                detail: detail,
                isSelected: isSelected,
                isRemovable: isRemovable
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle ?? [title, detail].compactMap { $0 }.joined(separator: " "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeOut(duration: 0.16), value: isSelected)
    }
}

/// 大搜索框。回车即搜，输入时防抖自动搜，右侧圆钮兜住"就是要现在搜"。
struct SearchField: View {
    @Binding var text: String
    var height: CGFloat
    var prompt: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var onChange: () -> Void
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isFocused.wrappedValue ? SearchStyle.textPrimary : SearchStyle.textTertiary)

            TextField("", text: $text, prompt: promptText)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SearchStyle.textPrimary)
                .tint(.white)
                .focused(isFocused)
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .onChange(of: text) { _, _ in onChange() }

            if !text.isEmpty {
                Button {
                    onClear()
                    isFocused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(SearchStyle.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空输入")

                Button(action: onSubmit) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: height)
        .background {
            Capsule(style: .continuous)
                .fill(SearchStyle.surface)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isFocused.wrappedValue ? Color.white.opacity(0.45) : SearchStyle.hairline,
                            lineWidth: 1
                        )
                }
        }
        .animation(.easeOut(duration: 0.18), value: isFocused.wrappedValue)
        .animation(.easeOut(duration: 0.18), value: text.isEmpty)
    }

    private var promptText: Text {
        Text(prompt).foregroundColor(SearchStyle.textTertiary)
    }
}

/// 展开式筛选面板的容器。
struct SearchFacetPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: SearchStyle.facetPanelRadius, style: .continuous)
                    .fill(SearchStyle.surface)
                    .overlay {
                        RoundedRectangle(cornerRadius: SearchStyle.facetPanelRadius, style: .continuous)
                            .strokeBorder(SearchStyle.hairline, lineWidth: 1)
                    }
            }
    }
}
