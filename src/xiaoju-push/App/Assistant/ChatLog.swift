import SwiftUI

// 对话记录：每句话、本地模型的原始输出、做了什么、成没成，都存一份到云盘 /小橘推送/对话/日期/，
// 用来找本地模型在真实对话里错在哪，针对性训下一版。
// 先记在手机上，每做完一件事传一次。每次传都是一个新文件，不覆盖旧的，也不往回收站塞东西。

@MainActor
final class ChatLog: ObservableObject {
    static let shared = ChatLog()
    static let folder = "/小橘推送/对话"

    @Published var enabled = UserDefaults.standard.object(forKey: "chatLogEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "chatLogEnabled") }
    }
    /// 还没传上去的条数
    @Published private(set) var pending = 0

    /// 这次打开 App 的编号，同一段对话的几次上传能串起来
    private let session = String(UUID().uuidString.prefix(8)).lowercased()
    private var made: Set<String> = []
    private var flushing = false

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("chatlog-pending.jsonl")
    }()

    private init() {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        pending = raw.split(separator: "\n").count
    }

    /// 记一条。role：user 用户的话 / model 本地模型原始输出 / understood 理解成什么 / tool、shell 做的事 /
    /// text 回复 / error 出错 / card 确认卡片 / wrong 用户点了「不对」
    func add(_ role: String, _ fields: [String: Any]) {
        guard enabled else { return }
        var row = fields
        row["role"] = role
        row["at"] = ISO8601DateFormatter().string(from: Date())
        row["session"] = session
        guard JSONSerialization.isValidJSONObject(row),
              let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        guard let h = try? FileHandle(forWritingTo: url) else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
            pending += 1
            return
        }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data((line + "\n").utf8))
        pending += 1
    }

    /// 把攒着的传上去（没写权限、没联网就留着下次再传）。secrets：要从记录里抹掉的令牌、密码
    func flush(_ cloud: CloudFiles, secrets: [String]) async {
        guard !flushing, pending > 0, cloud.canWrite,
              let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        let count = raw.split(separator: "\n").count
        let text = Self.redact(raw, secrets: secrets)
        let now = Date()
        let day = Self.stamp("yyyy-MM-dd", now)
        let folder = Self.folder + "/" + day
        do {
            for f in ["/小橘推送", Self.folder, folder] where !made.contains(f) {
                try? await cloud.mkdir(f)
                made.insert(f)
            }
            try await cloud.upload(folder + "/" + Self.stamp("HHmmss", now) + "-" + session + ".jsonl", Data(text.utf8))
        } catch {
            return
        }
        // 传的时候又记了新的：只删掉传上去的那几行
        let now2 = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let rest = now2.split(separator: "\n", omittingEmptySubsequences: true).dropFirst(count)
        try? (rest.isEmpty ? "" : rest.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        pending = rest.count
    }

    private static func stamp(_ format: String, _ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: d)
    }

    /// 令牌不进云盘：已知的令牌、密码直接替换，其它长得像令牌的也抹掉
    static func redact(_ s: String, secrets: [String]) -> String {
        var out = s
        for k in secrets where k.count >= 6 { out = out.replacingOccurrences(of: k, with: "[令牌已隐藏]") }
        let pattern = #"(hf_|KGAT_|ghp_|gho_|ghs_|github_pat_|sk-|xox[bp]-)[A-Za-z0-9_\-]{8,}"#
        return out.replacingOccurrences(of: pattern, with: "[令牌已隐藏]", options: .regularExpression)
    }

    /// 对话条目 → 一条记录（等待中的条目不记，做完了再记）
    func add(_ k: ChatItem.Kind) {
        switch k {
        case .user(let s): add("user", ["text": s])
        case .understood(let s, let source): add("understood", ["text": s, "source": source])
        case .text(let s): add("text", ["text": String(s.prefix(4000))])
        case .error(let s): add("error", ["text": s])
        case .link(let s, let u): add("link", ["text": s, "url": u.absoluteString])
        case .pasted(let s): add("pasted", ["text": String(s.prefix(600))])
        case .attachment(let a): add("attachment", ["text": a.name])
        case .entries(let title, let items): add("entries", ["text": title, "count": items.count])
        case .card(let c):
            if let st = c.status { add("card", ["text": c.title, "lines": c.lines, "status": st]) }
            else { add("card", ["text": c.title, "lines": c.lines]) }
        case .tool(let t) where t.state != .busy:
            var f: [String: Any] = ["text": t.title, "sub": t.sub, "ok": t.state == .ok, "cloud": t.cloud]
            if let d = t.detail { f["detail"] = String(d.prefix(1500)) }
            add("tool", f)
        case .shell(let c):
            switch c.state {
            case .pending, .running: break
            default: add("shell", ["text": c.command, "state": String(describing: c.state), "output": String(c.output.suffix(1500))])
            }
        default: break
        }
    }
}
