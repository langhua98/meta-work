import Foundation
import Security
import SwiftUI

// 令牌存钥匙串；推送任务和「上次推过什么」存 UserDefaults。
enum Keychain {
    private static let service = "com.langhua98.xiaoju.push"

    static func read(_ key: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ key: String, _ value: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// 一个推送任务：云盘文件夹 → 仓库 / 分支 / 仓库里的目录。
struct Mapping: Codable, Identifiable, Hashable {
    var id = UUID()
    var cloudPath = ""
    var repo = ""      // owner/name
    var branch = ""    // 空 = 仓库默认分支
    var repoPath = ""  // 空 = 仓库根目录
    /// 不推的文件夹（相对云盘文件夹），每行一个，比如「cloude审阅」
    var excludes = ""
    /// true = 代码在手机工作区（粘贴进来整理的），false = 小橘云盘文件夹
    var workspace = false

    init() {}

    // 旧版本存的任务没有 excludes，解码时缺了就用空
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        cloudPath = try c.decodeIfPresent(String.self, forKey: .cloudPath) ?? ""
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath) ?? ""
        excludes = try c.decodeIfPresent(String.self, forKey: .excludes) ?? ""
        workspace = try c.decodeIfPresent(Bool.self, forKey: .workspace) ?? false
    }

    /// 排除的相对路径（已清理），比如 ["cloude审阅", "docs/old"]
    /// 完整路径（/meta work/cloude审阅）和相对路径（cloude审阅）都认
    var excludedPaths: [String] {
        // 按换行（含 \r\n）、逗号、顿号分；Swift 里 "\r\n" 是一个字符，不能只比 "\n"
        excludes.components(separatedBy: CharacterSet(charactersIn: "\n\r\u{2028}\u{2029},，、"))
            .map { relativeToCloud($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// 云盘里的路径换成相对推送文件夹的路径；本来就是相对的原样返回
    func relativeToCloud(_ path: String) -> String {
        var segs = PushEngine.clean(path)
        let root = PushEngine.clean(cloudPath)
        if !root.isEmpty, segs.count >= root.count, Array(segs.prefix(root.count)) == root {
            segs.removeFirst(root.count)
        }
        return segs.joined(separator: "/")
    }

    /// 浏览选好一个文件夹后加进排除列表（存相对路径，重复的不加）
    mutating func addExclude(_ path: String) {
        let rel = relativeToCloud(path)
        guard !rel.isEmpty, !excludedPaths.contains(rel) else { return }
        excludes = excludes.trimmingCharacters(in: .whitespacesAndNewlines)
        excludes += (excludes.isEmpty ? "" : "\n") + rel
    }

    var title: String {
        let src = workspace ? repo : cloudPath
        let name = src.split(separator: "/").last.map(String.init) ?? src
        return name.isEmpty ? "未命名" : name
    }

    /// 代码从哪来，给界面显示
    var sourceLabel: String { workspace ? "手机工作区" : "云盘 \(cloudPath)" }

    var target: String {
        var s = repo.isEmpty ? "（没选仓库）" : repo
        if !branch.isEmpty { s += "@" + branch }
        if !repoPath.isEmpty { s += ":/" + repoPath }
        return s
    }
}

/// 某个文件上次推送时的云盘 sha256 和 git blob sha。
struct Pushed: Codable {
    var sha256: String
    var blob: String
}

/// 一次推送记录
struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var task: UUID
    var repo: String
    var branch: String
    var sha: String
    var url: String
    var title: String
    var files: [String]
    var added: Int
    var removed: Int
    var date = Date()
}

@MainActor
final class Store: ObservableObject {
    static let defaultCloudURL = "https://node.tail823dbd.ts.net"
    static let shared = Store()
    static let defaultTemplates = ["从小橘云盘更新 {文件}", "修复：{文件}", "新功能：{文件}", "整理代码：{文件}"]

    @Published var cloudURL: String { didSet { UserDefaults.standard.set(cloudURL, forKey: "cloudURL") } }
    @Published var cloudToken: String { didSet { Keychain.write("cloudToken", cloudToken) } }
    @Published var githubToken: String { didSet { Keychain.write("githubToken", githubToken) } }
    @Published var mappings: [Mapping] { didSet { save(mappings, "mappings"); saveSnapshot() } }
    @Published private(set) var history: [HistoryEntry] { didSet { save(history, "history") } }
    @Published var templates: [String] { didSet { save(templates, "templates") } }
    @Published var onboarded: Bool { didSet { UserDefaults.standard.set(onboarded, forKey: "onboarded") } }
    /// 0 跟随系统，1 浅色，2 深色
    @Published var appearance: Int { didSet { UserDefaults.standard.set(appearance, forKey: "appearance") } }
    /// 后台定时检查，有改动发通知
    @Published var autoCheck: Bool { didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheck") } }
    /// 每个任务大概有几个文件待推（只比云盘 sha256，不下载）
    @Published private(set) var pending: [UUID: Int] { didSet { save(pending, "pending"); saveSnapshot() } }
    @Published private(set) var lastChecked: Date? { didSet { UserDefaults.standard.set(lastChecked, forKey: "lastChecked") } }
    @Published var refreshing = false
    /// 点通知后要打开的任务
    @Published var openTask: UUID?
    /// 快捷指令「问小橘」发来的一句话（Assistant/Shortcuts.swift），首页收到就进对话框发出去
    @Published var askText: String?
    private(set) var pushed: [String: Pushed]
    /// 能改云盘文件的「整理」令牌（改名、移动、放回收站、写记忆）
    @Published var organizeToken: String { didSet { Keychain.write("organizeToken", organizeToken) } }
    /// HF 上的 OpenCode
    @Published var openCodeURL: String { didSet { UserDefaults.standard.set(openCodeURL, forKey: "openCodeURL") } }
    @Published var openCodePassword: String { didSet { Keychain.write("openCodePassword", openCodePassword) } }
    /// 本地模型搞不定时自动问云端
    @Published var autoCloud: Bool { didSet { UserDefaults.standard.set(autoCloud, forKey: "autoCloud") } }
    /// 云端用快模型（deepseek-flash），关掉用更强但慢的 v4-pro
    @Published var cloudFast: Bool { didSet { UserDefaults.standard.set(cloudFast, forKey: "cloudFast") } }
    /// 云控：配对口令，要和被控的那台一样（空着按 0 发）
    @Published var remotePair: String { didSet { Keychain.write("remotePair", remotePair) } }
    /// 云控：上次控制的设备名
    @Published var remoteTarget: String { didSet { UserDefaults.standard.set(remoteTarget, forKey: "remoteTarget") } }
    /// 接着用的 OpenCode 会话
    var openCodeSession: String {
        get { UserDefaults.standard.string(forKey: "openCodeSession") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "openCodeSession") }
    }
    var openCodeSessionAt: Date {
        get { UserDefaults.standard.object(forKey: "openCodeSessionAt") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "openCodeSessionAt") }
    }
    var openCodeTurns: Int {
        get { UserDefaults.standard.integer(forKey: "openCodeTurns") }
        set { UserDefaults.standard.set(newValue, forKey: "openCodeTurns") }
    }

    init() {
        let d = UserDefaults.standard
        cloudURL = d.string(forKey: "cloudURL") ?? Store.defaultCloudURL
        cloudToken = Keychain.read("cloudToken")
        githubToken = Keychain.read("githubToken")
        mappings = Store.load("mappings") ?? []
        pushed = Store.load("pushed") ?? [:]
        history = Store.load("history") ?? []
        templates = Store.load("templates") ?? Store.defaultTemplates
        appearance = d.integer(forKey: "appearance")
        autoCheck = d.bool(forKey: "autoCheck")
        pending = Store.load("pending") ?? [:]
        lastChecked = d.object(forKey: "lastChecked") as? Date
        organizeToken = Keychain.read("organizeToken")
        openCodeURL = d.string(forKey: "openCodeURL") ?? OpenCodeClient.defaultURL
        openCodePassword = Keychain.read("openCodePassword")
        autoCloud = d.object(forKey: "autoCloud") as? Bool ?? true
        cloudFast = d.object(forKey: "cloudFast") as? Bool ?? true
        remotePair = Keychain.read("remotePair")
        remoteTarget = d.string(forKey: "remoteTarget") ?? ""
        // 老用户已经填过令牌，不再显示引导
        onboarded = d.bool(forKey: "onboarded") || !Keychain.read("githubToken").isEmpty
    }

    var ready: Bool { !cloudToken.isEmpty && !githubToken.isEmpty }

    var colorScheme: ColorScheme? { appearance == 1 ? .light : appearance == 2 ? .dark : nil }

    var totalPending: Int { mappings.reduce(0) { $0 + (pending[$1.id] ?? 0) } }

    func engine() -> PushEngine {
        PushEngine(cloudBase: cloudURL.isEmpty ? Store.defaultCloudURL : cloudURL,
                   cloudToken: cloudToken, githubToken: githubToken)
    }

    func upsert(_ m: Mapping) {
        if let i = mappings.firstIndex(where: { $0.id == m.id }) { mappings[i] = m } else { mappings.append(m) }
        pending[m.id] = nil
    }

    func remove(_ m: Mapping) {
        mappings.removeAll { $0.id == m.id }
        pending[m.id] = nil
    }

    func record(_ entries: [String: Pushed]) {
        pushed.merge(entries) { _, new in new }
        save(pushed, "pushed")
    }

    func setPending(_ m: Mapping, _ n: Int) {
        pending[m.id] = n
        lastChecked = Date()
    }

    func addHistory(_ e: HistoryEntry) {
        history.insert(e, at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }
    }

    func history(for m: Mapping) -> [HistoryEntry] { history.filter { $0.task == m.id } }

    var lastPush: Date? { history.first?.date }

    /// 刷新每个任务的待推文件数。返回比上次多出改动的任务（给通知用）。
    @discardableResult
    func refreshPending() async -> [(Mapping, Int)] {
        guard ready, !refreshing else { return [] }
        refreshing = true
        defer { refreshing = false }
        let e = engine()
        var grew: [(Mapping, Int)] = []
        for m in mappings {
            guard let n = try? await e.pendingCount(m, pushed: pushed) else { continue }
            if n > (pending[m.id] ?? 0) { grew.append((m, n)) }
            pending[m.id] = n
        }
        lastChecked = Date()
        return grew
    }

    private func saveSnapshot() {
        WidgetSnapshot(tasks: mappings.map { .init(name: $0.title, repo: $0.repo, pending: pending[$0.id] ?? 0) },
                       updated: Date()).save()
        WidgetReloader.reload()
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        if let data = try? JSONEncoder().encode(v) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
