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
        case attachment(Attachment)
        case work(WorkLog)
        /// 粘贴进来的一大段代码（只显示前几行）
        case pasted(String)
        /// 粘贴的代码整理成的文件，等确认
        case paste(PasteDraft)
    }
    let id = UUID()
    var kind: Kind
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var busy = false
    @Published var pickMapping: Mapping?

    /// 整个 App 只有这一个对话：首页点任务也是进这里，只是换「当前任务」
    static let shared = ChatModel(store: Store.shared)

    let store: Store
    /// 当前任务（没说哪个任务时用它）
    @Published var mapping: Mapping?
    private var job: Task<Void, Never>?
    private var jobID = UUID()
    private var plans: [UUID: Plan] = [:]
    private var lastCommand: String?
    private var recent: [String] = []
    private var memoryIndex = ""
    private var memoryLoaded = false

    init(store: Store) {
        self.store = store
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
        watchBusy()
    }

    private var watching = false
    private var idleTicks = 0

    /// 保险：转圈中但界面上已经没有任何在跑的东西（没在想、没有转圈的卡片、云端没在干活）超过 6 秒，
    /// 就把发送键变回来。正常不会触发；万一哪里没收尾，不让人一直对着停止键。
    private func watchBusy() {
        guard !watching else { return }
        watching = true
        Task { @MainActor [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard self.busy else { self.idleTicks = 0; continue }
                let active = self.items.suffix(8).contains { it in
                    switch it.kind {
                    case .thinking: return true
                    case .tool(let t): return t.state == .busy
                    case .work(let w): return w.running
                    default: return false
                    }
                }
                self.idleTicks = active ? 0 : self.idleTicks + 1
                if self.idleTicks >= 3 {
                    self.idleTicks = 0
                    self.jobID = UUID()
                    self.job = nil
                    self.busy = false
                }
            }
        }
    }

    /// 从首页点了某个任务：只换当前任务，不自动检查（要检查点「检查改动」或直接说）
    func focus(_ m: Mapping) {
        // 同一个任务也换成最新的（设置里改了「不推的文件夹」要马上生效）
        mapping = m
    }

    func stop() {
        job?.cancel()
        job = nil
        jobID = UUID()
        busy = false
        // 还在转圈的都收掉、标成停了，不留一个一直转的
        items.removeAll { if case .thinking = $0.kind { return true }; return false }
        for i in items.indices {
            switch items[i].kind {
            case .tool(var t) where t.state == .busy:
                t.state = .failed; t.progress = nil; t.sub = "停了"
                items[i].kind = .tool(t)
            default: break
            }
        }
        add(.text("停了。"))
    }

    /// 离开对话页：云端在干的活照样跑完，回来还能看到；只把本地模型从内存里放掉
    func leave() {
        guard !busy else { return }
        Task { await LocalModel.shared.unload() }
    }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        Haptics.tap()
        // 粘贴进来的代码（比如 DeepSeek 的回答）：整理成文件
        if CodePaste.looksLikeCode(text) {
            add(.pasted(text))
            run { await self.organize(text) }
            return
        }
        add(.user(text))
        run { await self.handle(text) }
    }

    // MARK: 粘贴代码 → 文件

    /// 当前任务；没选但只有一个任务就用它
    var currentTask: Mapping? {
        if let m = mapping, let fresh = store.mappings.first(where: { $0.id == m.id }) { return fresh }
        return store.mappings.count == 1 ? store.mappings[0] : nil
    }

    /// 任务里所有文件的相对路径
    func taskFiles(_ m: Mapping) async throws -> [String] {
        if m.workspace { return Workspace(mapping: m).files() }
        return try await store.engine().walk(m.cloudPath, excluding: m.excludedPaths).map(\.0)
    }

    /// 任务里某个文件的内容（云盘的要下载）
    func readTaskFile(_ m: Mapping, _ rel: String) async -> Data? {
        if m.workspace { return Workspace(mapping: m).read(rel) }
        let path = "/" + (PushEngine.clean(m.cloudPath) + PushEngine.clean(rel)).joined(separator: "/")
        return try? await files.readData(path)
    }

    private func organize(_ text: String) async {
        guard let m = currentTask else {
            say("先选个任务：点上面的标题切换，或者去首页点一个任务，再粘贴。")
            return
        }
        let blocks = CodePaste.blocks(text)
        guard !blocks.isEmpty else { say("没认出代码。"); return }
        let t = add(.tool(ToolCard(icon: "doc.on.clipboard", title: "整理 \(blocks.count) 段代码", sub: m.sourceLabel)))
        var list: [String] = []
        do { list = try await taskFiles(m) } catch {
            tool(t) { $0.state = .failed; $0.sub = error.localizedDescription }
            return
        }
        // 按内容找类名只在工作区里做（本地读，快）
        let ws = m.workspace ? Workspace(mapping: m) : nil
        let textFiles = list.filter(CodePaste.isText)
        var drafts: [FileDraft] = []
        for (i, b) in blocks.enumerated() {
            let r = CodePaste.resolve(b, files: textFiles.isEmpty ? list : textFiles) { f in
                ws?.read(f).flatMap { String(data: $0, encoding: .utf8) }
            }
            var d = FileDraft(path: r?.0 ?? "", code: b.code, isNew: r?.1 ?? true,
                              how: r?.2 ?? "第 \(i + 1) 段没认出放哪，填个路径")
            if let r, !r.1 {
                let old = await readTaskFile(m, r.0)
                let diff = FileDiff.make(old: old, new: Data(b.code.utf8))
                d.added = diff.added
                d.removed = diff.removed
            } else {
                d.added = b.code.split(separator: "\n", omittingEmptySubsequences: false).count
            }
            drafts.append(d)
        }
        tool(t) { $0.state = .ok; $0.sub = "认出 \(drafts.filter { !$0.path.isEmpty }.count) 个文件" }
        add(.paste(PasteDraft(task: m, files: drafts)))
    }

    func pasteEdit(_ id: UUID, file: UUID, path: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), case .paste(var p) = items[i].kind,
              let j = p.files.firstIndex(where: { $0.id == file }) else { return }
        p.files[j].path = CodePaste.cleanPath(path)
        items[i].kind = .paste(p)
    }

    func pasteDrop(_ id: UUID, file: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), case .paste(var p) = items[i].kind else { return }
        p.files.removeAll { $0.id == file }
        items[i].kind = .paste(p)
    }

    /// 写进工作区（或云盘）；andPush 就接着检查并出推送卡片
    func pasteSave(_ id: UUID, andPush: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }), case .paste(var p) = items[i].kind else { return }
        let files = p.files.filter { !$0.path.isEmpty }
        guard !files.isEmpty else { return }
        p.status = "保存中…"
        items[i].kind = .paste(p)
        let m = p.task
        run {
            do {
                if m.workspace {
                    let ws = Workspace(mapping: m)
                    try ws.ensure()
                    for f in files { try ws.write(f.path, Data(f.code.utf8)) }
                } else {
                    guard self.files.canWrite else { throw PushError("写云盘要先在设置里填整理令牌") }
                    for f in files {
                        let path = "/" + (PushEngine.clean(m.cloudPath) + PushEngine.clean(f.path)).joined(separator: "/")
                        try await self.files.upload(path, Data(f.code.utf8))
                    }
                }
                self.setPasteStatus(id, "✓ 放好了 \(files.count) 个文件")
                self.recent.append("把粘贴的代码整理成 \(files.map(\.path).joined(separator: "、"))")
                Haptics.success()
                if andPush { await self.preparePush(m) }
            } catch {
                self.setPasteStatus(id, "没放进去")
                self.add(.error(error.localizedDescription))
            }
        }
    }

    func pasteCancel(_ id: UUID) { setPasteStatus(id, "没动") }

    private func setPasteStatus(_ id: UUID, _ s: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), case .paste(var p) = items[i].kind else { return }
        p.status = s
        items[i].kind = .paste(p)
    }

    /// 从 GitHub 拉到工作区
    func pull(_ m: Mapping) {
        run {
            let t = self.add(.tool(ToolCard(icon: "arrow.down.circle", title: "从 GitHub 拉到工作区", sub: m.repo + "…")))
            do {
                let r = try await self.store.engine().pull(m, pushed: self.store.pushed) { s in
                    Task { @MainActor in self.tool(t) { $0.sub = s } }
                }
                self.store.record(r.records)
                self.tool(t) { $0.state = .ok; $0.sub = "拉了 \(r.written) 个文件" }
                self.say(r.kept.isEmpty ? "工作区和 GitHub 一样了。"
                         : "工作区更新好了。这 \(r.kept.count) 个你改过还没推，没覆盖：\(r.kept.prefix(5).joined(separator: "、"))")
                await self.store.refreshPending()
            } catch {
                self.tool(t) { $0.state = .failed; $0.sub = error.localizedDescription }
            }
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        job?.cancel()
        busy = true
        let id = UUID()
        jobID = id
        job = Task {
            await work()
            // 只有最新的那件事做完才算空闲（被新的一句话顶掉的旧任务不管）
            if jobID == id { busy = false }
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
        if let c = Interpreter.keyword(text, tasks: ts, current: currentTask) {
            add(.understood(c.summary, source: "快捷按钮"))
            await execute(c, original: text)
            return
        }
        guard ModelStore.shared.downloaded else {
            if cloudReady && store.autoCloud {
                await askCloud(text, kind: "ask", auto: true)
            } else {
                say("这句话我要用本地模型才听得懂。去「设置 → 本地模型」下载一下（\(ByteCountFormatter.string(fromByteCount: ModelStore.shared.info.bytes, countStyle: .file))），或者说得简单点，比如「推送 \(ts.first?.name ?? "任务名")」。")
            }
            return
        }
        await loadMemory()
        let thinking = add(.thinking(LocalModelIsLoaded.value ? "本地模型在理解你的话" : "加载本地模型…"))
        let started = Date()
        // 上一句话和上一步一起给模型，「交给云端」「再移回来」这种才知道说的是什么
        let ctx = [previousUserText().map { "上一句：\(String($0.prefix(200)))" }, lastCommand.map { "上一步：\($0)" }]
            .compactMap { $0 }.joined(separator: "；")
        let p = Interpreter.prompt(tasks: ts, current: currentTask, memoryIndex: memoryIndex, last: ctx.isEmpty ? nil : ctx)
        let grammar = Interpreter.grammar(tasks: ts)
        let path = ModelStore.shared.fileURL.path
        let suffix = p.suffix(text)
        var out = ""
        do {
            try await LocalModel.shared.load(path: path)
            LocalModelIsLoaded.value = true
            update(thinking, .thinking("本地模型在理解你的话"))
            // 每秒更新一下秒数，看得出它在算、没卡死
            let ticker = Task { @MainActor [weak self] in
                var n = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    n += 1
                    if n >= 2 { self?.update(thinking, .thinking("本地模型在理解你的话（\(n) 秒）")) }
                }
            }
            defer { ticker.cancel() }
            // 提示里写的是 2B，换成现在用的模型名（问「你是谁」时答对）
            let prefix = p.prefix.replacingOccurrences(of: "Qwen3.5-2B", with: ModelStore.shared.info.short)
            out = try await LocalModel.shared.generate(prefix: prefix, suffix: suffix, grammar: grammar, maxTokens: 320)
        } catch {
            remove(thinking)
            if !(error is CancellationError) && !Task.isCancelled { add(.error(error.localizedDescription)) }
            return
        }
        remove(thinking)
        if Task.isCancelled { return }
        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
        guard let cmd = Interpreter.parse(out).flatMap({ Interpreter.plausible($0, text) ? $0 : nil }) else {
            // 小模型没听懂或者瞎猜（比如闲聊被翻成「找文件」），不乱执行
            if cloudReady && store.autoCloud { await askCloud(text, kind: "ask", auto: true) }
            else { say("这句我没把握，就不乱做了。可以说得具体点，比如「推送 \(ts.first?.name ?? "任务名")」「找一下 PushEngine」；写代码、解释代码这类要在设置里填 OpenCode 密码交给云端。") }
            return
        }
        switch cmd {
        case .say(let q) where cloudReady && store.autoCloud:
            // 小模型想反问的，先让云端带着记忆试一下
            add(.understood("本地模型没把握（\(q)）", source: "\(secs) 秒 · 没联网"))
            await askCloud(text, kind: "ask", auto: true)
        default:
            let via = Connectors.label(for: cmd.kind).map { " · " + $0 } ?? ""
            add(.understood(cmd.summary, source: "\(secs) 秒 · 没联网" + via))
            await execute(cmd, original: text)
        }
    }

    // MARK: 执行

    private func execute(_ cmd: Command, original: String) async {
        // 连接器里关掉的工具不做
        if !Connectors.enabledKinds.contains(cmd.kind), let hit = Connectors.tool(for: cmd.kind) {
            say("「\(hit.0.name) · \(hit.1.name)」在连接器里关掉了，要用就去「设置 → 连接器 → \(hit.0.name)」打开。")
            return
        }
        if let line = cmd.memoryLine { lastCommand = line }
        switch cmd {
        case .check(let t, let skip):
            guard let m = taskOrComplain(t) else { return }
            let (mm, extra) = withSkips(m, skip)
            await check(mm)
            offerKeepExcludes(m, extra)
        case .push(let t, let skip):
            guard let m = taskOrComplain(t) else { return }
            let (mm, extra) = withSkips(m, skip)
            await preparePush(mm)
            offerKeepExcludes(m, extra)
        case .status:
            await status()
        case .history(let t):
            guard let m = taskOrComplain(t) else { return }
            history(m)
        case .exclude(let t, let path):
            guard let m = taskOrComplain(t) else { return }
            confirmExclude(m, path)
        case .find(let k, let folder):
            await find(k, folder, hint: original)
        case .mkdir(let p):
            confirmFileOp(.mkdir(path: p), entry: nil)
        case .rename(let p, _), .move(let p, _), .trash(let p):
            await resolveThen(p) { e in self.confirmFileOp(cmd, entry: e) }
        case .remember(let s):
            if cloudReady { await askCloud(s, kind: "remember", auto: true) }
            else { say("记忆要交给云端整理，先在设置里填 OpenCode 密码。") }
        case .run(let c):
            await shell(c, original: original)
        case .cloud(let s):
            // 用户原话交给云端（小模型转述常会抄错），云端自己给的指令才用它的文字
            // 再带上用户上一句原话，「交给云端处理」这种短句云端才知道是哪件事
            var ask = original.isEmpty || original == cmd.summary ? s : original
            if !original.isEmpty, original != cmd.summary, let prev = previousUserText() {
                ask = "用户上一句：\(prev)\n用户这一句：\(original)"
            }
            if cloudReady && store.autoCloud { await askCloud(ask, kind: "ask", auto: true) }
            else if cloudReady { confirmCloud(ask) }
            else { say("这件事要交给云端大模型，先在设置里填 OpenCode 密码。") }
        case .say(let q), .answer(let q):
            say(q)
        }
    }

    /// 模型听出来「这次跳过 7day」：这次检查 / 推送先跳过这些文件夹
    private func withSkips(_ m: Mapping, _ skip: [String]) -> (Mapping, [String]) {
        let extra = skip
            .map { m.relativeToCloud($0) }
            .filter { !$0.isEmpty && !m.excludedPaths.contains($0) }
        guard !extra.isEmpty else { return (m, []) }
        var mm = m
        for e in extra { mm.addExclude(e) }
        return (mm, extra)
    }

    /// 这次跳过的，问一句要不要以后都跳过
    private func offerKeepExcludes(_ m: Mapping, _ extra: [String]) {
        guard !extra.isEmpty else { return }
        var cid = UUID()
        cid = add(.card(ActionCard(title: "以后也都跳过？", lines: extra.map { "\(m.title) / \($0)" },
                                   note: "这次已经跳过了。确认后以后检查、推送都不管这些文件夹", tone: .primary, buttons: [
            CardButton(label: "以后都跳过", style: .primary) { [weak self] in
                guard let self else { return }
                var mm = self.store.mappings.first { $0.id == m.id } ?? m
                for e in extra { mm.addExclude(e) }
                self.store.upsert(mm)
                self.resolveCard(cid, "已加入不推的文件夹")
                Haptics.success()
            },
            CardButton(label: "只这一次", style: .plain) { [weak self] in self?.resolveCard(cid, "只跳过这一次") },
        ])))
    }

    /// 这一句之前用户说的最后一句（跳过同样是「交给云端」的话）
    private func previousUserText() -> String? {
        var seenCurrent = false
        for it in items.reversed() {
            guard case .user(let s) = it.kind else { continue }
            if !seenCurrent { seenCurrent = true; continue }
            return s
        }
        return nil
    }

    private func taskOrComplain(_ name: String?) -> Mapping? {
        if let m = TaskRef.find(name, in: tasks, current: currentTask) { return m }
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
                    if s.hasPrefix("读取云盘") || s.hasPrefix("读取工作区") {
                        self.tool(git) { $0.state = .ok; $0.sub = m.repo + (m.branch.isEmpty ? "" : " · " + m.branch) }
                        if ids.a == nil {
                            ids.a = self.add(.tool(ToolCard(icon: Self.iconFolder, title: "浏览\(m.sourceLabel)", sub: "读取文件夹…")))
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
            if Task.isCancelled { say("检查停了。") }
            else { add(.error(PushPhaseView.friendly(error.localizedDescription).title + "：" + error.localizedDescription)) }
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

    private func find(_ keyword: String, _ folder: String?, hint: String = "") async {
        guard !store.cloudToken.isEmpty else { add(.error("先在设置里填云盘令牌")); return }
        // 没有关键词（或者小模型把「云盘」「文件夹」当成了关键词）= 看看文件夹里有什么
        let k = keyword.trimmingCharacters(in: .whitespaces)
        if k.isEmpty || ["云盘", "文件夹", "目录", "文件", "所有文件", "全部"].contains(k) {
            await listFolder(folder, hint: hint)
            return
        }
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

    /// 列出云盘某个文件夹里有什么。没指定文件夹时，拿原话去对根目录里真实的文件夹名，
    /// 话里提到了哪个就列哪个，都没提到就列根目录（不再把「读取」「小橘」这种词当文件夹名）
    private func listFolder(_ folder: String?, hint: String = "") async {
        var path = folder.map { CloudFiles.clean($0) } ?? "/"
        if path.isEmpty { path = "/" }
        let t = add(.tool(ToolCard(icon: Self.iconFolder, title: "看看云盘", sub: "读取…")))
        do {
            if path != "/", try await files.item(path) == nil {
                path = try await files.resolve(path).first(where: \.isFolder)?.fullPath ?? "/"
            }
            if path == "/", !hint.isEmpty {
                func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }
                let said = norm(hint)
                let root = try await files.list("/", limit: 200).filter(\.isFolder)
                if let hit = root.filter({ said.contains(norm($0.name)) && norm($0.name).count >= 2 })
                    .max(by: { $0.name.count < $1.name.count }) {
                    path = hit.fullPath
                }
            }
            let all = try await files.list(path, limit: 200)
            let dirs = all.filter(\.isFolder), others = all.filter { !$0.isFolder }
            tool(t) { $0.state = .ok; $0.title = "看看云盘 \(path == "/" ? "根目录" : path)"; $0.sub = "\(dirs.count) 个文件夹 · \(others.count) 个文件" }
            if all.isEmpty { say("这个文件夹是空的。"); return }
            add(.entries(title: "\(path == "/" ? "云盘根目录" : path) · \(dirs.count) 个文件夹、\(others.count) 个文件", items: Array((dirs + others).prefix(50))))
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

    // MARK: 本机命令（Shell/ShellRunner.swift）

    /// 命令在哪里跑：当前任务是工作区就进它的文件夹，不然在「工作区」总文件夹
    private func shellFolder() -> (URL, String) {
        if let m = currentTask, m.workspace {
            let w = Workspace(mapping: m)
            try? w.ensure()
            return (w.root, "工作区 / " + w.root.lastPathComponent)
        }
        try? FileManager.default.createDirectory(at: Workspace.base, withIntermediateDirectories: true)
        return (Workspace.base, "工作区")
    }

    private func shell(_ command: String, original: String) async {
        switch ShellSafety.check(command) {
        case .safe:
            await runShell(command)
        case .missing(let name):
            if cloudReady {
                var cid = UUID()
                cid = add(.card(ActionCard(title: "手机上没有 \(name) 这个命令", lines: ["$ " + command],
                                           note: "要交给云端 OpenCode 去跑吗？", tone: .cloud, buttons: [
                    CardButton(label: "交给云端", style: .cloud) { [weak self] in
                        guard let self else { return }
                        self.resolveCard(cid, "交给云端了")
                        self.run { await self.askCloud(original.isEmpty ? command : original, kind: "ask", auto: false) }
                    },
                    CardButton(label: "不用", style: .plain) { [weak self] in self?.resolveCard(cid, "没跑") },
                ])))
            } else {
                say("手机上没有 \(name) 这个命令。能用的有 grep、sed、awk、git、curl、tar 这些。")
            }
        case .confirm(let why):
            var cid = UUID()
            cid = add(.card(ActionCard(title: "跑这条命令？", lines: ["$ " + command],
                                       note: why + "。在「\(shellFolder().1)」里跑。", tone: .primary, buttons: [
                CardButton(label: "运行", style: .primary) { [weak self] in
                    guard let self else { return }
                    self.resolveCard(cid, "已确认")
                    self.run { await self.runShell(command) }
                },
                CardButton(label: "不要", style: .plain) { [weak self] in self?.resolveCard(cid, "没跑") },
            ])))
        }
    }

    private func runShell(_ command: String) async {
        let (dir, label) = shellFolder()
        await prepareGit()
        let t = add(.tool(ToolCard(icon: "terminal", title: "$ " + command, sub: "在「\(label)」里跑", detail: "")))
        let box = ShellOutputBox()
        // 输出在后台线程来，攒起来每 0.2 秒刷一次界面
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let d = box.takeIfChanged() { self?.tool(t) { $0.detail = ShellOutputBox.tail(d) } }
            }
        }
        let r = await ShellRunner.shared.run(command, cwd: dir) { box.append($0) }
        ticker.cancel()
        let secs = r.seconds < 10 ? String(format: "%.1f 秒", r.seconds) : "\(Int(r.seconds)) 秒"
        let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        tool(t) {
            $0.state = r.ok ? .ok : .failed
            $0.detail = out.isEmpty ? (r.ok ? "（没有输出）" : nil) : ShellOutputBox.tail(out)
            $0.sub = r.killed ? "停了 · \(secs)" : (r.ok ? "\(label) · \(secs)" : "出错了（退出码 \(r.status)）· \(secs)")
        }
        lastCommand = "跑了命令 \(command)" + (r.ok ? "" : "，出错了")
    }

    /// git 配置：提交作者用 GitHub 用户名，推送用 GitHub 令牌。只在第一次跑命令时问一下 GitHub 你是谁。
    private func prepareGit() async {
        let d = UserDefaults.standard
        if d.string(forKey: "gitLogin") == nil, !store.githubToken.isEmpty {
            var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
            req.setValue("Bearer \(store.githubToken)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 8
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let login = o["login"] as? String, let id = o["id"] as? Int {
                d.set(login, forKey: "gitLogin")
                d.set("\(id)+\(login)@users.noreply.github.com", forKey: "gitEmail")
            }
        }
        ShellRunner.writeGitConfig(name: d.string(forKey: "gitLogin") ?? "", email: d.string(forKey: "gitEmail") ?? "",
                                   token: store.githubToken)
    }

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
        let w = add(.work(WorkLog(title: auto ? "问云端 OpenCode" : "交给 OpenCode", status: "连接…")))
        do {
            await loadMemory()
            // 接着用最近的会话（20 分钟内、不到 6 轮），记忆它已经看过，不再重发；太久或太长就开新会话，越长越慢
            let reuse = store.openCodeSession.isEmpty == false
                && Date().timeIntervalSince(store.openCodeSessionAt) < 20 * 60 && store.openCodeTurns < 6
            let sid = reuse ? store.openCodeSession : nil
            // 记忆文件一起读，不一个个等；总共最多 12KB
            var mem: [(String, String)] = []
            if !reuse, let list = try? await files.memoryFiles() {
                let picked = Array(list.filter { $0.name != CloudFiles.memoryIndex }.prefix(20))
                let fs = files
                mem = await withTaskGroup(of: (Int, String, String)?.self) { g in
                    for (i, e) in picked.enumerated() {
                        g.addTask { (try? await fs.readText(e.fullPath)).map { (i, e.name, String($0.prefix(4096))) } }
                    }
                    var out: [(Int, String, String)] = []
                    for await x in g { if let x { out.append(x) } }
                    return out.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
                }
                var total = 0
                mem = mem.filter { total += $0.1.utf8.count; return total <= 12_000 }
            }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let prompt = OpenCodeClient.prompt(request: text, kind: kind, tasks: tasks, memoryIndex: memoryIndex,
                                               memoryFiles: mem, recent: Array(recent.suffix(10)), today: f.string(from: Date()),
                                               followUp: reuse)
            var r: (reply: String, session: String)
            do {
                r = try await client.ask(prompt, sessionID: sid, fast: store.cloudFast, status: { s in Task { @MainActor in self.work(w) { $0.status = s } } },
                                         steps: { st in Task { @MainActor in self.work(w) { $0.steps = st } } })
            } catch let e as PushError where sid != nil && e.message.contains("（404）") {
                // 会话没了（Space 重启过），开个新的
                r = try await client.ask(prompt.replacingOccurrences(of: "（同这个会话前面发过的）", with: "（这次没带）"), sessionID: nil, fast: store.cloudFast, status: { s in Task { @MainActor in self.work(w) { $0.status = s } } },
                                         steps: { st in Task { @MainActor in self.work(w) { $0.steps = st } } })
            }
            if r.session != store.openCodeSession { store.openCodeTurns = 0 }
            store.openCodeSession = r.session
            store.openCodeSessionAt = Date()
            store.openCodeTurns += 1
            work(w) { $0.finished = Date(); $0.status = "完成" }
            let reply = OpenCodeClient.parse(r.reply)
            if !reply.text.isEmpty { say(reply.text) }
            if let mu = reply.memory { memoryCard(mu) }
            if !reply.commands.isEmpty { cloudCommandsCard(reply.commands) }
            if !reply.files.isEmpty { await showFiles(reply.files, client: client) }
            if reply.text.isEmpty && reply.memory == nil && reply.commands.isEmpty && reply.files.isEmpty { say("OpenCode 没给出结果。") }
        } catch {
            work(w) { $0.finished = Date(); $0.failed = true; $0.status = error.localizedDescription }
            if !Task.isCancelled { add(.error(error.localizedDescription)) }
        }
    }

    private func work(_ id: UUID, _ f: (inout WorkLog) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }), case .work(var w) = items[i].kind else { return }
        f(&w)
        items[i].kind = .work(w)
    }

    /// 下载 OpenCode 发来的文件，存到本机缓存，对话里按类型显示
    private func showFiles(_ paths: [String], client: OpenCodeClient) async {
        for p in paths.prefix(10) {
            let name = (p as NSString).lastPathComponent
            let t = add(.tool(ToolCard(icon: "arrow.down.circle", title: "接收 \(name)", sub: p, cloud: true)))
            do {
                let data = try await client.download(p)
                let url = try Attachment.save(data, name: name)
                tool(t) { $0.state = .ok; $0.sub = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }
                remove(t)
                add(.attachment(Attachment(name: name, remotePath: p, url: url, size: data.count)))
            } catch {
                tool(t) { $0.state = .failed; $0.sub = error.localizedDescription }
            }
        }
    }

    /// 附件存进云盘 /小橘推送/附件/日期/
    func saveToCloud(_ a: Attachment) async throws -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let folder = "/小橘推送/附件/" + f.string(from: Date())
        let data = try Data(contentsOf: a.url)
        let c = files
        try? await c.mkdir("/小橘推送")
        try? await c.mkdir("/小橘推送/附件")
        try? await c.mkdir(folder)
        let path = folder + "/" + a.name
        try await c.upload(path, data)
        recent.append("把 \(a.name) 存到云盘 \(folder)")
        return path
    }

    private func cloudCommandsCard(_ all: [Command]) {
        // 连接器里关掉的，云端说了也不做
        let on = Connectors.enabledKinds
        let cmds = all.filter { on.contains($0.kind) }
        let dropped = all.filter { !on.contains($0.kind) }
        if !dropped.isEmpty {
            say("云端还想做这些，但对应的工具在连接器里关掉了，没做：" + dropped.prefix(5).map(\.summary).joined(separator: "；"))
        }
        guard !cmds.isEmpty else { return }
        // 只看不改的（列文件、看记录）直接做；推送、检查、改文件这些先问用户
        if cmds.count == 1, let c = cmds.first {
            switch c {
            case .find, .status, .history, .say, .answer:
                add(.understood(c.summary, source: "问了云端"))
                run { await self.execute(c, original: c.summary) }
            default:
                var cid = UUID()
                cid = add(.card(ActionCard(title: "云端建议：\(c.summary)", lines: [],
                                           note: "还没动。要做就点确认。", tone: .primary, buttons: [
                    CardButton(label: "确认", style: .primary) { [weak self] in
                        guard let self else { return }
                        self.resolveCard(cid, "已确认")
                        self.run { await self.execute(c, original: c.summary) }
                    },
                    CardButton(label: "不用", style: .plain) { [weak self] in self?.resolveCard(cid, "没做") },
                ])))
            }
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
                    if let m = TaskRef.find(task, in: tasks, current: currentTask) {
                        var mm = m
                        mm.addExclude(mm.relativeToCloud(path))
                        store.upsert(mm)
                    }
                case .push(let task, _):
                    if let m = TaskRef.find(task, in: tasks, current: currentTask), let p = await check(m, quiet: true), !p.changes.isEmpty {
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
/// 命令输出从后台线程攒到这里，界面定时来取
final class ShellOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var changed = false

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        text += s
        if text.count > 20_000 { text = String(text.suffix(10_000)) }
        changed = true
    }

    func takeIfChanged() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard changed else { return nil }
        changed = false
        return text
    }

    /// 卡片上只放最后 12 行
    static func tail(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 12 else { return s }
        return "…（前面 \(lines.count - 12) 行收起来了）\n" + lines.suffix(12).joined(separator: "\n")
    }
}

enum LocalModelIsLoaded {
    @MainActor static var value = false
}

/// 进度回调里要改的条目 id（闭包里不能直接改外面的 var）
final class IDBox: @unchecked Sendable {
    var a: UUID?
    var b: UUID?
}
