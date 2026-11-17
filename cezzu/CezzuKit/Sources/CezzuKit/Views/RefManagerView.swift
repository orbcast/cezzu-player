import SwiftUI
import UniformTypeIdentifiers

/// ref 管理页的文案。抽出来是为了能单测，视图里不放判断。
enum RefManagerText {
    /// 卡片副标题：`v0.2 · 脚本 · 可访问 3 个域名`。
    static func summary(for manifest: RefManifest) -> String {
        var parts = ["v\(manifest.version)"]
        switch manifest.kind {
        case .script:
            parts.append("脚本")
            if !manifest.allowedHosts.isEmpty {
                parts.append("可访问 \(manifest.allowedHosts.count) 个域名")
            }
        case .legacyRules:
            parts.append("规则集")
        }
        if !manifest.config.isEmpty { parts.append("需要配置") }
        return parts.joined(separator: " · ")
    }
}

/// ref 管理：已安装列表、切换当前 ref、添加、配置、移除。
///
/// 一张卡片一个 ref：点卡片切换，右侧 `…` 菜单里配置 / 移除（不靠滑动手势，鼠标也能用）。
public struct RefManagerView: View {
    let store: RefStore
    @State private var showAdd = false
    @State private var configuring: RefManifest?
    @State private var removing: RefManifest?

    public init(store: RefStore) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("当前 ref 决定搜索和播放的来源。同一时间使用一个，点击卡片即可切换。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                ForEach(store.installed) { manifest in
                    RefCard(
                        manifest: manifest,
                        isCurrent: store.currentID == manifest.id,
                        onSelect: {
                            withAnimation(.easeOut(duration: 0.2)) { store.currentID = manifest.id }
                        },
                        onConfigure: { configuring = manifest },
                        onRemove: { removing = manifest }
                    )
                }

                addButton

                Label("ref 是运行在沙箱里的脚本，只添加你信任的来源。", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("数据源")
        .sheet(isPresented: $showAdd) { AddRefSheet(store: store) }
        .sheet(item: $configuring) { manifest in RefConfigSheet(store: store, manifest: manifest) }
        .confirmationDialog(
            "移除 \(removing?.name ?? "")？",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                if let removing { withAnimation { store.remove(removing.id) } }
                removing = nil
            }
        } message: {
            Text("已保存的配置也会一并删除。")
        }
    }

    private var addButton: some View {
        Button { showAdd = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text(store.installed.isEmpty ? "添加第一个 ref" : "添加 ref")
            }
            .font(.body.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct RefCard: View {
    let manifest: RefManifest
    let isCurrent: Bool
    let onSelect: () -> Void
    let onConfigure: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 14) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.title3)
                        .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                        .frame(width: 42, height: 42)
                        .background(
                            Circle().fill(isCurrent ? Color.accentColor : Color.primary.opacity(0.08))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(manifest.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(RefManagerText.summary(for: manifest))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if isCurrent {
                        Text("使用中")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                if !manifest.config.isEmpty {
                    Button("配置…", systemImage: "slider.horizontal.3", action: onConfigure)
                }
                Button("移除", systemImage: "trash", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.leading, 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(shape.fill(Color.primary.opacity(hovering ? 0.10 : 0.06)))
        .overlay {
            shape.strokeBorder(
                isCurrent ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                lineWidth: isCurrent ? 1.5 : 1
            )
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// 按清单声明渲染配置输入框。敏感项用密码框，值不回显。
struct RefConfigFields: View {
    let fields: [RefManifest.ConfigField]
    @Binding var values: [String: String]

    var body: some View {
        ForEach(fields, id: \.key) { field in
            let binding = Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 })
            if field.secret {
                SecureField(field.label + (field.required ? "" : "（可选）"), text: binding)
            } else {
                TextField(field.label + (field.required ? "" : "（可选）"), text: binding)
                    .autocorrectionDisabled()
            }
        }
    }

    static func isComplete(_ fields: [RefManifest.ConfigField], _ values: [String: String]) -> Bool {
        fields.allSatisfy { !$0.required || !(values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// 修改已安装 ref 的配置。
struct RefConfigSheet: View {
    let store: RefStore
    let manifest: RefManifest
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    RefConfigFields(fields: manifest.config, values: $values)
                } footer: {
                    Text("这些值只保存在本机，不会上传，也不会写进 ref 本身。")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("配置 \(manifest.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try store.updateConfig(id: manifest.id, values: values)
                            dismiss()
                        } catch {
                            errorMessage = AddRefError.message(for: error)
                        }
                    }
                    .disabled(!RefConfigFields.isComplete(manifest.config, values))
                }
            }
            .onAppear { values = store.config(for: manifest.id) }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }
}

struct AddRefSheet: View {
    let store: RefStore
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var pending: RefStore.Pending?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var isPickingFolder = false
    @State private var configValues: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("清单地址（URL 或本地目录路径）", text: $address)
                        .autocorrectionDisabled()
                    HStack {
                        Button(isWorking ? "读取中…" : "读取") { Task { await prepare() } }
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                        Button("选择本地目录…") { isPickingFolder = true }
                            .disabled(isWorking)
                    }
                } footer: {
                    Text("ref 是一段会运行在沙箱里的脚本。只添加你信任的来源。本地目录请用「选择本地目录」授权，App 无法直接读取手输的路径。")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }

                if let manifest = pending?.manifest {
                    Section("确认权限") {
                        LabeledContent("名称", value: manifest.name)
                        LabeledContent("版本", value: manifest.version)
                        if manifest.kind == .legacyRules {
                            Text("这是一个规则集，会访问规则中列出的多个站点，并使用内置嗅探播放。")
                        } else {
                            ForEach(manifest.allowedHosts, id: \.self) { Text("可访问：\($0)") }
                        }
                        ForEach(manifest.capabilities, id: \.self) { Text("能力：\($0.rawValue)") }
                    }
                    if !manifest.config.isEmpty {
                        Section {
                            RefConfigFields(fields: manifest.config, values: $configValues)
                        } header: {
                            Text("配置")
                        } footer: {
                            Text("这些值只保存在本机，不会上传，也不会写进 ref 本身。")
                        }
                    }
                    Section {
                        Button("允许并添加") { confirm() }
                            .disabled(!RefConfigFields.isComplete(manifest.config, configValues))
                    }
                }
            }
            .formStyle(.grouped)
            .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    address = url.path
                    Task { await prepare(from: url, scoped: true) }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .navigationTitle("添加 ref")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    private func prepare() async {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = text.contains("://") ? URL(string: text) : URL(fileURLWithPath: (text as NSString).expandingTildeInPath) else {
            errorMessage = "地址无效"
            return
        }
        await prepare(from: url, scoped: false)
    }

    private func prepare(from url: URL, scoped: Bool) async {
        isWorking = true
        errorMessage = nil
        pending = nil
        configValues = [:]
        // 文件选择器给的是临时授权：读取（含脚本）都在这个区间内完成，之后 Pending 已持有全部数据。
        let granted = scoped && url.startAccessingSecurityScopedResource()
        defer {
            if granted { url.stopAccessingSecurityScopedResource() }
            isWorking = false
        }
        do {
            pending = try await store.prepare(from: url)
        } catch {
            errorMessage = AddRefError.message(for: error)
        }
    }

    private func confirm() {
        guard let pending else { return }
        do {
            try store.install(pending, config: configValues)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum AddRefError {
    static func message(for error: Error) -> String {
        switch error {
        case RefError.scriptError(let message), RefError.invalidResult(let message), RefError.invalidManifest(let message):
            return message
        case RefError.unsupportedAPI(let required, let supported):
            return "该 ref 需要协议 v\(required)，当前播放器支持到 v\(supported)"
        default: return error.localizedDescription
        }
    }
}
