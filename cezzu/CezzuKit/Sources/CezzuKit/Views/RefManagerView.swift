import SwiftUI
import UniformTypeIdentifiers

/// ref 管理：已安装列表、切换当前 ref、添加、移除。
public struct RefManagerView: View {
    let store: RefStore
    @State private var showAdd = false
    @State private var configuring: RefManifest?

    public init(store: RefStore) {
        self.store = store
    }

    public var body: some View {
        List {
            Section {
                if store.installed.isEmpty {
                    Text("还没有添加 ref").foregroundStyle(.secondary)
                }
                ForEach(store.installed) { manifest in
                    Button {
                        store.currentID = manifest.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(manifest.name)
                                Text("v\(manifest.version)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.currentID == manifest.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("移除", role: .destructive) { store.remove(manifest.id) }
                        if !manifest.config.isEmpty {
                            Button("配置") { configuring = manifest }.tint(.blue)
                        }
                    }
                    .contextMenu {
                        if !manifest.config.isEmpty {
                            Button("配置…") { configuring = manifest }
                        }
                        Button("移除", role: .destructive) { store.remove(manifest.id) }
                    }
                }
            } header: {
                Text("当前 ref 决定搜索和播放的来源")
            } footer: {
                Text("同一时间使用一个 ref，点选切换。ref 是运行在沙箱里的脚本，只添加你信任的来源。")
            }
        }
        .navigationTitle("Ref")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加", systemImage: "plus") { showAdd = true }
            }
        }
        .sheet(isPresented: $showAdd) { AddRefSheet(store: store) }
        .sheet(item: $configuring) { manifest in RefConfigSheet(store: store, manifest: manifest) }
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
