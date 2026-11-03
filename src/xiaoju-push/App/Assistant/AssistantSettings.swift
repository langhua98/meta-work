import SwiftUI

// 设置里的：本地模型、整理令牌、云端大模型、记忆。

struct AssistantSettingsSections: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var models = ModelStore.shared

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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(models.info.name)
                    Text(ByteCountFormatter.string(fromByteCount: models.info.bytes, countStyle: .file))
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                Spacer()
                if models.downloaded {
                    Text("已下载").font(.footnote.weight(.semibold)).foregroundStyle(Theme.green)
                }
            }
            if let p = models.progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: p).tint(Theme.orange)
                    Text("\(ByteCountFormatter.string(fromByteCount: models.received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: models.info.bytes, countStyle: .file))")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                Button("取消下载", role: .destructive) { Haptics.tap(); models.cancel() }
            } else if models.downloaded {
                Button("删除模型", role: .destructive) { Haptics.medium(); models.delete() }
            } else {
                Button("下载（只用 Wi-Fi）") { Haptics.tap(); models.download() }
            }
            if !models.error.isEmpty {
                Text(models.error).font(.footnote).foregroundStyle(Theme.redText)
            }
        } header: { Text("本地模型") } footer: {
            Text("在手机上听懂你的话，不联网。只在说话时加载，空闲 2 分钟或切到后台就释放内存。不下载也能用简单的话（推送、检查）。")
        }
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
            Toggle("本地搞不定自动问云端", isOn: $store.autoCloud).tint(Theme.greenFill)
        } header: { Text("云端大模型（HF 上的 OpenCode）") } footer: {
            Text("密码是 Space 里的 OPENCODE_SERVER_PASSWORD。云端只出方案，改东西前都会先问你。")
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
