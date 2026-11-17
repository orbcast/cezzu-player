import SwiftUI

/// 首页没有分区时的提示：ref 没提供首页内容，或者请求失败（失败时可以重试）。
struct HomeEmptyNotice: View {
    let error: CatalogAPIError?
    let onRetry: () -> Void

    var body: some View {
        if let error {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "首页加载失败",
                message: error.userMessage,
                tone: .error,
                actionTitle: "重试",
                action: onRetry)
        } else {
            EmptyStateView(
                systemImage: "rectangle.stack",
                title: "当前 ref 没有提供首页内容",
                message: "可以直接搜索想看的内容。")
        }
    }
}
