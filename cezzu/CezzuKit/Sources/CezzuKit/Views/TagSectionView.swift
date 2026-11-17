import SwiftUI

/// 单个分区的全量列表页（「查看全部」入口）。
public struct TagSectionView: View {
    @State private var model: TagBrowseViewModel
    var onTapItem: (CatalogItem) -> Void

    public init(
        api: CatalogAPIClientProtocol,
        tag: String,
        onTapItem: @escaping (CatalogItem) -> Void
    ) {
        _model = State(initialValue: TagBrowseViewModel(api: api, tag: tag))
        self.onTapItem = onTapItem
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScrollToTopAnchor()
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.isLoading && model.items.isEmpty {
                        CatalogSkeletonGrid()
                    } else if model.loadFailed {
                        EmptyStateView(
                            systemImage: "wifi.exclamationmark",
                            title: "加载失败",
                            message: model.lastError?.userMessage ?? "请检查网络后重试。",
                            tone: .warning,
                            actionTitle: "重试",
                            action: { Task { await model.reload() } }
                        )
                        .padding(.top, 20)
                    } else if model.items.isEmpty {
                        EmptyStateView(
                            systemImage: "sparkles",
                            title: "暂无剧集",
                            message: "这个分区暂时没有内容。"
                        )
                        .padding(.top, 20)
                    } else {
                        CatalogGrid(
                            items: model.items,
                            onTapItem: onTapItem,
                            onLoadMore: { item in
                                await model.loadMoreIfNeeded(currentItem: item)
                            }
                        ) {
                            if model.isLoadingMore {
                                CatalogSkeletonGrid(placeholderCount: 4)
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .scrollToTop()
        .task { await model.loadInitialIfNeeded() }
        .refreshable { await model.reload() }
        .navigationTitle(model.title)
    }
}
