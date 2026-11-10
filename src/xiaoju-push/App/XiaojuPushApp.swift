import SwiftUI

@main
struct XiaojuPushApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .preferredColorScheme(store.colorScheme)
                .tint(Theme.orange)
                .onAppear { MemoryHUD.install() }
        }
        .backgroundTask(.appRefresh(BackgroundCheck.id)) { await BackgroundCheck.run() }
    }
}

enum Route: Hashable {
    case history(Mapping)
    /// 唯一的对话框（编码助手）；点任务也是进这里
    case assistant
    /// 下载仓库 ZIP
    case zip
    /// 双机推理（两台手机合跑 Qwen3.5-9B）
    case pipe
    /// 遥控（云控）：经小橘云盘控制法莉娅 / Vania，2026-11 从设置挪到首页
    case remote
}

// 首页：推送任务列表。点一个任务 → 看改了什么 → 提交并推送。
struct HomeView: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var phase
    @State private var editing: Mapping?
    @State private var showSettings = false
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                if !store.ready {
                    Section {
                        Button { Haptics.tap(); showSettings = true } label: {
                            Label("先填小橘云盘令牌和 GitHub 令牌", systemImage: "key.fill").foregroundStyle(Theme.orangeText)
                        }
                        .buttonStyle(PressStyle())
                        .listRowBackground(Theme.card)
                    }
                }
                Section {
                    ForEach(store.mappings) { m in
                        Button { Haptics.tap(); open(m) } label: {
                            TaskRow(mapping: m, pending: store.pending[m.id])
                        }
                        .buttonStyle(PressStyle())
                        .listRowBackground(Theme.card)
                        .listRowSeparatorTint(Theme.divider)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { Haptics.medium(); store.remove(m) } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button { Haptics.tap(); editing = m } label: { Label("编辑", systemImage: "pencil") }
                                .tint(Theme.blueFill)
                        }
                        .swipeActions(edge: .leading) {
                            Button { Haptics.tap(); path.append(.history(m)) } label: {
                                Label("记录", systemImage: "clock.arrow.circlepath")
                            }
                            .tint(Theme.orange)
                        }
                        .contextMenu {
                            Button { open(m) } label: { Label("检查改动", systemImage: "arrow.triangle.2.circlepath") }
                            Button { path.append(.history(m)) } label: { Label("推送记录", systemImage: "clock") }
                            Button { editing = m } label: { Label("编辑", systemImage: "pencil") }
                            Button(role: .destructive) { store.remove(m) } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("我的任务").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                } footer: {
                    Text(store.mappings.isEmpty
                         ? "点右上角 + 添加：选一个云盘文件夹，推到哪个 GitHub 仓库的哪个目录。"
                         : "左滑编辑或删除，右滑看推送记录，下拉刷新改动数。云盘删掉的文件不会在 GitHub 上删除。")
                        .foregroundStyle(Theme.muted)
                }
                Section {
                    Button { Haptics.tap(); path.append(.remote) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.orangeText).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("遥控").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.text)
                                Text("经小橘云盘控制别的设备：实时画面、移动侦测、拍照、手电…").font(.system(size: 13)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.faint)
                        }
                    }
                    .buttonStyle(PressStyle())
                    .listRowBackground(Theme.card)
                    Button { Haptics.tap(); path.append(.zip) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox").foregroundStyle(Theme.orangeText).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("下载仓库 ZIP").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.text)
                                Text("和 GitHub 上 Code → Download ZIP 一样").font(.system(size: 13)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.faint)
                        }
                    }
                    .buttonStyle(PressStyle())
                    .listRowBackground(Theme.card)
                    Button { Haptics.tap(); path.append(.pipe) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.gen2.radiowaves.left.and.right").foregroundStyle(Theme.orangeText).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("双机推理").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.text)
                                Text("两台手机合跑 Qwen3.5-9B，一台装不下的模型").font(.system(size: 13)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.faint)
                        }
                    }
                    .buttonStyle(PressStyle())
                    .listRowBackground(Theme.card)
                } header: {
                    Text("工具").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                }
                if !store.mappings.isEmpty && store.ready {
                    Section {
                        Button {
                            Haptics.medium()
                            Task { await store.refreshPending() }
                        } label: {
                            Label(store.refreshing ? "正在刷新…" : "刷新全部改动数", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(BigButtonStyle(kind: .push))
                        .disabled(store.refreshing)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("推送任务")
            .navigationDestination(for: Route.self) { r in
                switch r {
                case .history(let m): HistoryView(mapping: m)
                case .assistant: ChatView()
                case .zip: RepoZipView()
                case .pipe: PipeHomeView()
                case .remote: RemoteView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Haptics.tap(); showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.tap(); path.append(.assistant) } label: {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                    }
                    .accessibilityLabel("编码助手")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.tap(); var m = Mapping(); m.workspace = true; editing = m } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.black)
                            .frame(width: 30, height: 30)
                            .background(Theme.orange, in: Circle())
                    }
                    .accessibilityLabel("新建任务")
                }
            }
            .refreshable {
                Haptics.tap()
                await store.refreshPending()
            }
            .task { await store.refreshPending() }
            .sheet(item: $editing) { m in MappingEditView(mapping: m) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: Binding(get: { !store.onboarded }, set: { if !$0 { store.onboarded = true } })) {
                OnboardingView()
            }
            .onChange(of: store.openTask) { openFromNotification() }
            .onAppear { openFromNotification(); askFromShortcut() }
            .onChange(of: store.askText) { askFromShortcut() }
            .onChange(of: phase) {
                if phase == .background {
                    BackgroundCheck.schedule()
                    Task { await ChatModel.shared.flushLog() }
                }
            }
        }
    }

    private func askFromShortcut() {
        guard let t = store.askText else { return }
        store.askText = nil
        path = [.assistant]
        ChatModel.shared.send(t)
    }

    private func openFromNotification() {
        guard let id = store.openTask else { return }
        store.openTask = nil
        if let m = store.mappings.first(where: { $0.id == id }) { open(m) }
    }

    /// 进对话框并检查这个任务（和右上角进的是同一个对话）
    private func open(_ m: Mapping) {
        ChatModel.shared.focus(m)
        path = [.assistant]
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(store.ready ? Theme.green : Theme.faint).frame(width: 8, height: 8)
                Text(store.ready ? "云盘和 GitHub 已设置" : "还没设置令牌").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
                if store.refreshing {
                    ProgressView().controlSize(.mini)
                    Text("刷新中").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 8) {
                StatTile(value: "\(store.mappings.count)", label: "个任务", color: Theme.text)
                StatTile(value: "\(store.totalPending)", label: "个文件待推", color: Theme.blueText)
                StatTile(value: store.lastPush.map(Self.short) ?? "还没有", label: "上次推送", color: Theme.green)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private static func short(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

struct StatTile: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.spring, value: value)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

struct TaskRow: View {
    let mapping: Mapping
    let pending: Int?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 16))
                .frame(width: 36, height: 36)
                .foregroundStyle((pending ?? 0) > 0 ? Theme.orangeText : Theme.muted)
                .background((pending ?? 0) > 0 ? Theme.orangeSoft : Theme.raised, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(mapping.repo.split(separator: "/").last.map(String.init) ?? mapping.title)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    Pill(text: mapping.branch.isEmpty ? "默认分支" : mapping.branch, mono: !mapping.branch.isEmpty)
                    Text(mapping.sourceLabel).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            badge
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var badge: some View {
        if let n = pending {
            if n > 0 {
                Pill(text: "\(n) 个改动")
            } else {
                Pill(text: "已同步", fg: Theme.muted, bg: Theme.raised)
            }
        } else {
            Pill(text: "未检查", fg: Theme.muted, bg: Theme.raised)
        }
    }
}
