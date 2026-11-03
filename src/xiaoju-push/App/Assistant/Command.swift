import Foundation

// 一句话 → 一条指令。先用关键词认，认不出来再问本地模型（输出被语法锁死成下面这些 JSON）。

enum Command: Equatable {
    case check(task: String?)
    case push(task: String?)
    case status
    case history(task: String?)
    case exclude(task: String?, path: String)
    case find(keyword: String, folder: String?)
    case mkdir(path: String)
    case rename(path: String, to: String)
    case move(path: String, to: String)
    case trash(path: String)
    case remember(String)
    case cloud(String)
    case say(String)

    /// 给对话里「听懂了：…」小标签用
    var summary: String {
        switch self {
        case .check(let t): return "检查 \(t ?? "这个任务") 的改动"
        case .push(let t): return "推送 \(t ?? "这个任务")"
        case .status: return "看所有任务有没有改动"
        case .history(let t): return "看 \(t ?? "这个任务") 的推送记录"
        case .exclude(let t, let p): return "\(t ?? "这个任务") 不推 \(p)"
        case .find(let k, let f): return "找文件「\(k)」" + (f.map { "，在 \($0)" } ?? "")
        case .mkdir(let p): return "新建文件夹 \(p)"
        case .rename(let p, let to): return "把 \(p) 改名为 \(to)"
        case .move(let p, let to): return "移动 \(p) → \(to)"
        case .trash(let p): return "把 \(p) 放进回收站"
        case .remember(let s): return "记住：\(s)"
        case .cloud: return "这件事要交给云端大模型"
        case .say: return "要再问你一句"
        }
    }

    /// 最近一条指令的一行摘要（下一句话的上下文，比如「再移回来」）
    var memoryLine: String? {
        switch self {
        case .say, .cloud, .status: return nil
        default: return summary
        }
    }
}

/// 模型看得到的任务：一个短名字 + 云盘文件夹 + 仓库
struct TaskRef {
    let name: String
    let mapping: Mapping

    static func list(_ mappings: [Mapping]) -> [TaskRef] {
        var used: [String: Int] = [:]
        return mappings.map { m in
            var n = m.repo.split(separator: "/").last.map(String.init) ?? m.title
            if n.isEmpty { n = m.title }
            let k = n.lowercased()
            used[k, default: 0] += 1
            if used[k]! > 1 { n += "-\(used[k]!)" }
            return TaskRef(name: n, mapping: m)
        }
    }

    static func find(_ name: String?, in tasks: [TaskRef], current: Mapping?) -> Mapping? {
        guard let raw = name?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return current }
        let n = raw.lowercased().replacingOccurrences(of: " ", with: "")
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }
        if let t = tasks.first(where: { norm($0.name) == n }) { return t.mapping }
        if let t = tasks.first(where: { norm($0.mapping.repo) == n || norm($0.mapping.title) == n }) { return t.mapping }
        if let t = tasks.first(where: { norm($0.name).contains(n) || n.contains(norm($0.name)) }) { return t.mapping }
        return nil
    }
}

enum Interpreter {
    // MARK: 关键词（不用模型，马上出结果）

    static func keyword(_ text: String, tasks: [TaskRef], current: Mapping?) -> Command? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s.count <= 24 else { return nil }
        // 句子里提到的任务名
        let named = tasks.first { s.contains($0.name.lowercased()) }?.name
        let hasTask = named != nil || current != nil
        let negative = ["不推", "别推", "不要推", "排除"].contains { s.contains($0) }
        if negative { return nil }
        if hasTask, ["推送", "推上去", "推一下", "推吧", "push", "提交"].contains(where: { s.contains($0) }) {
            return .push(task: named)
        }
        if hasTask, ["检查", "看看改动", "有什么改动", "改了什么", "有改动吗", "check"].contains(where: { s.contains($0) }) {
            return .check(task: named)
        }
        if ["全部任务", "所有任务", "哪些任务", "待推"].contains(where: { s.contains($0) }) { return .status }
        if hasTask, ["推送记录", "历史", "推过什么"].contains(where: { s.contains($0) }) { return .history(task: named) }
        return nil
    }

    // MARK: 模型

    static func prompt(tasks: [TaskRef], current: Mapping?, memoryIndex: String, last: String?) -> (prefix: String, suffix: (String) -> String) {
        let taskLines = tasks.map { "- \($0.name)：云盘 \($0.mapping.cloudPath) → \($0.mapping.repo)" }.joined(separator: "\n")
        let cur = current.flatMap { c in tasks.first { $0.mapping.id == c.id }?.name }
        var sys = """
        你是「小橘推送」的指令翻译器。把用户的一句话翻译成一条 JSON 指令，只输出 JSON。
        指令：
        {"do":"push","task":任务名} 推送任务到 GitHub
        {"do":"check","task":任务名} 检查任务有什么改动
        {"do":"status"} 看所有任务有没有改动
        {"do":"history","task":任务名} 看推送记录
        {"do":"exclude","task":任务名,"path":"文件夹"} 以后不推某个文件夹
        {"do":"find","keyword":"关键词"} 或加 "folder":"/路径" 在云盘找文件、看文件夹里有什么
        {"do":"mkdir","path":"/路径"} 新建文件夹
        {"do":"rename","path":"/路径","to":"新名字"} 改名
        {"do":"move","path":"/路径","to":"/目标文件夹"} 移动
        {"do":"trash","path":"/路径"} 删除（放进回收站）
        {"do":"remember","text":"要记住的事"} 用户说「记住…」或纠正你
        {"do":"cloud","text":"用户原话"} 复杂的事：批量整理、写代码、总结、解释原因、你不确定路径或指的是什么
        {"do":"say","text":"问题"} 缺信息时反问，比如没说是哪个任务
        任务：
        \(taskLines.isEmpty ? "（还没有任务）" : taskLines)
        """
        if let cur { sys += "\n当前任务：\(cur)" }
        let mem = memoryIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mem.isEmpty { sys += "\n记忆（用户的约定，路径以这里为准）：\n" + String(mem.prefix(1200)) }
        sys += """

        例子：
        把 meta-work 推上去 → {"do":"push","task":"meta-work"}
        找一下发票 → {"do":"find","keyword":"发票"}
        把 /文档/demo 移到归档 → {"do":"move","path":"/文档/demo","to":"/归档"}
        记住发票都放 /文档/发票 → {"do":"remember","text":"发票都放 /文档/发票"}
        帮我把代码文件夹按项目整理 → {"do":"cloud","text":"帮我把代码文件夹按项目整理"}
        """
        let prefix = "<|im_start|>system\n\(sys)<|im_end|>\n"
        let lastLine = last.map { "（上一步：\($0)）\n" } ?? ""
        return (prefix, { text in
            "<|im_start|>user\n\(lastLine)\(text)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        })
    }

    /// GBNF：只允许上面这些 JSON，任务名只能从列表里选
    static func grammar(tasks: [TaskRef]) -> String {
        let names = tasks.map { "\"\\\"" + gbnfEscape(jsonEscape($0.name)) + "\\\"\"" }
        let task = names.isEmpty ? "str" : names.joined(separator: " | ")
        return #"""
        root ::= "{" ws "\"do\":" ws ( push | check | status | history | exclude | find | mkdir | rename | move | trash | remember | cloud | say ) ws "}"
        push ::= "\"push\"," ws "\"task\":" ws task
        check ::= "\"check\"," ws "\"task\":" ws task
        status ::= "\"status\""
        history ::= "\"history\"," ws "\"task\":" ws task
        exclude ::= "\"exclude\"," ws "\"task\":" ws task "," ws "\"path\":" ws str
        find ::= "\"find\"," ws "\"keyword\":" ws str ( "," ws "\"folder\":" ws str )?
        mkdir ::= "\"mkdir\"," ws "\"path\":" ws str
        rename ::= "\"rename\"," ws "\"path\":" ws str "," ws "\"to\":" ws str
        move ::= "\"move\"," ws "\"path\":" ws str "," ws "\"to\":" ws str
        trash ::= "\"trash\"," ws "\"path\":" ws str
        remember ::= "\"remember\"," ws "\"text\":" ws str
        cloud ::= "\"cloud\"," ws "\"text\":" ws str
        say ::= "\"say\"," ws "\"text\":" ws str
        task ::= TASKS
        str ::= "\"" char{1,120} "\""
        char ::= [^"\\\x00-\x1F] | "\\" ["\\/nt]
        ws ::= " "?
        """#.replacingOccurrences(of: "TASKS", with: task)
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func gbnfEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 解析模型（或云端）给的 JSON 指令
    static func parse(_ json: String) -> Command? {
        guard let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"), start < end,
              let data = String(json[start...end]).data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = o["do"] as? String else { return nil }
        func s(_ k: String) -> String? {
            (o[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch d {
        case "push": return .push(task: s("task"))
        case "check": return .check(task: s("task"))
        case "status": return .status
        case "history": return .history(task: s("task"))
        case "exclude": return s("path").map { .exclude(task: s("task"), path: $0) }
        case "find": return s("keyword").map { .find(keyword: $0, folder: s("folder")) }
        case "mkdir": return s("path").map { .mkdir(path: $0) }
        case "rename": if let p = s("path"), let t = s("to") { return .rename(path: p, to: t) }; return nil
        case "move": if let p = s("path"), let t = s("to") { return .move(path: p, to: t) }; return nil
        case "trash": return s("path").map { .trash(path: $0) }
        case "remember": return s("text").map { .remember($0) }
        case "cloud": return s("text").map { .cloud($0) }
        case "say": return s("text").map { .say($0) }
        default: return nil
        }
    }
}
