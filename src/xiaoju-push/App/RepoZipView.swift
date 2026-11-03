import SwiftUI

// 仓库 ZIP：和 GitHub 页面 Code → Download ZIP 一样，把整个仓库打包下载到手机。
// 存在「文件」App →「我的 iPhone」→「小橘推送」→「仓库ZIP」里，也能直接分享出去（发给别的 AI、存到别处）。

struct RepoZipView: View {
    @EnvironmentObject var store: Store
    @State private var other = ""
    @State private var busy: String?
    @State private var error = ""
    @State private var saved: [URL] = []

    struct Repo: Hashable { let repo: String; let branch: String }

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("仓库ZIP", isDirectory: true)
    }

    /// 任务里用到的仓库，去重
    private var repos: [Repo] {
        var out: [Repo] = []
        for m in store.mappings where !m.repo.isEmpty {
            let r = Repo(repo: m.repo, branch: m.branch)
            if !out.contains(r) { out.append(r) }
        }
        return out
    }

    var body: some View {
        List {
            Section {
                if repos.isEmpty { Text("还没有任务。也可以在下面直接写仓库名。").foregroundStyle(Theme.muted) }
                ForEach(repos, id: \.self) { r in
                    Button { download(r) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox").foregroundStyle(Theme.orangeText).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.repo).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.text)
                                Text(r.branch.isEmpty ? "默认分支" : r.branch).font(.system(size: 13)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if busy == key(r) { ProgressView() } else {
                                Image(systemName: "arrow.down.circle").font(.system(size: 20)).foregroundStyle(Theme.orangeText)
                            }
                        }
                    }
                    .disabled(busy != nil)
                    .listRowBackground(Theme.card)
                }
            } header: { Text("下载哪个仓库") } footer: {
                Text("和 GitHub 网页上点 Code → Download ZIP 一样，下载的是 GitHub 上现在的版本。")
            }

            Section {
                HStack {
                    TextField("别的仓库，比如 langhua98/xiaoju-video", text: $other)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("下载") {
                        let parts = other.trimmingCharacters(in: .whitespaces).split(separator: "@", maxSplits: 1).map(String.init)
                        guard let name = parts.first, name.contains("/") else { error = "写成 用户名/仓库名"; return }
                        download(Repo(repo: name, branch: parts.count > 1 ? parts[1] : ""))
                    }
                    .disabled(busy != nil || other.isEmpty)
                }
                .listRowBackground(Theme.card)
            } footer: { Text("要指定分支就写 用户名/仓库名@分支") }

            if !error.isEmpty {
                Text(error).foregroundStyle(Theme.redText).listRowBackground(Theme.card)
            }

            Section {
                if saved.isEmpty { Text("还没有下载过").foregroundStyle(Theme.muted) }
                ForEach(saved, id: \.self) { u in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(u.lastPathComponent).font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.text)
                                .lineLimit(1).truncationMode(.middle)
                            Text(info(u)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        ShareLink(item: u) { Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.orangeText) }
                    }
                    .listRowBackground(Theme.card)
                    .swipeActions {
                        Button(role: .destructive) { try? FileManager.default.removeItem(at: u); load() } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } header: { Text("下载好的") } footer: {
                Text("在「文件」App →「我的 iPhone」→「小橘推送」→「仓库ZIP」里也能看到。点分享可以存到别处或发给别的 AI。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("仓库 ZIP")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func key(_ r: Repo) -> String { r.repo + "@" + r.branch }

    private func download(_ r: Repo) {
        guard !store.githubToken.isEmpty else { error = "先在设置里填 GitHub 令牌"; return }
        Haptics.tap()
        error = ""
        busy = key(r)
        let name = r.repo.replacingOccurrences(of: "/", with: "-") + (r.branch.isEmpty ? "" : "-" + r.branch.replacingOccurrences(of: "/", with: "-"))
        let f = DateFormatter()
        f.dateFormat = "MMdd-HHmm"
        let dest = Self.folder.appendingPathComponent("\(name)-\(f.string(from: Date())).zip")
        Task {
            do {
                try await store.engine().downloadZip(repo: r.repo, ref: r.branch, to: dest)
                Haptics.success()
            } catch {
                self.error = error.localizedDescription
            }
            busy = nil
            load()
        }
    }

    private func load() {
        let fm = FileManager.default
        let list = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        saved = list.filter { $0.pathExtension == "zip" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    private func info(_ u: URL) -> String {
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
