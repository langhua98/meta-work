import SwiftUI

// 纠错本：本地模型理解错、被纠正（或者云端代答）的话。
// 1. 马上有用：下次说相似的话，把最像的几条当例子塞进提示词。
// 2. 攒够了当训练数据：每行一个 JSON，scripts/finetune/make_data.py 读它（格式见 Fix.line）。
// 手机上一份（真正的那份），云盘 /小橘推送/纠错本/纠错本.jsonl 一份（换手机能拿回来，训练也从这里读）。

struct Fix: Identifiable, Equatable {
    enum Source: String { case user, cloud }
    let id: String
    /// 用户原话
    var text: String
    /// 上一句 / 上一步（跟模型看到的一样），没有就 nil
    var context: String?
    /// 错的指令 JSON（模型没输出合法指令就是 nil）
    var wrong: String?
    /// 对的指令 JSON，和语法一样的对象
    var right: String
    var model: String
    var at: Date
    var source: Source

    /// 存盘的一行
    var line: String {
        func obj(_ s: String?) -> Any {
            guard let s, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) else { return NSNull() }
            return o
        }
        let o: [String: Any] = ["id": id, "text": text, "context": context.map { $0 as Any } ?? NSNull(), "wrong": obj(wrong), "right": obj(right),
                                "model": model, "at": ISO8601DateFormatter().string(from: at), "source": source.rawValue]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    init(text: String, context: String?, wrong: Command?, right: Command, model: String, source: Source) {
        id = UUID().uuidString
        self.text = text
        self.context = context
        self.wrong = wrong?.json
        self.right = right.json
        self.model = model
        at = Date()
        self.source = source
    }

    init?(line: String) {
        guard let d = line.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let text = o["text"] as? String, let r = o["right"], !(r is NSNull),
              let rd = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]),
              let right = String(data: rd, encoding: .utf8) else { return nil }
        id = o["id"] as? String ?? UUID().uuidString
        self.text = text
        context = o["context"] as? String
        // 读回来的键是排过序的，按指令重新写一遍（"do" 在最前面，和提示词一样）
        if let w = o["wrong"], !(w is NSNull), let wd = try? JSONSerialization.data(withJSONObject: w, options: [.sortedKeys]),
           let ws = String(data: wd, encoding: .utf8) {
            wrong = Interpreter.parse(ws)?.json ?? ws
        } else {
            wrong = nil
        }
        self.right = Interpreter.parse(right)?.json ?? right
        model = o["model"] as? String ?? ""
        at = (o["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        source = Source(rawValue: o["source"] as? String ?? "") ?? .user
    }

    var rightCommand: Command? { Interpreter.parse(right) }
    var wrongCommand: Command? { wrong.flatMap { Interpreter.parse($0) } }
}

@MainActor
final class FixBook: ObservableObject {
    static let shared = FixBook()
    static let folder = "/小橘推送/纠错本"
    static let fileName = "纠错本.jsonl"
    /// 攒到这么多条提醒一次可以训新版
    static let trainAt = 50

    @Published private(set) var fixes: [Fix] = []
    /// 云盘那份还没跟上（没联网、没整理令牌）
    @Published private(set) var unsynced = false
    /// 本地模型没把握、云端做成了的那句也记下
    @Published var learnFromCloud = UserDefaults.standard.object(forKey: "fixbookLearnCloud") as? Bool ?? true {
        didSet { UserDefaults.standard.set(learnFromCloud, forKey: "fixbookLearnCloud") }
    }
    private var trainNoticed: Bool {
        get { UserDefaults.standard.bool(forKey: "fixbookTrainNoticed") }
        set { UserDefaults.standard.set(newValue, forKey: "fixbookTrainNoticed") }
    }

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("fixbook.jsonl")
    }()
    private var pulled = false

    private init() {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        fixes = raw.split(separator: "\n").compactMap { Fix(line: String($0)) }
        unsynced = UserDefaults.standard.bool(forKey: "fixbookUnsynced")
    }

    // MARK: 增删

    /// 记一条。同一句原话只留最新的（再纠正一次就以新的为准）。返回是第几条。
    @discardableResult
    func add(_ f: Fix, cloud: CloudFiles) -> Int {
        fixes.removeAll { Self.norm($0.text) == Self.norm(f.text) }
        fixes.append(f)
        save(cloud)
        return fixes.count
    }

    func remove(_ id: String, cloud: CloudFiles) {
        fixes.removeAll { $0.id == id }
        save(cloud)
    }

    /// 刚够数时返回 true（只提醒一次）
    func shouldNoticeTraining() -> Bool {
        guard fixes.count >= Self.trainAt, !trainNoticed else { return false }
        trainNoticed = true
        return true
    }

    private func save(_ cloud: CloudFiles) {
        let text = fixes.map(\.line).joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        setUnsynced(true)
        Task { await push(cloud) }
    }

    private func setUnsynced(_ v: Bool) {
        unsynced = v
        UserDefaults.standard.set(v, forKey: "fixbookUnsynced")
    }

    // MARK: 云盘

    /// 打开对话时调一次：手机上没有就从云盘拿（换了手机、重装）；有没传上去的就补传
    func sync(_ cloud: CloudFiles) async {
        if !pulled, fixes.isEmpty, let raw = try? await cloud.readText(Self.folder + "/" + Self.fileName) {
            pulled = true
            let got = raw.split(separator: "\n").compactMap { Fix(line: String($0)) }
            if !got.isEmpty, fixes.isEmpty {
                fixes = got
                try? (got.map(\.line).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            return
        }
        pulled = true
        if unsynced { await push(cloud) }
    }

    private func push(_ cloud: CloudFiles) async {
        guard cloud.canWrite else { return }
        do {
            try? await cloud.mkdir("/小橘推送")
            try? await cloud.mkdir(Self.folder)
            try await cloud.writeText(Self.folder + "/" + Self.fileName, fixes.map(\.line).joined(separator: "\n") + "\n")
            setUnsynced(false)
        } catch {
            setUnsynced(true)
        }
    }

    // MARK: 找相似的

    /// 跟这句话最像的几条，给提示词当例子。按字的两两组合算相似度，不用另外的模型。
    func similar(_ text: String, limit: Int = 3) -> [Fix] {
        let q = Self.grams(text)
        guard !q.isEmpty else { return [] }
        let scored = fixes.compactMap { f -> (Fix, Double)? in
            let g = Self.grams(f.text)
            let inter = Double(q.intersection(g).count)
            let uni = Double(q.union(g).count)
            guard uni > 0 else { return nil }
            let s = inter / uni
            return s >= 0.25 ? (f, s) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    static func norm(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static func grams(_ s: String) -> Set<String> {
        let c = Array(norm(s))
        guard c.count > 1 else { return c.isEmpty ? [] : [String(c)] }
        return Set((0..<(c.count - 1)).map { String(c[$0...$0 + 1]) })
    }
}

extension Command {
    /// 和语法一样的 JSON（纠错本、训练数据用）
    var json: String {
        var o: [String: Any]
        switch self {
        case .check(let t, let k): o = ["do": "check", "task": t ?? ""]; if !k.isEmpty { o["skip"] = k }
        case .push(let t, let k): o = ["do": "push", "task": t ?? ""]; if !k.isEmpty { o["skip"] = k }
        case .status: o = ["do": "status"]
        case .history(let t): o = ["do": "history", "task": t ?? ""]
        case .exclude(let t, let p): o = ["do": "exclude", "task": t ?? "", "path": p]
        case .find(let k, let f):
            if k.isEmpty { o = ["do": "list", "folder": f ?? "/"] }
            else { o = ["do": "find", "keyword": k]; if let f { o["folder"] = f } }
        case .mkdir(let p): o = ["do": "mkdir", "path": p]
        case .rename(let p, let to): o = ["do": "rename", "path": p, "to": to]
        case .move(let p, let to): o = ["do": "move", "path": p, "to": to]
        case .trash(let p): o = ["do": "trash", "path": p]
        case .remember(let s): o = ["do": "remember", "text": s]
        case .run(let c): o = ["do": "run", "cmd": c]
        case .search(let q): o = ["do": "search", "q": q]
        case .fetch(let u): o = ["do": "fetch", "url": u]
        case .shortcut(let n): o = ["do": "shortcut", "name": n]
        case .cloud(let s): o = ["do": "cloud", "text": s]
        case .say(let s): o = ["do": "say", "text": s]
        case .answer(let s): o = ["do": "answer", "text": s]
        }
        // 没说任务名的不写空字符串（语法里 task 是必填的，空的会教坏模型）
        if (o["task"] as? String) == "" { o.removeValue(forKey: "task") }
        // "do" 放最前面，跟提示词里的写法一样
        let d = o.removeValue(forKey: "do") as? String ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]),
              let rest = String(data: data, encoding: .utf8) else { return "{\"do\":\"\(d)\"}" }
        return rest == "{}" ? "{\"do\":\"\(d)\"}" : "{\"do\":\"\(d)\"," + rest.dropFirst()
    }
}

// MARK: 设置 → 纠错本

struct FixBookView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var book = FixBook.shared
    @State private var showAll = false
    @ObservedObject private var log = ChatLog.shared

    private var cloud: CloudFiles {
        CloudFiles(base: store.cloudURL.isEmpty ? Store.defaultCloudURL : store.cloudURL,
                   readToken: store.cloudToken, writeToken: store.organizeToken)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("下次升级本地模型").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text("\(book.fixes.count) / \(FixBook.trainAt) 条").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                    ProgressView(value: Double(min(book.fixes.count, FixBook.trainAt)), total: Double(FixBook.trainAt))
                        .tint(Theme.orange)
                    Text("攒够 \(FixBook.trainAt) 条，就能在 Kaggle 训一版新的。150 道老题加上这些新题打分，分数不掉才换上，否则继续用现在的。")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("现在就在用：你说到相似的话时，会把最像的 3 条当例子给本地模型看。")
            }
            .listRowBackground(Theme.card)

            if book.fixes.isEmpty {
                Section {
                    Text("还没有。本地模型理解错了，点那行字后面的「不对」就会记进来。").foregroundStyle(Theme.muted)
                }
                .listRowBackground(Theme.card)
            } else {
                Section {
                    ForEach(shown) { f in
                        row(f)
                            .swipeActions {
                                Button("删掉", role: .destructive) { Haptics.medium(); book.remove(f.id, cloud: cloud) }
                            }
                    }
                    if book.fixes.count > 20 && !showAll {
                        Button("还有 \(book.fixes.count - 20) 条") { showAll = true }.foregroundStyle(Theme.muted)
                    }
                } footer: {
                    Text("左滑删掉记错的。存在云盘 \(FixBook.folder)/，换手机也在。"
                         + (book.unsynced ? (!cloud.canWrite ? "这个云盘令牌没有写的权限，云盘那份写不进去。" : "有几条还没传到云盘，下次打开对话时补传。") : ""))
                }
                .listRowBackground(Theme.card)
            }

            Section {
                Toggle(isOn: $book.learnFromCloud) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("云端代答的也记下")
                        Text("本地模型没把握、交给云端做成了的那句").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                .tint(Theme.orange)
                Toggle(isOn: $log.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("对话存到云盘")
                        Text("每句话和小橘怎么理解、做没做成，存到 \(ChatLog.folder)/，看真实对话里错在哪、针对性训练。令牌和密码会抹掉。")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                .tint(Theme.orange)
            } footer: {
                if log.enabled && log.pending > 0 {
                    Text(!cloud.canWrite ? "有 \(log.pending) 条对话没传：这个云盘令牌没有写的权限。" : "有 \(log.pending) 条对话还没传，做完下一件事时补传。")
                }
            }
            .listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("纠错本")
        .task { await book.sync(cloud) }
    }

    private var shown: [Fix] {
        let all = book.fixes.reversed()
        return showAll ? Array(all) : Array(all.prefix(20))
    }

    private func row(_ f: Fix) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(f.text).font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(3)
            HStack(spacing: 4) {
                Text(f.wrongCommand?.summary ?? "没听懂").strikethrough()
                Text("→")
                Text(f.rightCommand?.summary ?? f.right)
            }
            .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(2)
            Text((f.source == .user ? "你纠正的" : "云端代答的") + " · " + Self.day(f.at))
                .font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 2)
    }

    private static func day(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "今天" }
        if Calendar.current.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter()
        f.dateFormat = "M 月 d 日"
        return f.string(from: d)
    }
}
