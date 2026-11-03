import SwiftUI

// 对话框的大脑：一句话 → 指令（关键词 / 本地模型 / 云端 OpenCode）→ 会改东西的先出确认卡片 → 执行，过程实时显示在对话里。

struct ToolCard: Equatable {
    enum State: Equatable { case busy, ok, failed }
    var icon: String
    var title: String
    var sub: String
    var state: State = .busy
    var progress: Double?
    var cloud = false
    /// 命令输出之类，等宽字体显示几行
    var detail: String?
}

struct CardButton: Identifiable {
    enum Style { case push, primary, cloud, plain }
    let id = UUID()
    let label: String
    let style: Style
    let run: @MainActor () -> Void
}

struct ActionCard {
    enum Tone { case push, primary, cloud }
    var title: String
    var lines: [String]
    var note: String?
    var tone: Tone
    var buttons: [CardButton]
    /// 点过按钮后显示的结果，按钮收起
    var status: String?
}

struct ChatItem: Identifiable {
    enum Kind {
        case user(String)
        case understood(String, source: String)
        case thinking(String)
        case tool(ToolCard)
        case text(String)
        case changes(Plan)
        case entries(title: String, items: [CloudEntry])
        case card(ActionCard)
        case error(String)
        case link(String, URL)
    }
    let id = UUID()
    var kind: Kind
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var busy = false
    @Published var pickMapping: Mapping?

    let store: Store
    let mapping: Mapping?
    private var job: Task<Void, Never>?
    private var plans: [UUID: Plan] = [:]
    private var lastCommand: String?
    private var recent: [String] = []
    private var memoryIndex = ""
    private var memoryLoaded = false

    init(store: Store, mapping: Mapping?) {
        self.store = store
        self.mapping = mapping
    }

    private var tasks: [TaskRef] { TaskRef.list(store.mappings) }
    private var files: CloudFiles {
        CloudFiles(base: store.cloudURL.isEmpty ? Store.defaultCloudURL : store.cloudURL,
                   readToken: store.cloudToken, writeToken: store.organizeToken)
    }
    private var cloudReady: Bool { !store.openCodePassword.isEmpty }

    // MARK: 对话条目

    @discardableResult
    private func add(_ k: ChatItem.Kind) -> UUID {
        let it = ChatItem(kind: k)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { items.append(it) }
        return it.id
    }

    private func update(_ id: UUID, _ k: ChatItem.Kind) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].kind = k
    }

    private func remove(_ id: UUID) {
        withAnimation { items.removeAll { $0.id == id } }
    }

    private func tool(_ id: UUID, _ f: (inout ToolCard) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }), case .tool(var t) = items[i].kind else { return }
        f(&t)
        items[i].kind = .tool(t)
    }

    private func resolveCard(_ id: UUID, _ status: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), case .card(var c) = items[i].kind else { return }
        c.status = status
        c.buttons = []
        items[i].kind = .card(c)
    }

    private func say(_ s: String) { add(.text(s)) }

    // MARK: 入口

    func start() {
        Task { await loadMemory() }
        guard let mapping, items.isEmpty else { return }
        add(.user("检查一下有什么改动"))
        run { await self.check(mapping) }
    }

    func stop() {
        job?.cancel()
        job = nil
        busy = false
    }

    func leave() {
        job?.cancel()
        Task { await LocalModel.shared.unload() }
    }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        Haptics.tap()
        add(.user(text))
        run { await self.handle(text) }
    }

    private func run(_ work: @escaping () async -> Void) {
        job?.cancel()
        busy = true
        job = Task {
            await work()
            if !Task.isCancelled { busy = false }
        }
    }

    private func loadMemory() async {
        guard !memoryLoaded, !store.cloudToken.isEmpty else { return }
        memoryIndex = await files.memoryIndex()
        memoryLoaded = true
    }

    // MARK: 听懂这句话

    private func handle(_ text: String) async {
        let ts = tasks
        if let c = Interpreter.keyword(text, tasks: ts, current: mapping) {
            add(.understood(c.summary, source: "直接认出来"))
            await execute(c, original: text)
            return
        }
        guard ModelStore.shared.downloaded else {
            if cloudReady && store.autoCloud {
                await askCloud(text, kind: "ask", auto: true)
            } else {
                say("这句话我要用本地模型才听得懂。去「设置 → 本地模型」下载一下（1.28 GB），或者说得简单点，比如「推送 \(ts.first?.name ?? "任务名")」。")
            }
            return
        }
        await loadMemory()
        let thinking = add(.thinking(LocalModelIsLoaded.value ? "本地模型在理解你的话" : "加载本地模型…"))
        let started = Date()
        let p = Interpreter.prompt(tasks: ts, current: mapping, memoryIndex: memoryIndex, last: lastCommand)
        let grammar = Interpreter.grammar(tasks: ts)
        let path = ModelStore.shared.fileURL.path
        let suffix = p.suffix(text)
        var out = ""
        do {
            try await LocalModel.shared.load(path: path)
            LocalModelIsLoaded.value = true
            update(thinking, .thinking("本地模型在理解你的话"))
            out = try await LocalModel.shared.generate(prefix: p.prefix, suffix: suffix, grammar: grammar)
        } catch {
            remove(thinking)
            add(.error(error.localizedDescription))
            return
        }
        remove(thinking)
        if Task.isCancelled { return }
        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
        guard let cmd = Interpreter.parse(out) else {
            if cloudReady && store.autoCloud { await askCloud(text, kind: "ask", auto: true) }
            else { say("没听懂，换个说法试试？") }
            return
        }
        switch cmd {
        case .say(let q) where cloudReady && store.autoCloud:
            // 小模型想反问的，先让云端带着记忆试一下
            add(.understood("本地模型没把握（\(q)）", source: "\(secs) 秒 · 没联网"))
            await askCloud(text, kind: "ask", auto: true)
        default:
            add(.understood(cmd.summary, source: "\(secs) 秒 · 没联网"))
            await execute(cmd, original: text)
        }
    }

    // MARK: 执行

    private func execute(_ cmd: Command, original: String) async {
        if let line = cmd.memoryLine { lastCommand = line }
        switch cmd {
        case .check(let t):
            guard let m = taskOrComplain(t) else { return }
            await check(m)
        case .push(let t):
            guard let m = taskOrComplain(t) else { return }
            await preparePush(m)
        case .status:
            await status()
        case .history(let t):
            guard let m = taskOrComplain(t) else { return }
            history(m)
        case .exclude(let t, let path):
            guard let m = taskOrComplain(t) else { return }
            confirmExclude(m, path)
        case .find(let k, let folder):
            await find(k, folder)
        case .mkdir(let p):
            confirmFileOp(.mkdir(path: p), entry: nil)
        case .rename(let p, _), .move(let p, _), .trash(let p):
            await resolveThen(p) { e in self.confirmFileOp(cmd, entry: e) }
        case .remember(let s):
            if cloudReady { await askCloud(s, kind: "remember", auto: true) }
            else { say("记忆要交给云端整理，先在设置里填 OpenCode 密码。") }
        case .cloud(let s):
            if cloudReady { confirmCloud(s.isEmpty ? original : s) }
            else { say("这件事要交给云端大模型，先在设置里填 OpenCode 密码。") }
        case .say(let q):
            say(q)
        }
    }

    private func taskOrComplain(_ name: String?) -> Mapping? {
        if let m = TaskRef.find(name, in: tasks, current: mapping) { return m }
        let names = tasks.map(\.name).joined(separator: "、")
        say(name == nil ? "是哪个任务？有：\(names)" : "没找到任务「\(name!)」。有：\(names)")
        return nil
    }

    // MARK: 检查和推送

    private static let iconGit = "arrow.triangle.branch"
    private static let iconFolder = "folder"
    private static let iconDiff = "text.alignleft"
    private static let iconUp = "arrow.up"

    @discardableResult
    private func check(_ m: Mapping, quiet: Bool = false) async -> Plan? {
        guard store.ready else { add(.error("先在设置里填好云盘令牌和 GitHub 令牌")); return nil }
        let engine = store.engine()
        let git = add(.tool(ToolCard(icon: Self.iconGit, title: "读取 GitHub 仓库", sub: m.repo + "…")))
        let ids = IDBox()
        do {
            let p = try await engine.plan(m, pushed: store.pushed) { s in
                Task { @MainActor in
                    if s.hasPrefix("读取云盘") {
                        self.tool(git) { $0.state = .ok; $0.sub = m.repo + (m.branch.isEmpty ? "" : " · " + m.branch) }
                        if ids.a == nil {
                            ids.a = self.add(.tool(ToolCard(icon: Self.iconFolder, title: "浏览云盘 \(m.cloudPath)", sub: "读取文件夹…")))
                        }
                    } else if s.hasPrefix("比较") {
                        if let c = ids.a { self.tool(c) { $0.state = .ok; $0.sub = m.excludedPaths.isEmpty ? "读完了" : "跳过 " + m.excludedPaths.joined(separator: "、") } }
                        let nums = s.dropFirst(3).split(separator: "：").first?.split(separator: "/") ?? []
                        let i = Double(nums.first ?? "") ?? 0, n = Double(nums.dropFirst().first ?? "") ?? 1
                        if ids.b == nil { ids.b = self.add(.tool(ToolCard(icon: Self.iconDiff, title: "逐个对比文件", sub: s))) }
                        if let c = ids.b { self.tool(c) { $0.sub = s; $0.progress = n > 0 ? i / n : nil } }
                    }
                }
            }
            store.record(p.confirmed)
            store.setPending(m, p.changes.count)
            plans[m.id] = p
            tool(git) { $0.state = .ok; $0.sub = "\(p.repo) · \(p.branch)" }
            if let c = ids.a { tool(c) { $0.state = .ok } }
            let new = p.changes.filter(\.isNew).count, mod = p.changes.count - new
            let sum = "\(p.unchanged) 个一样" + (new > 0 ? " · \(new) 个新文件" : "") + (mod > 0 ? " · \(mod) 个改了" : "")
            if let c = ids.b { tool(c) { $0.state = .ok; $0.progress = nil; $0.sub = sum } }
            else { add(.tool(ToolCard(icon: Self.iconDiff, title: "逐个对比文件", sub: sum, state: .ok))) }
            if quiet { return p }
            if p.changes.isEmpty {
                say("检查完了，和 GitHub 上一样，没有要推的。")
            } else {
                let risks = Risk.scan(p.changes)
                var s = "检查完了。有 \(p.changes.count) 个文件要推"
                if new > 0 { s += "，\(new) 个是新的" }
                s += "。"
                s += risks.contains { $0.level == .secret } ? "\n注意：发现像密码或令牌的内容，推之前看一眼。" : ""
                say(s)
                add(.changes(p))
                pushCard(m, p, risks: risks)
            }
            return p
        } catch {
            tool(git) { if $0.state == .busy { $0.state = .failed } }
            if let c = ids.a { tool(c) { if $0.state == .busy { $0.state = .failed } } }
            if let c = ids.b { tool(c) { $0.state = .failed; $0.progress = nil } }
            if !Task.isCancelled { add(.error(PushPhaseView.friendly(error.localizedDescription).title + "：" + error.localizedDescription)) }
            return nil
        }
    }

    private func preparePush(_ m: Mapping) async {
        guard let p = await check(m, quiet: true) else { return }
        if p.changes.isEmpty { say("和 GitHub 上一样，没有要推的。"); return }
        add(.changes(p))
        pushCard(m, p, risks: Risk.scan(p.changes))
    }

    private func commitMessage(_ p: Plan) -> String {
        PushView.defaultMessage(p, only: Set(p.changes.map(\.repoPath)), template: store.templates.first ?? Store.defaultTemplates[0])
    }

    private func pushCard(_ m: Mapping, _ p: Plan, risks: [Risk]) {
        let msg = commitMessage(p)
        var card = ActionCard(title: "要推这 \(p.changes.count) 个文件吗？",
                              lines: ["→ \(p.repo) · \(p.branch)"],
                              note: "提交说明：" + (msg.split(separator: "\n").first.map(String.init) ?? ""),
                              tone: .push, buttons: [])
        if risks.isEmpty { card.lines[0] += " · 没发现密码或令牌" }
        else { card.lines += risks.prefix(3).map { "⚠︎ " + $0.title } }
        var cid = UUID()
        card.buttons = [
            CardButton(label: "确认推送", style: .push) { [weak self] in
                guard let self else { return }
                Haptics.heavy()
                self.resolveCard(cid, "已确认")
                self.run { await self.commit(m, p, message: msg) }
            },
            CardButton(label: "挑文件", style: .plain) { [weak self] in self?.pickMapping = m },
            CardButton(label: "取消", style: .plain) { [weak self] in
                self?.resolveCard(cid, "没推")
                self?.say("好的，没推。")
            },
        ]
        cid = add(.card(card))
    }

    private func commit(_ m: Mapping, _ p: Plan, message: String) async {
        let engine = store.engine()
        let up = add(.tool(ToolCard(icon: Self.iconUp, title: "上传 \(p.changes.count) 个文件", sub: "准备…", progress: 0)))
        let ids = IDBox()
        do {
            let r = try await engine.commit(p, message: message) { s in
                Task { @MainActor in
                    if s.hasPrefix("上传") {
                        let nums = s.dropFirst(3).split(separator: "：").first?.split(separator: "/") ?? []
                        let i = Double(nums.first ?? "") ?? 0, n = Double(nums.dropFirst().first ?? "") ?? 1
                        self.tool(up) { $0.sub = s; $0.progress = n > 0 ? i / n : nil }
                    } else if s.hasPrefix("提交") {
                        self.tool(up) { $0.state = .ok; $0.progress = nil; $0.sub = "传完了" }
                        if ids.a == nil { ids.a = self.add(.tool(ToolCard(icon: Self.iconUp, title: "创建提交", sub: "…"))) }
                    } else if s.hasPrefix("推送") {
                        if let mk = ids.a { self.tool(mk) { $0.state = .ok; $0.sub = "好了" } }
                    }
                }
            }
            tool(up) { $0.state = .ok; $0.progress = nil; $0.sub = "传完了" }
            if let mk = ids.a { tool(mk) { $0.state = .ok; $0.sub = String(r.sha.prefix(7)) } }
            add(.tool(ToolCard(icon: Self.iconUp, title: "更新分支 \(p.branch)", sub: "不强推", state: .ok)))
            var rec: [String: Pushed] = [:]
            for c in p.changes { rec[p.recordKey(c.repoPath)] = Pushed(sha256: c.sha256, blob: c.blob) }
            store.record(rec)
            let added = p.changes.reduce(0) { $0 + $1.diff.added }
            let removed = p.changes.reduce(0) { $0 + $1.diff.removed }
            let title = message.split(separator: "\n").first.map(String.init) ?? message
            store.addHistory(HistoryEntry(task: m.id, repo: p.repo, branch: p.branch, sha: r.sha, url: r.url, title: title,
                                          files: p.changes.map(\.repoPath), added: added, removed: removed))
            store.setPending(m, 0)
            plans[m.id] = nil
            recent.append("推送 \(m.repo) \(p.changes.count) 个文件")
            Haptics.celebrate()
            say("推好了。\(p.changes.count) 个文件已经在 \(p.repo) 的 \(p.branch) 分支上，提交 \(r.sha.prefix(7))。")
            if let u = URL(string: r.url) { add(.link("在 GitHub 上看", u)) }
        } catch {
            tool(up) { if $0.state == .busy { $0.state = .failed; $0.progress = nil } }
            if let mk = ids.a { tool(mk) { if $0.state == .busy { $0.state = .failed } } }
            Haptics.error()
            let f = PushPhaseView.friendly(error.localizedDescription)
            add(.error("\(f.title)。\(f.advice)"))
        }
    }

    private func status() async {
        guard store.ready else { add(.error("先在设置里填好令牌")); return }
        let t = add(.tool(ToolCard(icon: Self.iconFolder, title: "检查所有任务", sub: "\(store.mappings.count) 个任务…")))
        await store.refreshPending()
        tool(t) { $0.state = .ok; $0.sub = "查完了" }
        let lines = tasks.map { r -> String in
            let n = store.pending[r.mapping.id] ?? 0
            return "· \(r.name)：" + (n > 0 ? "\(n) 个文件待推" : "没有改动")
        }
        say(lines.isEmpty ? "还没有任务。" : lines.joined(separator: "\n"))
    }

    private func history(_ m: Mapping) {
        let h = store.history(for: m).prefix(5)
        if h.isEmpty { say("\(m.repo) 还没有推送记录。"); return }
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        say(h.map { "· \(f.string(from: $0.date))  \($0.title)（\($0.files.count) 个文件）" }.joined(separator: "\n"))
    }

    private func confirmExclude(_ m: Mapping, _ path: String) {
        var cid = UUID()
        let rel = m.relativeToCloud(path)
        cid = add(.card(ActionCard(title: "以后不推这个文件夹？", lines: ["\(m.title) / \(rel)"],
                                   note: "检查时直接跳过，GitHub 上已有的不会删", tone: .primary, buttons: [
            CardButton(label: "确认", style: .primary) { [weak self] in
                guard let self else { return }
                var mm = self.store.mappings.first { $0.id == m.id } ?? m
                mm.addExclude(rel)
                self.store.upsert(mm)
                self.resolveCard(cid, "已加入不推的文件夹")
                self.recent.append("\(m.title) 不推 \(rel)")
                Haptics.success()
            },
            CardButton(label: "取消", style: .plain) { [weak self] in self?.resolveCard(cid, "没改") },
        ])))
    }

    // MARK: 云盘文件

    private func find(_ keyword: String, _ folder: String?) async {
        guard !store.cloudToken.isEmpty else { add(.error("先在设置里填云盘令牌")); return }
        let t = add(.tool(ToolCard(icon: "magnifyingglass", title: "在云盘里找「\(keyword)」", sub: folder ?? "整个云盘")))
        do {
            var hits = try await files.search(keyword, in: folder)
            if hits.isEmpty, let folder, keyword.isEmpty == false {
                // 「看看某个文件夹里有什么」也走这里
                hits = try await files.list(folder)
            }
            tool(t) { $0.state = .ok; $0.sub = "找到 \(hits.count) 个" }
            if hits.isEmpty { say("没找到。") } else { add(.entries(title: "找到 \(hits.count) 个", items: Array(hits.prefix(12)))) }
        } catch {
            tool(t) { $0.state = .failed; $0.sub = error.localizedDescription }
        }
    }

    /// 路径不准时按名字找；找到多个让你点一个
    private func resolveThen(_ path: String, _ then: @escaping (CloudEntry) -> Void) async {
        guard !store.cloudToken.isEmpty else { add(.error("先在设置里填云盘令牌")); return }
        let t = add(.tool(ToolCard(icon: "magnifyingglass", title: "找 \(path)", sub: "…")))
        do {
            let hits = try await files.resolve(path)
            tool(t) { $0.state = .ok; $0.sub = hits.count == 1 ? hits[0].fullPath : "找到 \(hits.count) 个" }
            if hits.isEmpty {
                say("云盘里找不到 \(path)。")
                if cloudReady && store.autoCloud {
                    await askCloud("找不到 \(path)，用户原话的意思可能另有所指：\(lastCommand ?? path)", kind: "ask", auto: true)
                }
            } else if hits.count == 1 {
                then(hits[0])
            } else {
                var cid = UUID()
                cid = add(.card(ActionCard(title: "是哪一个？", lines: [], note: nil, tone: .primary,
                                           buttons: hits.prefix(4).map { e in
                    CardButton(label: e.fullPath, style: .plain) { [weak self] in
                        self?.resolveCard(cid, "选了 \(e.fullPath)")
                        then(e)
                    }
                })))
            }
        } catch {
            tool(t) { $0.state = .failed; $0.sub = error.localizedDescription }
        }
    }

    private func confirmFileOp(_ cmd: Command, entry: CloudEntry?) {
        let (title, lines, label): (String, [String], String) = {
            switch cmd {
            case .mkdir(let p): return ("新建文件夹？", [CloudFiles.clean(p)], "确认新建")
            case .rename(_, let to): return ("改名？", ["\(entry?.fullPath ?? "") → \(to)"], "确认改名")
            case .move(_, let to): return ("移动\(entry?.isFolder == true ? "这个文件夹" : "这个文件")？",
                                           ["\(entry?.fullPath ?? "") → \(CloudFiles.clean(to))"], "确认移动")
            case .trash: return ("放进回收站？", [entry?.fullPath ?? ""], "放进回收站")
            default: return ("", [], "")
            }
        }()
        let note: String? = {
            if case .trash = cmd { return "在回收站里随时可以放回来，不会永久删除" }
            if !files.canWrite { return "还没填整理令牌，可能会失败" }
            return entry?.isFolder == true ? "里面的文件一起处理" : nil
        }()
        var cid = UUID()
        cid = add(.card(ActionCard(title: title, lines: lines, note: note, tone: .primary, buttons: [
            CardButton(label: label, style: .primary) { [weak self] in
                guard let self else { return }
                Haptics.medium()
                self.resolveCard(cid, "处理中…")
                self.run {
                    do {
                        try await self.perform(cmd, entry: entry)
                        self.resolveCard(cid, "✓ 好了")
                        self.recent.append(cmd.summary)
                        Haptics.success()
                    } catch {
                        self.resolveCard(cid, "没成功")
                        self.add(.error(error.localizedDescription))
                        Haptics.error()
                    }
                }
            },
            CardButton(label: "取消", style: .plain) { [weak self] in self?.resolveCard(cid, "没动") },
        ])))
    }

    private func perform(_ cmd: Command, entry: CloudEntry?) async throws {
        let f = files
        switch cmd {
        case .mkdir(let p): try await f.mkdir(p)
        case .rename(_, let to): if let e = entry { try await f.rename(e, to: to) }
        case .move(_, let to): if let e = entry { try await f.move(e, to: to) }
        case .trash: if let e = entry { try await f.trash(e) }
        default: break
        }
    }

    // MARK: 云端 OpenCode

    private func confirmCloud(_ text: String) {
        var cid = UUID()
        cid = add(.card(ActionCard(title: "交给云端大模型？",
                                   lines: ["HF 上的 OpenCode（DeepSeek）会帮你想办法。"],
                                   note: "会联网，会用一点 DeepSeek 额度。它只出方案，要执行还得你确认。",
                                   tone: .cloud, buttons: [
            CardButton(label: "交给它", style: .cloud) { [weak self] in
                guard let self else { return }
                self.resolveCard(cid, "交给云端了")
                self.run { await self.askCloud(text, kind: "ask", auto: false) }
            },
            CardButton(label: "算了", style: .plain) { [weak self] in
                self?.resolveCard(cid, "没发出去")
            },
        ])))
    }

    private func askCloud(_ text: String, kind: String, auto: Bool) async {
        let client = OpenCodeClient(base: store.openCodeURL, password: store.openCodePassword)
        let t = add(.tool(ToolCard(icon: "cloud", title: auto ? "问云端 OpenCode" : "交给 OpenCode", sub: "连接…", cloud: true)))
        do {
            await loadMemory()
            var mem: [(String, String)] = []
            if let list = try? await files.memoryFiles() {
                for e in list.prefix(20) where e.name != CloudFiles.memoryIndex {
                    if let s = try? await files.readText(e.fullPath) { mem.append((e.name, String(s.prefix(4096)))) }
                }
            }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let prompt = OpenCodeClient.prompt(request: text, kind: kind, tasks: tasks, memoryIndex: memoryIndex,
                                               memoryFiles: mem, recent: Array(recent.suffix(10)), today: f.string(from: Date()))
            let sid = store.openCodeSession.isEmpty ? nil : store.openCodeSession
            let cards = StepCards()
            var r: (reply: String, session: String)
            do {
                r = try await client.ask(prompt, sessionID: sid, status: { s in Task { @MainActor in self.tool(t) { $0.sub = s } } },
                                         steps: { st in Task { @MainActor in self.showSteps(st, cards: cards) } })
            } catch let e as PushError where sid != nil && e.message.contains("（404）") {
                // 会话没了（Space 重启过），开个新的
                r = try await client.ask(prompt, sessionID: nil, status: { s in Task { @MainActor in self.tool(t) { $0.sub = s } } },
                                         steps: { st in Task { @MainActor in self.showSteps(st, cards: cards) } })
            }
            store.openCodeSession = r.session
            tool(t) { $0.state = .ok; $0.sub = "回复了" }
            let reply = OpenCodeClient.parse(r.reply)
            if !reply.text.isEmpty { say(reply.text) }
            if let mu = reply.memory { memoryCard(mu) }
            if !reply.commands.isEmpty { cloudCommandsCard(reply.commands) }
            if reply.text.isEmpty && reply.memory == nil && reply.commands.isEmpty { say("OpenCode 没给出结果。") }
        } catch {
            tool(t) { $0.state = .failed; $0.sub = error.localizedDescription }
            if !Task.isCancelled { add(.error(error.localizedDescription)) }
        }
    }

    /// OpenCode 的每一步一张卡片：新的追加在下面，已有的更新状态和输出
    private func showSteps(_ steps: [CloudStep], cards: StepCards) {
        for st in steps {
            let icon: String = {
                let n = st.name.lowercased()
                if n.contains("bash") || n.contains("shell") || n.contains("exec") { return "terminal" }
                if n.contains("read") || n.contains("view") { return "doc.text" }
                if n.contains("write") || n.contains("edit") || n.contains("patch") { return "square.and.pencil" }
                if n.contains("grep") || n.contains("glob") || n.contains("search") || n.contains("find") { return "magnifyingglass" }
                if n.contains("fetch") || n.contains("web") { return "globe" }
                if n.contains("skill") { return "sparkles" }
                return "wrench.and.screwdriver"
            }()
            let title = st.name.isEmpty ? "工具" : st.name
            let sub = st.input.isEmpty ? "…" : st.input
            let state: ToolCard.State = st.failed ? .failed : (st.done ? .ok : .busy)
            let detail = st.output.isEmpty ? nil : st.tail
            if let id = cards.ids[st.id] {
                tool(id) { $0.sub = sub; $0.state = state; $0.detail = detail; $0.title = title; $0.icon = icon }
            } else {
                cards.ids[st.id] = add(.tool(ToolCard(icon: icon, title: title, sub: sub, state: state, cloud: true, detail: detail)))
            }
        }
    }

    private func cloudCommandsCard(_ cmds: [Command]) {
        // 只有一条就走普通流程（推送、改文件都会再出自己的确认卡片）
        if cmds.count == 1, let c = cmds.first {
            add(.understood(c.summary, source: "问了云端"))
            run { await self.execute(c, original: c.summary) }
            return
        }
        var cid = UUID()
        cid = add(.card(ActionCard(title: "云端建议做这 \(cmds.count) 件事", lines: cmds.prefix(12).map { "· " + $0.summary }
                                   + (cmds.count > 12 ? ["…还有 \(cmds.count - 12) 件"] : []),
                                   note: "还没动任何东西。确认后由手机一件件执行，不会永久删除。", tone: .primary, buttons: [
            CardButton(label: "确认执行", style: .primary) { [weak self] in
                guard let self else { return }
                self.resolveCard(cid, "执行中…")
                self.run { await self.runBatch(cmds, card: cid) }
            },
            CardButton(label: "取消", style: .plain) { [weak self] in self?.resolveCard(cid, "没动") },
        ])))
    }

    private func runBatch(_ cmds: [Command], card: UUID) async {
        var ok = 0, failed: [String] = []
        let t = add(.tool(ToolCard(icon: "checklist", title: "一件件执行", sub: "0 / \(cmds.count)", progress: 0)))
        for (i, c) in cmds.enumerated() {
            if Task.isCancelled { break }
            do {
                switch c {
                case .mkdir: try await perform(c, entry: nil)
                case .rename(let p, _), .move(let p, _), .trash(let p):
                    let hits = try await files.resolve(p)
                    guard hits.count == 1, hits[0].fullPath == CloudFiles.clean(p) || hits[0].name == PushEngine.clean(p).last
                    else { throw PushError("找不准 \(p)") }
                    try await perform(c, entry: hits[0])
                case .exclude(let task, let path):
                    if let m = TaskRef.find(task, in: tasks, current: mapping) {
                        var mm = m
                        mm.addExclude(mm.relativeToCloud(path))
                        store.upsert(mm)
                    }
                case .push(let task):
                    if let m = TaskRef.find(task, in: tasks, current: mapping), let p = await check(m, quiet: true), !p.changes.isEmpty {
                        await commit(m, p, message: commitMessage(p))
                    }
                default:
                    await execute(c, original: c.summary)
                }
                ok += 1
                recent.append(c.summary)
            } catch {
                failed.append("\(c.summary)：\(error.localizedDescription)")
            }
            tool(t) { $0.sub = "\(i + 1) / \(cmds.count)"; $0.progress = Double(i + 1) / Double(cmds.count) }
        }
        tool(t) { $0.state = failed.isEmpty ? .ok : .failed; $0.progress = nil }
        resolveCard(card, failed.isEmpty ? "✓ 都做完了" : "做了 \(ok) 件，\(failed.count) 件没成功")
        if !failed.isEmpty { add(.error(failed.prefix(5).joined(separator: "\n"))) }
    }

    private func memoryCard(_ mu: MemoryUpdate) {
        var lines = mu.files.map { "写入 \($0.name)" } + mu.remove.map { "删除 \($0)" }
        if !mu.index.isEmpty { lines.append("更新 索引.md") }
        guard !lines.isEmpty else { return }
        var cid = UUID()
        cid = add(.card(ActionCard(title: "要记住这条吗？", lines: lines,
                                   note: "存在云盘 /小橘推送/记忆/，随时可以在设置里看和删", tone: .primary, buttons: [
            CardButton(label: "记住", style: .primary) { [weak self] in
                guard let self else { return }
                self.resolveCard(cid, "写入中…")
                self.run {
                    do {
                        let f = self.files
                        try await f.mkdir(CloudFiles.memoryFolder)
                        for file in mu.files { try await f.writeText(CloudFiles.memoryFolder + "/" + file.name, file.content) }
                        for name in mu.remove {
                            if let e = try await f.item(CloudFiles.memoryFolder + "/" + name) { try await f.trash(e) }
                        }
                        if !mu.index.isEmpty {
                            try await f.writeText(CloudFiles.memoryFolder + "/" + CloudFiles.memoryIndex, mu.index)
                            self.memoryIndex = mu.index
                        }
                        self.resolveCard(cid, "✓ 记住了")
                        Haptics.success()
                    } catch {
                        self.resolveCard(cid, "没写进去")
                        self.add(.error(error.localizedDescription))
                    }
                }
            },
            CardButton(label: "不用", style: .plain) { [weak self] in self?.resolveCard(cid, "没记") },
        ])))
    }
}

/// 给界面判断模型是不是已经在内存里（只用来换提示文字）
enum LocalModelIsLoaded {
    @MainActor static var value = false
}

/// 进度回调里要改的条目 id（闭包里不能直接改外面的 var）
final class StepCards: @unchecked Sendable {
    var ids: [String: UUID] = [:]
}

final class IDBox: @unchecked Sendable {
    var a: UUID?
    var b: UUID?
}
