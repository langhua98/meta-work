import Foundation

// 交给 HF 上的 OpenCode（douyin-proxy Space，默认 DeepSeek）。
// Space 对自己带 Authorization 的请求原样转给 OpenCode：Basic 认证，用户名 opencode，密码是 OPENCODE_SERVER_PASSWORD。

/// OpenCode 干活时的一步（跑命令、读文件、搜索…）
struct CloudStep: Equatable {
    let id: String
    var name: String
    var input: String
    var output: String
    var done: Bool
    var failed: Bool

    /// 输出的最后几行（打过码）
    var tail: String {
        let lines = OpenCodeClient.mask(output).split(separator: "\n", omittingEmptySubsequences: false).suffix(6)
        return String(lines.joined(separator: "\n").suffix(500))
    }
}

struct CloudReply {
    var text: String
    var commands: [Command]
    var memory: MemoryUpdate?
    /// 要发给用户看的文件（OpenCode 工作目录里的相对路径）
    var files: [String] = []
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

    /// 发一句话，等 OpenCode 回完。sessionID 传进来就接着用那个会话。
    /// OpenCode 2 的接口都在 /api 下：POST /api/session 建会话，POST /api/session/{id}/prompt 发消息，GET /api/session/{id}/message 读结果。
    /// 快速模式用的模型（opencode.json 里的 small_model），否则用 Space 默认的 deepseek-v4-pro
    static let fastModel = (provider: "deepseek", id: "deepseek-flash")

    func ask(_ prompt: String, sessionID: String?, fast: Bool = true, status: @escaping (String) -> Void,
             steps: @escaping ([CloudStep]) -> Void = { _ in }) async throws -> (reply: String, session: String) {
        var sid = sessionID ?? ""
        if sid.isEmpty {
            status("连接 OpenCode…")
            // 允许读写工作目录外（比如 /tmp），不然它会停下来等一个没人点的批准
            // 不加载技能、不反问用户：这两样最拖时间（技能会先读一大段说明，反问会一直等）
            let body: [String: Any] = ["title": "小橘推送",
                                       "permissions": [["action": "external_directory", "resource": "*", "effect": "allow"],
                                                       ["action": "skill", "resource": "*", "effect": "deny"],
                                                       ["action": "question", "resource": "*", "effect": "deny"]]]
            let s = try await send("POST", "/api/session", body: body, status: status) as? [String: Any]
            sid = (s?["data"] as? [String: Any])?["id"] as? String ?? s?["id"] as? String ?? ""
            if sid.isEmpty { throw PushError("OpenCode 没给会话号") }
        }
        await setModel(sid, fast: fast)
        status("OpenCode 在想…")
        let text = try await promptAndWait(prompt, sid: sid, status: status, steps: steps)
        return (text, sid)
    }

    /// 换模型。接口的模型写法有字符串和对象两种，都试一下；不成就用默认的，不耽误干活
    private func setModel(_ sid: String, fast: Bool) async {
        let m = fast ? Self.fastModel : (provider: "deepseek", id: "deepseek-v4-pro")
        let forms: [Any] = ["\(m.provider)/\(m.id)", ["providerID": m.provider, "id": m.id]]
        for f in forms {
            if (try? await send("POST", "/api/session/\(sid)/model", body: ["model": f], status: { _ in })) != nil { return }
        }
    }

    /// 有等批准的就直接答：工作目录外的读写放行，别的（比如死循环提醒）拒绝，让它换个办法，不干等
    private func answerPermissions(_ sid: String) async {
        guard let page = try? await send("GET", "/api/session/\(sid)/permission", body: nil, status: { _ in }) as? [String: Any],
              let list = page["data"] as? [[String: Any]] else { return }
        for p in list {
            guard let id = p["id"] as? String else { continue }
            let action = p["action"] as? String ?? ""
            let body: [String: Any] = action == "external_directory"
                ? ["decision": "once"]
                : ["decision": "reject", "message": "用户不在线，不能批准。换个办法，或者直接给出结论。"]
            _ = try? await send("POST", "/api/session/\(sid)/permission/\(id)/reply", body: body, status: { _ in })
        }
    }

    /// POST /api/session/{id}/prompt {text}，然后每秒读 /message：
    /// 新出现的工具调用（命令、读文件…）实时交给 steps，跑完（idle 或回答 8 秒不变）返回最后的回答
    private func promptAndWait(_ prompt: String, sid: String, status: @escaping (String) -> Void,
                               steps: @escaping ([CloudStep]) -> Void) async throws -> String {
        let old = try await messages(sid, limit: 200)
        let before = Self.texts(old.filter { ($0["type"] as? String) == "assistant" }).count
        let oldSteps = Set(Self.steps(old).map(\.id))
        _ = try await send("POST", "/api/session/\(sid)/prompt", body: ["text": prompt], status: status)
        let deadline = Date().addingTimeInterval(600)
        var waited = 0
        var last = "", same = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
            status("OpenCode 在干活…（\(waited) 秒）")
            if waited % 3 == 0 { await answerPermissions(sid) }
            let items = try await messages(sid, limit: 60)
            steps(Self.steps(items).filter { !oldSteps.contains($0.id) })
            let idle = (items.last?["type"] as? String) == "idle"
            // 只要最后一条 assistant 消息里的回答文字（工具调用单独显示成卡片）
            let replies = Self.texts(items.filter { ($0["type"] as? String) == "assistant" })
            let reply = replies.count > before ? (replies.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
            same = (!reply.isEmpty && reply == last) ? same + 1 : 0
            last = reply
            if !reply.isEmpty && (idle || same >= 8) { return Self.mask(reply) }
        }
        throw PushError("OpenCode 10 分钟都没做完")
    }

    /// 会话最近的消息，按时间从旧到新
    private func messages(_ sid: String, limit: Int) async throws -> [[String: Any]] {
        let page = try await send("GET", "/api/session/\(sid)/message?order=desc&limit=\(limit)", body: nil, status: { _ in }) as? [String: Any]
        return (page?["data"] as? [[String: Any]] ?? []).reversed()
    }

    /// 从消息里找出工具调用。兼容两种结构：
    /// OpenCode 的 {type:"tool", tool, callID, state:{status,input,output,title}}，
    /// 和分开的 {type:"tool-call", id/toolCallId, name, params} + {type:"tool-result", toolCallId, result}
    static func steps(_ items: [[String: Any]]) -> [CloudStep] {
        var order: [String] = []
        var map: [String: CloudStep] = [:]
        func str(_ v: Any?) -> String? {
            if let s = v as? String { return s }
            if let v, JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) {
                return String(decoding: d, as: UTF8.self)
            }
            return nil
        }
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                let t = (d["type"] as? String ?? "").lowercased()
                if t.contains("tool") && !t.contains("approval") {
                    let state = d["state"] as? [String: Any]
                    let id = (d["callID"] ?? d["toolCallId"] ?? d["callId"] ?? d["id"]) as? String ?? UUID().uuidString
                    var st = map[id] ?? CloudStep(id: id, name: "", input: "", output: "", done: false, failed: false)
                    if let n = (d["tool"] ?? d["name"] ?? d["toolName"]) as? String { st.name = n }
                    if let inp = (state?["input"] ?? d["input"] ?? d["params"] ?? d["args"]) { st.input = Self.inputLine(inp) }
                    if let title = state?["title"] as? String, !title.isEmpty, st.input.isEmpty { st.input = title }
                    if let out = str(state?["output"] ?? d["result"] ?? d["output"] ?? state?["error"]) { st.output = out }
                    let status = (state?["status"] as? String ?? "").lowercased()
                    if t.contains("result") || status == "completed" { st.done = true }
                    if status == "error" || d["isFailure"] as? Bool == true || state?["error"] != nil { st.done = true; st.failed = true }
                    if map[id] == nil { order.append(id) }
                    map[id] = st
                    return
                }
                for (_, x) in d { walk(x) }
            } else if let a = v as? [Any] {
                for x in a { walk(x) }
            }
        }
        for it in items { walk(it) }
        return order.compactMap { map[$0] }
    }

    /// 工具参数挑最能说明在干什么的一项：命令 > 文件路径 > 搜索词 > 第一项
    static func inputLine(_ v: Any) -> String {
        guard let d = v as? [String: Any] else { return mask(String(describing: v)) }
        for k in ["command", "cmd", "filePath", "path", "pattern", "query", "url", "description"] {
            if let s = d[k] as? String, !s.isEmpty { return mask(s) }
        }
        return mask(d.values.compactMap { $0 as? String }.first ?? "")
    }

    /// 令牌、密码打码
    static func mask(_ s: String) -> String {
        let patterns = [#"xa_[A-Za-z0-9_\-]{12,}"#, #"(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#, #"github_pat_[A-Za-z0-9_]{20,}"#,
                        #"hf_[A-Za-z0-9]{20,}"#, #"sk-[A-Za-z0-9_\-]{16,}"#,
                        #"(?i)((password|passwd|secret|token|api_?key)[A-Z_]*\s*[=:]\s*)\S+"#]
        var out = s
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let tmpl = p.hasPrefix("(?i)") ? "$1••••" : "••••"
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: tmpl)
        }
        return out
    }

    /// 每条 assistant 消息的回答文字：只取 type 为 text 的部分，跳过工具调用 / 工具结果 / 思考
    static func texts(_ items: [[String: Any]]) -> [String] {
        func walk(_ v: Any, _ out: inout [String]) {
            if let d = v as? [String: Any] {
                let t = (d["type"] as? String ?? "").lowercased()
                if t.contains("tool") || t.contains("reasoning") || t.contains("file") || t.contains("result") { return }
                if t == "text", let s = d["text"] as? String { out.append(s); return }
                for (k, x) in d where k != "input" && k != "output" && k != "state" && k != "metadata" { walk(x, &out) }
            } else if let a = v as? [Any] {
                for x in a { walk(x, &out) }
            }
        }
        return items.map { var out: [String] = []; walk($0, &out); return out.joined() }.filter { !$0.isEmpty }
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
                       memoryFiles: [(String, String)], recent: [String], today: String, followUp: Bool = false) -> String {
        let taskLines = tasks.map { "- \($0.name)：云盘 \($0.mapping.cloudPath) → \($0.mapping.repo)" }.joined(separator: "\n")
        let files = memoryFiles.map { "### \($0.0)\n\($0.1)" }.joined(separator: "\n\n")
        var p = """
        你是 iPhone 上编码助手「小橘推送」背后的大模型：用户的代码在小橘云盘里，App 负责推到 GitHub。今天是 \(today)。用中文，最后的回答只写结论，几句话就够；要快：能一步做完就别分几步，不要先做计划、头脑风暴或写测试，不要加载技能，不要向用户提问，有不确定就按最可能的意思直接做；不要贴文件内容、命令输出、技能说明，更不要写出任何令牌或密码。
        推送任务：
        \(taskLines.isEmpty ? "（没有）" : taskLines)

        最近做过的事：
        \(recent.isEmpty ? "（没有）" : recent.map { "- " + $0 }.joined(separator: "\n"))

        记忆索引：
        \(memoryIndex.isEmpty ? "（空）" : memoryIndex)

        记忆文件：
        \(followUp ? "（同这个会话前面发过的）" : files.isEmpty ? "（空）" : files)

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
            手机上的小模型没搞定，你来。写代码、改 bug、解释、审查都行。
            要 App 执行的话，最后输出一个 ```json 代码块，是指令数组（只能用这些）：
            {"do":"push","task":任务名} {"do":"check","task":任务名} {"do":"exclude","task":任务名,"path":"文件夹"}
            {"do":"find","keyword":"…"} {"do":"mkdir","path":"/…"} {"do":"rename","path":"/…","to":"新名字"}
            {"do":"move","path":"/…","to":"/目标文件夹"} {"do":"trash","path":"/…"}
            不要自己改云盘或推送：App 会先给用户看、用户确认后由 App 执行。不需要执行就不输出代码块，直接回答。
            要把文件、图片、视频发给用户看（比如你画的图、生成的报告、改好的代码），先保存在工作目录里，
            再在代码块里加 {"do":"show","files":["相对工作目录的路径"]}，App 会下载下来显示在对话里。
            """
        }
        return p
    }

    /// 从回复里拿出说明文字、指令、记忆改动、要显示的文件
    static func parse(_ reply: String) -> CloudReply {
        var text = reply
        var json = ""
        if let r = reply.range(of: "```json", options: .backwards),
           let e = reply.range(of: "```", range: r.upperBound..<reply.endIndex) {
            json = String(reply[r.upperBound..<e.lowerBound])
            text = String(reply[..<r.lowerBound]) + String(reply[e.upperBound...])
        }
        // 没放进代码块、单独一行的 {"do":"show",...} 也认
        var shown: [String] = []
        text = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("{"), l.contains("\"show\""), let d = l.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return true }
            let f = showFiles(o)
            if f.isEmpty { return true }
            shown += f
            return false
        }.joined(separator: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data) else {
            return CloudReply(text: text, commands: [], memory: nil, files: shown)
        }
        if let o = any as? [String: Any], (o["do"] as? String) == "memory" {
            let files = (o["files"] as? [[String: Any]] ?? []).compactMap { f -> (String, String)? in
                guard let n = f["name"] as? String, let c = f["content"] as? String, Self.safeName(n) else { return nil }
                return (n, c)
            }
            let remove = (o["remove"] as? [String] ?? []).filter { Self.safeName($0) && $0 != CloudFiles.memoryIndex }
            let index = o["index"] as? String ?? ""
            return CloudReply(text: text, commands: [], memory: MemoryUpdate(files: files.map { (name: $0.0, content: $0.1) },
                                                                             remove: remove, index: index), files: shown)
        }
        let list = (any as? [[String: Any]]) ?? ((any as? [String: Any]).map { [$0] } ?? [])
        for o in list { shown += showFiles(o) }
        let cmds = list.compactMap { o -> Command? in
            guard let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) else { return nil }
            switch Interpreter.parse(s) {
            case .cloud?, .say?, .remember?, nil: return nil
            case let c?: return c
            }
        }
        var seen = Set<String>()
        return CloudReply(text: text, commands: cmds, memory: nil, files: shown.filter { seen.insert($0).inserted })
    }

    private static func showFiles(_ o: [String: Any]) -> [String] {
        guard (o["do"] as? String) == "show" else { return [] }
        if let f = o["files"] as? [String] { return f.filter { !$0.isEmpty } }
        if let f = (o["file"] ?? o["path"]) as? String, !f.isEmpty { return [f] }
        return []
    }

    // MARK: 下载 OpenCode 工作目录里的文件

    static let maxDownload = 60 * 1024 * 1024

    /// GET /api/fs/read/<路径>，路径相对 OpenCode 的工作目录；给了绝对路径就再试几种去掉前缀的写法
    func download(_ path: String) async throws -> Data {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var tries = [p]
        if p.hasPrefix("/") {
            tries.append(String(p.drop(while: { $0 == "/" })))
            let segs = p.split(separator: "/").map(String.init)
            for name in ["open-code", "workspace", "work", "project"] {
                if let i = segs.firstIndex(of: name), i + 1 < segs.count { tries.append(segs[(i + 1)...].joined(separator: "/")) }
            }
        }
        if p.hasPrefix("./") { tries.append(String(p.dropFirst(2))) }
        var lastCode = 0
        for t in tries {
            let enc = t.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0)
            }.joined(separator: "/")
            guard let url = URL(string: base + "/api/fs/read/" + enc) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 120)
            req.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            let (data, resp) = try await session.data(for: req)
            lastCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(lastCode) {
                if data.count > Self.maxDownload { throw PushError("文件太大（超过 60 MB）") }
                return data
            }
            if lastCode == 401 { throw PushError("OpenCode 密码不对") }
        }
        throw PushError(lastCode == 404 ? "OpenCode 那边找不到 \(p)" : "下载 \(p) 失败（\(lastCode)）")
    }

    /// 记忆文件名只能是一层的 .md，不能带路径
    static func safeName(_ n: String) -> Bool {
        n.hasSuffix(".md") && !n.contains("/") && !n.contains("\\") && !n.hasPrefix(".") && n.count <= 60
    }
}
