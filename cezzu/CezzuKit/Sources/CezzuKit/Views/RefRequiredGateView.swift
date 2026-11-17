import SwiftUI

/// 没有任何数据源时的拦截页：搜索、首页、追剧都依赖 ref，没有 ref 就只能先添加。
enum RefGate {
    static func isRequired(installed: [RefManifest]) -> Bool { installed.isEmpty }
}

struct RefRequiredGateView: View {
    let store: RefStore
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Color.primary.opacity(0.06)))

            VStack(spacing: 8) {
                Text("先添加一个数据源")
                    .font(.title2.weight(.semibold))
                Text("搜索、选集和播放都来自数据源（ref）。添加之后才能开始使用。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            GlassPrimaryButton("添加数据源", systemImage: "plus") { showAdd = true }
                .padding(.top, 4)

            Label("ref 是运行在沙箱里的脚本，只添加你信任的来源。", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.09).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showAdd) { AddRefSheet(store: store) }
    }
}
