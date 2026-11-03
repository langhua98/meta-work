import SwiftUI

// 复制给 AI（把要求 + 相关文件 + 回答格式一起复制，去 DeepSeek 等粘贴）和工作区页面。

struct CopyOutView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let mapping: Mapping
    @State private var request = ""
    @State private var files: [String] = []
    @State private var picked: Set<String> = []
    @State private var query = ""
    @State private var loading = true
    @State private var copying = false
    @State private var error = ""
    @State private var copied = false

    private var shown: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? files : files.filter { $0.lowercased().contains(q) }
        // 勾了的排前面
        return list.filter(picked.contains) + list.filter { !picked.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("想让 AI 做什么，比如：输入框改成胶囊样式", text: $request, axis: .vertical)
                        .lineLimit(2...5)
                        .onChange(of: request) { autoPick() }
                } header: { Text("要求") }
                Section {
                    if loading { HStack { ProgressView(); Text("读取文件…").foregroundStyle(Theme.muted) } }
                    TextField("搜文件名", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    ForEach(shown.prefix(200), id: \.self) { f in
                        Button {
                            Haptics.select()
                            if picked.contains(f) { picked.remove(f) } else { picked.insert(f) }
                        } label: {
                            HStack(spacing: 12) {
                                CheckCircle(on: picked.contains(f))
                                Text(f).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                } header: {
                    Text("带上这些文件（\(picked.count) 个）")
                } footer: {
                    Text("按要求里的词先勾上可能相关的，你再增减。复制的内容会要求 AI 每个文件给完整内容、代码块第一行写路径，粘回来就能自动拆成文件。")
                }
                if !error.isEmpty { Text(error).foregroundStyle(Theme.redText) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .listRowBackground(Theme.card)
            .navigationTitle("复制给 AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button { copy() } label: {
                    Label(copied ? "复制好了，去 DeepSeek 粘贴" : (copying ? "读取中…" : "复制"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(BigButtonStyle(kind: .push))
                .disabled(copying || (picked.isEmpty && request.isEmpty))
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .task { await load() }
        }
    }

    private func load() async {
        do { files = try await ChatModel.shared.taskFiles(mapping).filter(CodePaste.isText) } catch {
            self.error = error.localizedDescription
        }
        loading = false
        autoPick()
    }

    private func autoPick() {
        picked.formUnion(CodePaste.guess(request, files: files))
    }

    private func copy() {
        copying = true
        Task {
            var out: [(String, String)] = []
            for f in files where picked.contains(f) {
                if let d = await ChatModel.shared.readTaskFile(mapping, f) {
                    out.append((f, String(decoding: d, as: UTF8.self)))
                }
            }
            UIPasteboard.general.string = CodePaste.prompt(repo: mapping.repo, request: request, files: out)
            copying = false
            copied = true
            Haptics.success()
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        }
    }
}

/// 工作区：手机里这个任务的代码副本。看哪些改了没推、推送、从 GitHub 拉
struct WorkspaceView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let mapping: Mapping
    @State private var files: [String] = []
    @State private var changed: [Changed] = []

    struct Changed: Hashable { let path: String; let isNew: Bool }

    private var ws: Workspace { Workspace(mapping: mapping) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        StatTile(value: "\(changed.filter { !$0.isNew }.count)", label: "改了", color: Theme.yellow)
                        StatTile(value: "\(changed.filter(\.isNew).count)", label: "新文件", color: Theme.green)
                        StatTile(value: "\(files.count - changed.count)", label: "没动", color: Theme.text)
                    }
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                if !changed.isEmpty {
                    Section("没推的改动") {
                        ForEach(changed, id: \.path) { c in
                            HStack(spacing: 10) {
                                Circle().fill(c.isNew ? Theme.green : Theme.yellow).frame(width: 8, height: 8)
                                Text(c.path).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                }
                Section {
                    if files.isEmpty {
                        Text("还是空的。点下面「从 GitHub 拉」把仓库拉下来，或者直接在对话框里粘贴代码。")
                            .foregroundStyle(Theme.muted)
                    }
                    ForEach(files.prefix(300), id: \.self) { f in
                        Text(f).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.head)
                    }
                } header: { Text("所有文件（\(files.count) 个）") } footer: {
                    Text("在「文件」App →「我的 iPhone」→「小橘推送」→「工作区」里也能看到和编辑。推送前会和 GitHub 对比，只推改了的。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("工作区 · \(mapping.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Button {
                        dismiss()
                        ChatModel.shared.focus(mapping)
                        ChatModel.shared.send("推送")
                    } label: { Text(changed.isEmpty ? "推送" : "推送 \(changed.count) 个文件") }
                        .buttonStyle(BigButtonStyle(kind: .push))
                        .disabled(changed.isEmpty)
                    Button {
                        dismiss()
                        ChatModel.shared.focus(mapping)
                        ChatModel.shared.pull(mapping)
                    } label: { Text("从 GitHub 拉") }
                        .buttonStyle(BigButtonStyle(kind: .plain))
                        .frame(maxWidth: 150)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .onAppear(perform: load)
        }
    }

    /// 和上次推送 / 拉取时记下的 blob 比，不联网
    private func load() {
        files = ws.files()
        let repo = mapping.repo
        let prefix = PushEngine.clean(mapping.repoPath).joined(separator: "/")
        let records = store.pushed.filter { $0.key.hasPrefix(repo + "@") }
        changed = files.compactMap { rel in
            let rp = prefix.isEmpty ? rel : prefix + "/" + rel
            let rec = records.first { $0.key.hasSuffix(":" + rp) }?.value
            guard let d = ws.read(rel) else { return nil }
            guard let rec else { return Changed(path: rel, isNew: true) }
            return PushEngine.gitBlobSHA(d) == rec.blob ? nil : Changed(path: rel, isNew: false)
        }
    }
}
