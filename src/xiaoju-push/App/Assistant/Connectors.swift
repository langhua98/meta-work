import SwiftUI

// 连接器：小橘云盘、GitHub、OpenCode 各是一个「连接器」，下面挂着几个工具。
// 关掉的工具：本地模型的提示词和语法里都拿掉（它根本选不到），云端也被告知不能用，执行时再拦一道。

struct ConnectorTool: Identifiable {
    let id: String
    let name: String
    /// 对应的指令（Command.kind）
    let kinds: [String]
    /// 会改东西的，执行前先出确认卡片
    var asks = false
}

struct Connector: Identifiable {
    let id: String
    let name: String
    let icon: String
    let note: String
    let tools: [ConnectorTool]

    static let cloud = Connector(id: "cloud", name: "小橘云盘", icon: "externaldrive", note: "你的代码和记忆都在这里", tools: [
        ConnectorTool(id: "cloud.find", name: "找文件", kinds: ["find"]),
        ConnectorTool(id: "cloud.list", name: "看文件夹", kinds: ["list"]),
        ConnectorTool(id: "cloud.mkdir", name: "新建文件夹", kinds: ["mkdir"], asks: true),
        ConnectorTool(id: "cloud.rename", name: "改名", kinds: ["rename"], asks: true),
        ConnectorTool(id: "cloud.move", name: "移动", kinds: ["move"], asks: true),
        ConnectorTool(id: "cloud.trash", name: "放进回收站", kinds: ["trash"], asks: true),
        ConnectorTool(id: "cloud.remember", name: "读写记忆", kinds: ["remember"], asks: true),
    ])
    static let github = Connector(id: "github", name: "GitHub", icon: "chevron.left.forwardslash.chevron.right", note: "把云盘里的代码推上去", tools: [
        ConnectorTool(id: "github.check", name: "检查改动", kinds: ["check", "status"]),
        ConnectorTool(id: "github.history", name: "推送记录", kinds: ["history"]),
        ConnectorTool(id: "github.push", name: "推送", kinds: ["push"], asks: true),
        ConnectorTool(id: "github.exclude", name: "设置不推的文件夹", kinds: ["exclude"], asks: true),
    ])
    static let opencode = Connector(id: "opencode", name: "OpenCode（云端）", icon: "cloud", note: "写代码、改 bug、解释代码这些难事", tools: [
        ConnectorTool(id: "opencode.ask", name: "交给云端处理", kinds: ["cloud"]),
    ])

    static let shell = Connector(id: "shell", name: "本机命令", icon: "terminal", note: "在手机工作区里跑 grep、git 这些命令", tools: [
        // 只看不改的直接跑；会改东西的（删文件、git commit/push…）每次先确认，见 ShellSafety
        ConnectorTool(id: "shell.run", name: "运行命令", kinds: ["run"]),
    ])

    static let all = [cloud, github, shell, opencode]
}

enum Connectors {
    private static let key = "connectorOff"

    /// 被关掉的工具 id；整个连接器关掉记成它的 id
    static var off: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: key) }
    }

    static func isOn(_ c: Connector) -> Bool { !off.contains(c.id) }
    static func isOn(_ t: ConnectorTool, in c: Connector) -> Bool { isOn(c) && !off.contains(t.id) }

    /// 现在能用的指令（say / answer 一直能用）
    static var enabledKinds: Set<String> {
        var s: Set<String> = ["say", "answer"]
        for c in Connector.all { for t in c.tools where isOn(t, in: c) { s.formUnion(t.kinds) } }
        return s
    }

    static let allKinds: Set<String> = Set(Connector.all.flatMap { $0.tools.flatMap(\.kinds) }).union(["say", "answer"])

    static var disabledKinds: Set<String> { allKinds.subtracting(enabledKinds) }

    /// 这条指令是哪个工具的（给「关掉了」的提示用）
    static func tool(for kind: String) -> (Connector, ConnectorTool)? {
        for c in Connector.all { if let t = c.tools.first(where: { $0.kinds.contains(kind) }) { return (c, t) } }
        return nil
    }

    /// 对话里小标签：「GitHub · 检查改动」
    static func label(for kind: String) -> String? {
        tool(for: kind).map { "\($0.0.name) · \($0.1.name)" }
    }
}

extension Command {
    var kind: String {
        switch self {
        case .check: return "check"
        case .push: return "push"
        case .status: return "status"
        case .history: return "history"
        case .exclude: return "exclude"
        case .find(let k, _): return k.isEmpty ? "list" : "find"
        case .mkdir: return "mkdir"
        case .rename: return "rename"
        case .move: return "move"
        case .trash: return "trash"
        case .remember: return "remember"
        case .run: return "run"
        case .cloud: return "cloud"
        case .say: return "say"
        case .answer: return "answer"
        }
    }
}

// MARK: 界面

struct ConnectorsView: View {
    @EnvironmentObject var store: Store
    @State private var refresh = 0

    var body: some View {
        List {
            Section {
                ForEach(Connector.all) { c in
                    NavigationLink { ConnectorDetailView(connector: c) } label: { row(c) }
                        .listRowBackground(Theme.card)
                }
            } footer: {
                Text("本地模型和云端只能用这里打开的工具。会改东西的工具（推送、移动、删除…）每次都会先出确认卡片。")
            }
        }
        .id(refresh)
        .onAppear { refresh += 1 }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("连接器")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ c: Connector) -> some View {
        let on = c.tools.filter { Connectors.isOn($0, in: c) }.count
        let linked = ConnectorDetailView.linked(c, store)
        return HStack(spacing: 12) {
            Image(systemName: c.icon).foregroundStyle(Theme.orangeText).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.text)
                Text(!linked ? "还没连上" : !Connectors.isOn(c) ? "已关掉" : "\(on) 个工具在用 · " + c.tools.filter { Connectors.isOn($0, in: c) }.map(\.name).joined(separator: "·"))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Circle().fill(linked && Connectors.isOn(c) ? Theme.green : Theme.faint).frame(width: 8, height: 8)
        }
    }
}

struct ConnectorDetailView: View {
    @EnvironmentObject var store: Store
    let connector: Connector
    @State private var off = Connectors.off
    @State private var result = ""
    @State private var testing = false

    static func linked(_ c: Connector, _ store: Store) -> Bool {
        switch c.id {
        case "cloud": return !store.cloudToken.isEmpty
        case "github": return !store.githubToken.isEmpty
        case "shell": return true
        default: return !store.openCodePassword.isEmpty
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { !off.contains(id) }, set: { v in
            Haptics.select()
            if v { off.remove(id) } else { off.insert(id) }
            Connectors.off = off
        })
    }

    var body: some View {
        Form {
            Section {
                switch connector.id {
                case "cloud":
                    TextField("地址", text: $store.cloudURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("xa_ 开头的令牌（只读）", text: $store.cloudToken)
                    SecureField("整理令牌（新建、移动、删除要用）", text: $store.organizeToken)
                case "github":
                    SecureField("GitHub 令牌", text: $store.githubToken)
                case "shell":
                    Text("不用登录。命令在手机里跑，只有 curl、git push / pull 这类会联网。")
                        .font(.footnote).foregroundStyle(Theme.muted)
                default:
                    TextField("地址", text: $store.openCodeURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("OpenCode 密码", text: $store.openCodePassword)
                    Toggle("本地搞不定自动问云端", isOn: $store.autoCloud).tint(Theme.orange)
                    Toggle("快速模式（DeepSeek Flash）", isOn: $store.cloudFast).tint(Theme.orange)
                }
                if connector.id != "opencode" {
                    Button {
                        test()
                    } label: {
                        HStack { Text(testing ? "测试中…" : "测试连接"); Spacer(); if testing { ProgressView() } }
                    }
                    .disabled(testing || !Self.linked(connector, store))
                }
                if !result.isEmpty { Text(result).font(.footnote).foregroundStyle(Theme.muted) }
            } header: { Text("账号") } footer: { Text(footer) }
            .listRowBackground(Theme.card)

            Section {
                Toggle("用这个连接器", isOn: binding(connector.id)).tint(Theme.orange)
            }
            .listRowBackground(Theme.card)

            Section {
                ForEach(connector.tools) { t in
                    Toggle(isOn: binding(t.id)) {
                        HStack(spacing: 6) {
                            Text(t.name)
                            if t.asks {
                                Text("先问你").font(.system(size: 11)).foregroundStyle(Theme.orangeText)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.orangeSoft, in: Capsule())
                            }
                        }
                    }
                    .tint(Theme.orange)
                    .disabled(off.contains(connector.id))
                }
            } header: { Text("模型能用的工具") } footer: {
                Text("关掉的工具，本地模型选不到，云端也不能让 App 做。")
            }
            .listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(connector.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var footer: String {
        switch connector.id {
        case "cloud": return "在网盘网页的「Agent 令牌」里新建。只读令牌够找文件、检查改动；新建、改名、移动、放回收站、写记忆要带「整理」权限的令牌。令牌存在手机钥匙串里。"
        case "shell": return "用的是 a-Shell 作者的 ios_system（BSD-3 开源）：ls、grep、sed、awk、tar、curl、git 等 70 多条命令。只看不改的直接跑；删文件、git commit / push 这类每次先问你。"
        case "github": return "GitHub → Settings → Developer settings → Personal access tokens 新建，要能写目标仓库（Contents: Read and write）。令牌存在手机钥匙串里。"
        default: return "密码是 Space 里的 OPENCODE_SERVER_PASSWORD。快速模式用 DeepSeek Flash，快很多；关掉用 V4 Pro，难题更稳但慢。云端只出方案，改东西前都会先问你。"
        }
    }

    private func test() {
        Haptics.tap()
        testing = true
        result = ""
        let e = store.engine()
        let id = connector.id
        Task {
            if id == "shell" {
                try? FileManager.default.createDirectory(at: Workspace.base, withIntermediateDirectories: true)
                let r = await ShellRunner.shared.run("echo 本机命令能用 && pwd && git version", cwd: Workspace.base) { _ in }
                result = (r.ok ? "✓ " : "✗ ") + r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if r.ok { Haptics.success() } else { Haptics.error() }
                testing = false
                return
            }
            do {
                result = id == "cloud" ? "✓ 连上了：\(try await e.checkCloud())" : "✓ 连上了：\(try await e.whoami())"
                Haptics.success()
            } catch {
                result = "✗ \(error.localizedDescription)"
                Haptics.error()
            }
            testing = false
        }
    }
}
