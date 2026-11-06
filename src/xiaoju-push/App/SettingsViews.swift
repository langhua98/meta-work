import SwiftUI

// 设置首页：账号、连接器、本地模型、记忆、推送习惯、外观、关于（令牌都在连接器里）；
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
    @ObservedObject private var models = ModelStore.shared
    @ObservedObject private var fixBook = FixBook.shared
    @AppStorage("memoryHUD") private var showHUD = true
    @State private var login = ""
    @State private var notificationsOff = false
    @State private var newTemplate = ""

    var body: some View {
        NavigationStack {
            Form {
                accountCard
                Section {
                    NavigationLink { ConnectorsView() } label: {
                        SettingsRow(icon: "powerplug", title: "连接器", sub: connectorsSub)
                    }
                }
                .listRowBackground(Theme.card)
                Section("助手") {
                    NavigationLink { LocalModelSettingsView() } label: {
                        SettingsRow(icon: "cpu", title: "本地模型",
                                    sub: models.info.short + (models.downloaded ? " · 已下载" : " · 还没下载") + (showHUD ? " · 底部显示内存" : ""))
                    }
                    NavigationLink { MemoryView() } label: {
                        SettingsRow(icon: "brain", title: "记忆", sub: "存在云盘 \(CloudFiles.memoryFolder)/")
                    }
                    .disabled(store.cloudToken.isEmpty)
                    NavigationLink { FixBookView() } label: {
                        SettingsRow(icon: "checkmark.bubble", title: "纠错本",
                                    sub: "\(fixBook.fixes.count) 条 · 本地模型下次照着做，也是升级用的训练数据")
                    }
                }
                .listRowBackground(Theme.card)
                Section("推送") {
                    NavigationLink { pushPrefs } label: {
                        SettingsRow(icon: "arrow.up.circle", title: "推送习惯",
                                    sub: (store.autoCheck ? "后台自动检查" : "不自动检查") + " · 提交说明模板 \(store.templates.count) 个")
                    }
                }
                .listRowBackground(Theme.card)
                Section("遥控") {
                    NavigationLink { RemoteView() } label: {
                        SettingsRow(icon: "dot.radiowaves.left.and.right", title: "遥控（被控端 · 发指令）",
                                    sub: "开待命后，另一台设备调用这台的相机 / 麦克风 / 定位等")
                    }
                }
                .listRowBackground(Theme.card)
                Section("App") {
                    NavigationLink { appearancePage } label: {
                        SettingsRow(icon: "circle.lefthalf.filled", title: "外观", sub: ["跟随系统", "浅色", "深色"][min(2, max(0, store.appearance))])
                    }
                    NavigationLink { aboutPage } label: {
                        SettingsRow(icon: "info.circle", title: "关于", sub: "版本 \(Self.version) · 重新看引导")
                    }
                }
                .listRowBackground(Theme.card)
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
            .task {
                guard login.isEmpty, !store.githubToken.isEmpty else { return }
                login = (try? await store.engine().whoami()) ?? ""
            }
        }
    }

    static var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }

    private var connectorsSub: String {
        let linked = Connector.all.filter { ConnectorDetailView.linked($0, store) && Connectors.isOn($0) }
        return linked.isEmpty ? "还没连上，点进去填账号" : linked.map(\.name).joined(separator: " · ") + " 已连上"
    }

    // MARK: 账号卡片

    private var accountCard: some View {
        Section {
            HStack(spacing: 12) {
                Text(String((login.isEmpty ? "小" : login).prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.onAccent)
                    .frame(width: 44, height: 44).background(Theme.orange, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(login.isEmpty ? (store.githubToken.isEmpty ? "还没连 GitHub" : "GitHub 已连上") : login)
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.text)
                    Text("\(store.mappings.count) 个任务 · 本地模型 \(models.info.short) · 云端\(store.cloudFast ? "快速模式" : "V4 Pro")")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Theme.card)
    }

    // MARK: 子页面

    private var pushPrefs: some View {
        Form {
            autoCheckSection
            templateSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("推送习惯")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appearancePage: some View {
        Form { appearanceSection }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("外观")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var aboutPage: some View {
        Form {
            Section {
                LabeledContent("版本", value: Self.version)
            }
            .listRowBackground(Theme.card)
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
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
                .tint(Theme.orange)
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
}

/// 设置首页的一行：图标 + 标题 + 一行状态
struct SettingsRow: View {
    let icon: String
    let title: String
    let sub: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.text)
                .frame(width: 32, height: 32).background(Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(Theme.text)
                Text(sub).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
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
                sourceSection
                repoSection
                if !mapping.workspace { cloudSection }
                excludeSection
                previewSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(store.mappings.contains { $0.id == mapping.id } ? mapping.title : "新建任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { Haptics.tap(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Haptics.success()
                        store.upsert(mapping)
                        // 新的工作区任务：先把仓库拉到手机里
                        if mapping.workspace && Workspace(mapping: mapping).files().isEmpty {
                            ChatModel.shared.focus(mapping)
                            ChatModel.shared.pull(mapping)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled((!mapping.workspace && mapping.cloudPath.isEmpty) || !mapping.repo.contains("/"))
                }
            }
        }
    }

    private var sourceSection: some View {
        Section {
            Picker("代码从哪来", selection: $mapping.workspace) {
                Text("手机工作区").tag(true)
                Text("小橘云盘文件夹").tag(false)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: { Text("代码从哪来") } footer: {
            Text(mapping.workspace
                 ? "工作区：从 DeepSeek 等 AI 复制来的代码粘贴进对话框，整理到手机里再推。保存后会先从 GitHub 拉一份下来。"
                 : "云盘：推小橘云盘里某个文件夹。")
        }
    }

    private var previewSection: some View {
        Section {
            Text("\(mapping.sourceLabel) → \(mapping.target)\(mapping.excludedPaths.isEmpty ? "" : "，跳过 \(mapping.excludedPaths.count) 个文件夹")")
                .font(.system(size: 15)).foregroundStyle(Theme.text)
        } header: { Text("预览") }
        .listRowBackground(Theme.card)
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
            .disabled(!store.ready || mapping.cloudPath.isEmpty || mapping.workspace)
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
