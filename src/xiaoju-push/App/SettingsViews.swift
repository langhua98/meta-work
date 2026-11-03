import SwiftUI

// 设置：云盘地址、两个令牌、外观、自动检查、提交说明模板；
// 以及编辑推送任务（选云盘文件夹、选仓库、选不推的文件夹）。

extension Mapping {
    /// 从排除列表里去掉一个（相对路径）
    mutating func removeExclude(_ rel: String) {
        excludes = excludedPaths.filter { $0 != rel }.joined(separator: "\n")
    }
}

// MARK: 设置

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var cloudResult = ""
    @State private var githubResult = ""
    @State private var testing = false
    @State private var notificationsOff = false
    @State private var newTemplate = ""

    var body: some View {
        NavigationStack {
            Form {
                cloudSection
                githubSection
                testSection
                AssistantSettingsSections()
                appearanceSection
                autoCheckSection
                templateSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { Haptics.tap(); dismiss() }
                }
            }
        }
    }

    // MARK: 令牌

    private var cloudSection: some View {
        Section {
            TextField("地址", text: $store.cloudURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            SecureField("xa_ 开头的令牌", text: $store.cloudToken)
        } header: { Text("小橘云盘") } footer: {
            Text("在网盘网页的「Agent 令牌」里新建，只读就够。")
        }
        .listRowBackground(Theme.card)
    }

    private var githubSection: some View {
        Section {
            SecureField("GitHub 令牌", text: $store.githubToken)
        } header: { Text("GitHub") } footer: {
            Text("GitHub → Settings → Developer settings → Personal access tokens 新建，要能写目标仓库（Contents: Read and write）。令牌存在手机钥匙串里。")
        }
        .listRowBackground(Theme.card)
    }

    private var testSection: some View {
        Section {
            Button {
                Haptics.tap()
                test()
            } label: {
                HStack {
                    Text(testing ? "测试中…" : "测试连接")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing || !store.ready)
            if !cloudResult.isEmpty { Text(cloudResult).font(.footnote).foregroundStyle(Theme.muted) }
            if !githubResult.isEmpty { Text(githubResult).font(.footnote).foregroundStyle(Theme.muted) }
        }
        .listRowBackground(Theme.card)
    }

    // MARK: 外观

    private var appearanceBinding: Binding<Int> {
        Binding(get: { store.appearance }, set: { v in
            if v != store.appearance { Haptics.select() }
            store.appearance = v
        })
    }

    private var appearanceSection: some View {
        Section("外观") {
            Picker("外观", selection: appearanceBinding) {
                Text("跟随系统").tag(0)
                Text("浅色").tag(1)
                Text("深色").tag(2)
            }
            .pickerStyle(.segmented)
        }
        .listRowBackground(Theme.card)
    }

    // MARK: 自动检查

    private var autoCheckBinding: Binding<Bool> {
        Binding(get: { store.autoCheck }, set: { on in
            Haptics.select()
            store.autoCheck = on
            if on {
                Task {
                    let ok = await BackgroundCheck.requestPermission()
                    notificationsOff = !ok
                    BackgroundCheck.schedule()
                }
            } else {
                notificationsOff = false
                BackgroundCheck.schedule()
            }
        })
    }

    private var autoCheckSection: some View {
        Section {
            Toggle("后台检查云盘，有改动发通知", isOn: autoCheckBinding)
                .tint(Theme.greenFill)
        } header: { Text("自动检查") } footer: {
            autoCheckFooter
        }
        .listRowBackground(Theme.card)
    }

    private var autoCheckFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if notificationsOff && store.autoCheck {
                Text("通知没打开，收不到提醒。请到 设置 > 通知 > 小橘推送 里打开。")
                    .foregroundStyle(Theme.redText)
            }
            Text("iOS 决定什么时候在后台运行，一般几十分钟到几小时一次。")
        }
    }

    // MARK: 提交说明模板

    private var templateSection: some View {
        Section {
            ForEach(Array(store.templates.enumerated()), id: \.offset) { _, t in
                Text(t)
            }
            .onDelete { offsets in
                Haptics.tap()
                store.templates.remove(atOffsets: offsets)
            }
            addTemplateRow
            Button("恢复默认") {
                Haptics.tap()
                store.templates = Store.defaultTemplates
            }
        } header: { Text("提交说明模板") } footer: {
            Text("{文件} 会换成这次推的文件名。左滑删除。")
        }
        .listRowBackground(Theme.card)
    }

    private var addTemplateRow: some View {
        HStack {
            TextField("新模板，比如 更新：{文件}", text: $newTemplate)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { addTemplate() }
            Button("添加") { addTemplate() }
                .buttonStyle(.borderless)
                .disabled(newTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func addTemplate() {
        let t = newTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Haptics.tap()
        store.templates.append(t)
        newTemplate = ""
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section("关于") {
            Button("重新看引导") {
                Haptics.tap()
                store.onboarded = false
                dismiss()
            }
        }
        .listRowBackground(Theme.card)
    }

    private func test() {
        testing = true
        cloudResult = ""
        githubResult = ""
        let e = store.engine()
        Task {
            var ok = true
            do {
                cloudResult = "云盘：✓ \(try await e.checkCloud())"
            } catch {
                ok = false
                cloudResult = "云盘：✗ \(error.localizedDescription)"
            }
            do {
                githubResult = "GitHub：✓ \(try await e.whoami())"
            } catch {
                ok = false
                githubResult = "GitHub：✗ \(error.localizedDescription)"
            }
            if ok { Haptics.success() } else { Haptics.error() }
            testing = false
        }
    }
}

// MARK: 编辑推送任务

struct MappingEditView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var mapping: Mapping

    var body: some View {
        NavigationStack {
            Form {
                cloudSection
                repoSection
                excludeSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(mapping.cloudPath.isEmpty ? "新任务" : mapping.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { Haptics.tap(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Haptics.success()
                        store.upsert(mapping)
                        dismiss()
                    }
                    .disabled(mapping.cloudPath.isEmpty || !mapping.repo.contains("/"))
                }
            }
        }
    }

    private var cloudSection: some View {
        Section("云盘文件夹") {
            TextField("/代码/my-app", text: $mapping.cloudPath)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            NavigationLink("浏览云盘…") { FolderPicker(path: "/", selection: $mapping.cloudPath) }
                .disabled(!store.ready)
        }
        .listRowBackground(Theme.card)
    }

    private var repoSection: some View {
        Section {
            TextField("owner/name", text: $mapping.repo)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            NavigationLink("从我的仓库里选…") { RepoPicker(selection: $mapping.repo) }
                .disabled(!store.ready)
            TextField("分支（空 = 默认分支）", text: $mapping.branch)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("仓库里的目录（空 = 根目录）", text: $mapping.repoPath)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("推到 GitHub") }
        .listRowBackground(Theme.card)
    }

    private var excludeSection: some View {
        Section {
            ForEach(mapping.excludedPaths, id: \.self) { p in
                excludeRow(p)
            }
            NavigationLink("浏览选择…") {
                ExcludePicker(root: mapping.cloudPath, mapping: $mapping)
            }
            .disabled(!store.ready || mapping.cloudPath.isEmpty)
            TextField("手写，比如 cloude审阅", text: $mapping.excludes, axis: .vertical)
                .lineLimit(1...6)
                .font(Theme.mono)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("不推的文件夹") } footer: {
            Text("可以浏览选择，也可以手写，每行一个（写完整路径或云盘文件夹里面的路径都行）。这些文件夹里的文件检查改动时直接跳过，不会提交。")
        }
        .listRowBackground(Theme.card)
    }

    private func excludeRow(_ p: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "nosign").foregroundStyle(Theme.red)
            Text(p).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button {
                remove(p)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint)
            }
            .buttonStyle(.borderless)
        }
        .swipeActions {
            Button(role: .destructive) {
                remove(p)
            } label: {
                Label("移除", systemImage: "trash")
            }
        }
    }

    private func remove(_ p: String) {
        Haptics.tap()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            mapping.removeExclude(p)
        }
    }
}

// MARK: 选不推的文件夹

struct ExcludePicker: View {
    @EnvironmentObject var store: Store
    let root: String
    let sub: String
    @Binding var mapping: Mapping
    @State private var folders: [CloudItem] = []
    @State private var error = ""
    @State private var loading = true

    init(root: String, sub: String = "", mapping: Binding<Mapping>) {
        self.root = root
        self.sub = sub
        self._mapping = mapping
    }

    private var path: String { "/" + PushEngine.clean(root + "/" + sub).joined(separator: "/") }

    private var rootName: String { PushEngine.clean(root).last ?? "云盘文件夹" }

    private var breadcrumb: String {
        var s = "云盘 / " + rootName
        if !sub.isEmpty { s += " / " + sub }
        return s
    }

    private var excluded: [String] { mapping.excludedPaths }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SectionTitle("已排除")
                chips
                SectionTitle(breadcrumb)
                folderList
            }
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .navigationTitle("不推的文件夹")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                folders = try await store.engine().listFolder(path).filter(\.isFolder)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    // MARK: 顶部已排除

    @ViewBuilder private var chips: some View {
        if excluded.isEmpty {
            Text("还没有，全部都会推送")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .card()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(excluded, id: \.self) { p in
                        chip(p)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
        }
    }

    private func chip(_ p: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "nosign").font(.system(size: 11, weight: .semibold))
            Text(p).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Button {
                remove(p)
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .padding(4)
            }
            .buttonStyle(PressStyle(scale: 0.85))
        }
        .foregroundStyle(Theme.redText)
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
        .background(Theme.redSoft, in: Capsule())
    }

    // MARK: 文件夹列表

    @ViewBuilder private var folderList: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity).padding(24)
        } else if !error.isEmpty {
            Text(error)
                .font(.system(size: 14))
                .foregroundStyle(Theme.redText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .card()
        } else if folders.isEmpty {
            Text("没有子文件夹")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .card()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(folders.enumerated()), id: \.element.id) { i, f in
                    folderRow(f)
                        .rowDivider(i < folders.count - 1)
                }
            }
            .card()
        }
    }

    private func rel(_ name: String) -> String { sub.isEmpty ? name : sub + "/" + name }

    private func isExcluded(_ r: String) -> Bool {
        excluded.contains { r == $0 || r.hasPrefix($0 + "/") }
    }

    private func folderRow(_ f: CloudItem) -> some View {
        let r = rel(f.name)
        let off = isExcluded(r)
        return HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(off ? Theme.faint : Theme.blue)
            Text(f.name)
                .font(.system(size: 15))
                .strikethrough(off, color: Theme.faint)
                .foregroundStyle(off ? Theme.muted : Theme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            actionButton(r)
            NavigationLink {
                ExcludePicker(root: root, sub: r, mapping: $mapping)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.85))
            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: off)
    }

    @ViewBuilder private func actionButton(_ r: String) -> some View {
        if excluded.contains(r) {
            Button {
                remove(r)
            } label: {
                Text("已排除")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.redText)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.redSoft, in: Capsule())
            }
            .buttonStyle(PressStyle(scale: 0.92))
        } else if isExcluded(r) {
            Text("上层已排除")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
        } else {
            Button {
                Haptics.success()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    mapping.addExclude(r)
                }
            } label: {
                Text("不推这个")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.raised, in: Capsule())
                    .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(PressStyle(scale: 0.92))
        }
    }

    private func remove(_ r: String) {
        Haptics.tap()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            mapping.removeExclude(r)
        }
    }
}

// MARK: 选云盘文件夹

struct FolderPicker: View {
    @EnvironmentObject var store: Store
    let path: String
    @Binding var selection: String
    @State private var folders: [CloudItem] = []
    @State private var error = ""
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Button {
                    Haptics.success()
                    selection = path
                    dismiss()
                } label: {
                    Label("选这个文件夹：\(path)", systemImage: "checkmark.circle")
                        .foregroundStyle(Theme.blue)
                }
            }
            .listRowBackground(Theme.card)
            Section {
                if loading { ProgressView() }
                if !error.isEmpty { Text(error).foregroundStyle(Theme.redText) }
                ForEach(folders, id: \.id) { f in
                    folderLink(f)
                }
                if !loading && error.isEmpty && folders.isEmpty {
                    Text("没有子文件夹").foregroundStyle(Theme.muted)
                }
            }
            .listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(path == "/" ? "云盘" : (path.split(separator: "/").last.map(String.init) ?? path))
        .task {
            do {
                folders = try await store.engine().listFolder(path).filter(\.isFolder)
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func folderLink(_ f: CloudItem) -> some View {
        let sub = (path == "/" ? "" : path) + "/" + f.name
        return NavigationLink {
            FolderPicker(path: sub, selection: $selection)
        } label: {
            Label {
                Text(f.name).foregroundStyle(Theme.text)
            } icon: {
                Image(systemName: "folder.fill").foregroundStyle(Theme.blue)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
    }
}

// MARK: 选仓库

struct RepoPicker: View {
    @EnvironmentObject var store: Store
    @Binding var selection: String
    @State private var repos: [Repo] = []
    @State private var error = ""
    @State private var loading = true
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var shown: [Repo] {
        repos.filter { query.isEmpty || $0.full_name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if loading { ProgressView().listRowBackground(Theme.card) }
            if !error.isEmpty { Text(error).foregroundStyle(Theme.redText).listRowBackground(Theme.card) }
            ForEach(shown, id: \.full_name) { r in
                repoRow(r)
            }
            .listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .searchable(text: $query)
        .navigationTitle("我的仓库")
        .task {
            do { repos = try await store.engine().repos() } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func repoRow(_ r: Repo) -> some View {
        Button {
            Haptics.success()
            selection = r.full_name
            dismiss()
        } label: {
            HStack {
                Image(systemName: "book.closed").foregroundStyle(Theme.muted)
                Text(r.full_name).foregroundStyle(Theme.text)
                Spacer()
                if r.private { Image(systemName: "lock").foregroundStyle(Theme.muted) }
            }
        }
    }
}
