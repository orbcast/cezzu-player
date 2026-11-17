import SwiftUI

/// 一行筛选 chip + 展开面板。每个面只要一次点击就能看见全部候选值，选完即收。
///
/// 有什么面完全由当前 ref 的清单决定（`RefSearchSpec`）：没声明排序 / 筛选，这一条就不存在。
struct SearchFilterBar: View {
    @Bindable var model: SearchViewModel
    @Binding var expandedFacet: SearchFacet?

    private var spec: RefSearchSpec { model.spec }
    /// 只有一种排序等于没得选。
    private var showsSort: Bool { spec.sorts.count > 1 }

    var body: some View {
        if showsSort || !spec.filters.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if showsSort {
                            facetChip(.sort, title: "排序", detail: currentSortLabel)
                        }
                        ForEach(spec.filters) { facet in
                            facetChip(
                                .filter(key: facet.key), title: facet.label,
                                detail: selectedLabel(of: facet))
                        }

                        if model.hasActiveFilter {
                            SearchChip(title: "重置", systemImage: "arrow.counterclockwise") {
                                model.resetFilters()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let expandedFacet {
                    SearchFacetPanel { options(for: expandedFacet) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !activeFilters.isEmpty {
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(activeFilters) { filter in
                            SearchChip(
                                title: filter.title,
                                isSelected: true,
                                isRemovable: true,
                                accessibilityTitle: "移除筛选 \(filter.title)"
                            ) {
                                model.select(nil, forFilter: filter.id)
                            }
                        }
                    }
                }
            }
            .animation(SearchStyle.panelTransition, value: expandedFacet)
            .animation(SearchStyle.panelTransition, value: activeFilters)
        }
    }

    private var activeFilters: [SearchActiveFilter] {
        SearchActiveFilter.chips(spec: spec, selections: model.selections)
    }

    /// 没选排序时显示 ref 的默认（第一项）。
    private var currentSortLabel: String? {
        let id = model.selectedSort ?? spec.sorts.first?.id
        return spec.sorts.first { $0.id == id }?.label
    }

    private func selectedLabel(of facet: RefSearchSpec.Facet) -> String? {
        guard let value = model.selections[facet.key] else { return nil }
        return facet.options.first { $0.value == value }?.label
    }

    @ViewBuilder
    private func facetChip(_ facet: SearchFacet, title: String, detail: String?) -> some View {
        SearchChip(
            title: title,
            systemImage: facet.systemImage,
            detail: detail,
            isSelected: expandedFacet == facet,
            accessibilityTitle: [title, detail].compactMap { $0 }.joined(separator: " ")
        ) {
            expandedFacet = expandedFacet == facet ? nil : facet
        }
    }

    @ViewBuilder
    private func options(for facet: SearchFacet) -> some View {
        FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            switch facet {
            case .sort:
                ForEach(spec.sorts) { sort in
                    SearchChip(
                        title: sort.label,
                        isSelected: (model.selectedSort ?? spec.sorts.first?.id) == sort.id
                    ) {
                        // 选回默认项就记成 nil，ref 收到的是「没指定」而不是某个 id。
                        model.selectedSort = sort.id == spec.sorts.first?.id ? nil : sort.id
                        model.sortChanged()
                        expandedFacet = nil
                    }
                }
            case .filter(let key):
                if let group = spec.filters.first(where: { $0.key == key }) {
                    SearchChip(title: "不限", isSelected: model.selections[key] == nil) {
                        model.select(nil, forFilter: key)
                        expandedFacet = nil
                    }
                    ForEach(group.options) { option in
                        SearchChip(title: option.label, isSelected: model.selections[key] == option.value) {
                            model.select(option.value, forFilter: key)
                            expandedFacet = nil
                        }
                    }
                }
            }
        }
    }
}

/// idle 态的「最近搜索」整段。一个 chip 两个热区：正文重搜、右侧 × 删除。
struct SearchHistorySection: View {
    @Bindable var model: SearchViewModel
    let limit: Int
    var onSelect: (String) -> Void

    var body: some View {
        let keywords = Array(model.historyKeywords.prefix(limit))
        if !keywords.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SearchSectionHeader(eyebrow: "RECENT", title: "最近搜索") {
                    Button("清空") {
                        model.clearHistory()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(SearchStyle.textTertiary)
                }
                FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(keywords, id: \.self) { keyword in
                        historyChip(keyword)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historyChip(_ keyword: String) -> some View {
        HStack(spacing: 6) {
            Button {
                onSelect(keyword)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                    Text(keyword)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(SearchStyle.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.deleteHistory(keyword)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SearchStyle.textTertiary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除“\(keyword)”")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            Capsule(style: .continuous)
                .fill(SearchStyle.surface)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(SearchStyle.hairline, lineWidth: 1)
                }
        }
    }
}
