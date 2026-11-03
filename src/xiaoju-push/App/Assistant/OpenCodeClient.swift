import Foundation

// 交给 HF 上的 OpenCode（douyin-proxy Space，默认 DeepSeek）。
// Space 对自己带 Authorization 的请求原样转给 OpenCode：Basic 认证，用户名 opencode，密码是 OPENCODE_SERVER_PASSWORD。

struct CloudReply {
    var text: String
    var commands: [Command]
    var memory: MemoryUpdate?
}

/// OpenCode 给的记忆改动：要写的文件 + 新索引
struct MemoryUpdate: Equatable {
    var files: [(name: String, content: String)]
    var remove: [String]
    var index: String

    static func == (a: MemoryUpdate, b: MemoryUpdate) -> Bool {
        a.index == b.index && a.remove == b.remove && a.files.map(\.name) == b.files.map(\.name)
            && a.files.map(\.content) == b.files.map(\.content)
    }
}

final class OpenCodeClient {
    static let defaultURL = "https://langhua1998-douyin-proxy.hf.space"

    private let base: String
    private let password: String
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 900
        return URLSession(configuration: c)
    }()

    init(base: String, password: String) {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty { b = Self.defaultURL }
        if !b.hasPrefix("http") { b = "https://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        self.base = b
        self.password = password
    }

    private func send(_ method: String, _ path: String, body: [String: Any]?, status: (String) -> Void) async throws -> Any? {
        guard let url = URL(string: base + path) else { throw PushError("OpenCode 地址不对") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        let auth = Data("opencode:\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // 免费 Space 睡着时先返回 502/503，最多等 3 分钟让它醒
        let deadline = Date().addingTimeInterval(180)
        while true {
            try Task.checkCancellation()
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                return data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
            }
            if (code == 502 || code == 503 || code == 504) && Date() < deadline {
                status("服务器在睡觉，等它醒…")
                try await Task.sleep(nanoseconds: 8_000_000_000)
                continue
            }
            if code == 401 { throw PushError("OpenCode 密码不对，去设置里改") }
            let text = String(decoding: data.prefix(200), as: UTF8.self)
            throw PushError("OpenCode 出错（\(code)）\(text.isEmpty ? "" : "：" + text)")
        }
    }

    /// 发一句话，等 OpenCode 回完。sessionID 传进来就接着上次的会话。
    func ask(_ prompt: String, sessionID: String?, status: @escaping (String) -> Void) async throws -> (reply: String, session: String) {
        var sid = sessionID ?? ""
        if sid.isEmpty {
            status("连接 OpenCode…")
            let s = try await send("POST", "/session", body: ["title": "小橘推送"], status: status) as? [String: Any]
            sid = s?["id"] as? String ?? ""
            if sid.isEmpty { throw PushError("OpenCode 没给会话号") }
        }
        status("OpenCode 在想…")
        let r = try await send("POST", "/session/\(sid)/message",
                               body: ["parts": [["type": "text", "text": prompt]]], status: status)
        let parts = (r as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, sid)
    }

    // MARK: 提示词和回复

    static let memoryRules = """
    记忆规则（照着做）：
    - 记忆是 /小橘推送/记忆/ 里一个主题一个 .md 文件，加一个索引.md（每行「- 文件名：一句话说明」，最多 30 行）。
    - 每个文件开头三行：名字、一句话说明、类型（偏好 / 纠正 / 约定 / 位置）。纠正要写原因。
    - 同一主题改已有文件，不新开重复的；记错的删掉；App 和 GitHub 里查得到的（任务列表、推送记录）不记。
    - 「昨天」「上周」换成具体日期；每个文件不超过 4KB；问句、闲聊、只跟这一次有关的事不记。
    """

    static func prompt(request: String, kind: String, tasks: [TaskRef], memoryIndex: String,
                       memoryFiles: [(String, String)], recent: [String], today: String) -> String {
        let taskLines = tasks.map { "- \($0.name)：云盘 \($0.mapping.cloudPath) → \($0.mapping.repo)" }.joined(separator: "\n")
        let files = memoryFiles.map { "### \($0.0)\n\($0.1)" }.joined(separator: "\n\n")
        var p = """
        你是 iPhone 上编码助手「小橘推送」背后的大模型：用户的代码在小橘云盘里，App 负责推到 GitHub。今天是 \(today)。用中文，简短。
        推送任务：
        \(taskLines.isEmpty ? "（没有）" : taskLines)

        最近做过的事：
        \(recent.isEmpty ? "（没有）" : recent.map { "- " + $0 }.joined(separator: "\n"))

        记忆索引：
        \(memoryIndex.isEmpty ? "（空）" : memoryIndex)

        记忆文件：
        \(files.isEmpty ? "（空）" : files)

        """
        if kind == "remember" {
            p += """

            用户说：\(request)
            \(memoryRules)
            把这件事更新进记忆。最后只输出一个 ```json 代码块：
            {"do":"memory","files":[{"name":"文件名.md","content":"整个文件的新内容"}],"remove":["要删的文件名.md"],"index":"索引.md 的新全文"}
            前面用一句话说你记了什么。
            """
        } else {
            p += """

            用户说：\(request)
            手机上的小模型没搞定，你来。写代码、改 bug、解释、审查都行；可以用工具看小橘云盘和仓库里的代码（如果有）。
            要 App 执行的话，最后输出一个 ```json 代码块，是指令数组（只能用这些）：
            {"do":"push","task":任务名} {"do":"check","task":任务名} {"do":"exclude","task":任务名,"path":"文件夹"}
            {"do":"find","keyword":"…"} {"do":"mkdir","path":"/…"} {"do":"rename","path":"/…","to":"新名字"}
            {"do":"move","path":"/…","to":"/目标文件夹"} {"do":"trash","path":"/…"}
            不要自己改云盘或推送：App 会先给用户看、用户确认后由 App 执行。不需要执行就不输出代码块，直接回答。
            """
        }
        return p
    }

    /// 从回复里拿出说明文字、指令、记忆改动
    static func parse(_ reply: String) -> CloudReply {
        var text = reply
        var json = ""
        if let r = reply.range(of: "```json", options: .backwards),
           let e = reply.range(of: "```", range: r.upperBound..<reply.endIndex) {
            json = String(reply[r.upperBound..<e.lowerBound])
            text = String(reply[..<r.lowerBound]) + String(reply[e.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data) else {
            return CloudReply(text: text, commands: [], memory: nil)
        }
        if let o = any as? [String: Any], (o["do"] as? String) == "memory" {
            let files = (o["files"] as? [[String: Any]] ?? []).compactMap { f -> (String, String)? in
                guard let n = f["name"] as? String, let c = f["content"] as? String, Self.safeName(n) else { return nil }
                return (n, c)
            }
            let remove = (o["remove"] as? [String] ?? []).filter { Self.safeName($0) && $0 != CloudFiles.memoryIndex }
            let index = o["index"] as? String ?? ""
            return CloudReply(text: text, commands: [], memory: MemoryUpdate(files: files.map { (name: $0.0, content: $0.1) },
                                                                             remove: remove, index: index))
        }
        let list = (any as? [[String: Any]]) ?? ((any as? [String: Any]).map { [$0] } ?? [])
        let cmds = list.compactMap { o -> Command? in
            guard let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) else { return nil }
            switch Interpreter.parse(s) {
            case .cloud?, .say?, .remember?, nil: return nil
            case let c?: return c
            }
        }
        return CloudReply(text: text, commands: cmds, memory: nil)
    }

    /// 记忆文件名只能是一层的 .md，不能带路径
    static func safeName(_ n: String) -> Bool {
        n.hasSuffix(".md") && !n.contains("/") && !n.contains("\\") && !n.hasPrefix(".") && n.count <= 60
    }
}
