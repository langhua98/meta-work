import SwiftUI

// 设置里的：本地模型、整理令牌、云端大模型、记忆。

struct AssistantSettingsSections: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var models = ModelStore.shared
    @AppStorage("memoryHUD") private var showHUD = true

    var body: some View {
        Group {
            modelSection
            organizeSection
            cloudSection
            memorySection
        }
        .listRowBackground(Theme.card)
    }

    private var modelSection: some View {
        Section {
            ForEach(ModelInfo.all) { m in modelRow(m) }
            Toggle("屏幕底部显示内存占用", isOn: $showHUD).tint(Theme.orange)
            if !models.error.isEmpty {
                Text(models.error).font(.footnote).foregroundStyle(Theme.redText)
            }
        } header: { Text("本地模型") } footer: {
            Text("点一个用它（打勾的是在用的）。在手机上听懂你的话，不联网。只在说话时加载，空闲 2 分钟或切到后台就释放内存。4B 更聪明但更占内存，看屏幕上的内存浮标就知道跑不跑得动。")
        }
    }

    private func modelRow(_ m: ModelInfo) -> some View {
        let on = models.selectedID == m.id
        let have = models.isDownloaded(m)
        let busy = models.downloadingID == m.id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.select()
                models.selectedID = m.id
            } label: {
                HStack(spacing: 12) {
                    CheckCircle(on: on)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name).foregroundStyle(Theme.text)
                        Text("\(ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file)) · \(m.note)")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if have { Text("已下载").font(.footnote.weight(.semibold)).foregroundStyle(Theme.green) }
                }
            }
            .buttonStyle(.plain)
            if busy, let p = models.progress {
                ProgressView(value: p).tint(Theme.orange)
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: models.received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file))")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("取消", role: .destructive) { Haptics.tap(); models.cancel() }.buttonStyle(.borderless)
                }
            } else if have {
                Button("删除这个模型", role: .destructive) { Haptics.medium(); models.delete(m) }
                    .buttonStyle(.borderless).font(.footnote)
            } else {
                Button("下载（只用 Wi-Fi）") { Haptics.tap(); models.download(m) }
                    .buttonStyle(.borderless).font(.footnote.weight(.semibold))
                    .disabled(models.downloading)
            }
        }
        .padding(.vertical, 4)
    }

    private var organizeSection: some View {
        Section {
            SecureField("xa_ 开头的整理令牌", text: $store.organizeToken)
        } header: { Text("管理云盘文件") } footer: {
            Text("改名、移动、放回收站、写记忆要用。在网盘「Agent 令牌」里新建一个带「整理」权限的。不填就只能找文件。删除永远只放进回收站。")
        }
    }

    private var cloudSection: some View {
        Section {
            TextField("地址", text: $store.openCodeURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            SecureField("OpenCode 密码", text: $store.openCodePassword)
            Toggle("本地搞不定自动问云端", isOn: $store.autoCloud).tint(Theme.orange)
            Toggle("快速模式", isOn: $store.cloudFast).tint(Theme.orange)
        } header: { Text("云端大模型（HF 上的 OpenCode）") } footer: {
            Text("快速模式用 DeepSeek Flash，快很多；关掉用 V4 Pro，难题更稳但慢。密码是 Space 里的 OPENCODE_SERVER_PASSWORD。云端只出方案，改东西前都会先问你。")
        }
    }

    private var memorySection: some View {
        Section {
            NavigationLink("看记忆") { MemoryView() }
                .disabled(store.cloudToken.isEmpty)
        } header: { Text("记忆") } footer: {
            Text("说「记住…」或纠正它时才会记，一个主题一个文件，存在云盘 \(CloudFiles.memoryFolder)/。")
        }
    }
}

/// 记忆：索引 + 每个文件，点开看，左滑放回收站
struct MemoryView: View {
    @EnvironmentObject var store: Store
    @State private var index = ""
    @State private var files: [CloudEntry] = []
    @State private var loading = true
    @State private var error = ""

    private var cloud: CloudFiles {
        CloudFiles(base: store.cloudURL.isEmpty ? Store.defaultCloudURL : store.cloudURL,
                   readToken: store.cloudToken, writeToken: store.organizeToken)
    }

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("读取中…").foregroundStyle(Theme.muted) }
            }
            if !error.isEmpty {
                Text(error).foregroundStyle(Theme.redText)
            }
            if !loading && files.isEmpty && error.isEmpty {
                Text("还没有记忆。在对话里说「记住…」就会记下来。").foregroundStyle(Theme.muted)
            }
            if !index.isEmpty {
                Section("索引") {
                    Text(index).font(.system(size: 13)).foregroundStyle(Theme.text).textSelection(.enabled)
                }
                .listRowBackground(Theme.card)
            }
            if !files.isEmpty {
                Section("文件") {
                    ForEach(files.filter { $0.name != CloudFiles.memoryIndex }) { f in
                        NavigationLink(f.name) { MemoryFileView(entry: f, cloud: cloud) }
                            .swipeActions {
                                Button("放进回收站", role: .destructive) { trash(f) }
                            }
                    }
                }
                .listRowBackground(Theme.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("记忆")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = ""
        do {
            files = try await cloud.memoryFiles()
            index = await cloud.memoryIndex()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func trash(_ f: CloudEntry) {
        Haptics.medium()
        Task {
            do {
                try await cloud.trash(f)
                files.removeAll { $0.id == f.id }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct MemoryFileView: View {
    let entry: CloudEntry
    let cloud: CloudFiles
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "读取中…" : text)
                .font(.system(size: 14)).foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { text = (try? await cloud.readText(entry.fullPath)) ?? "读不到" }
    }
}
