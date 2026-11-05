import Foundation

// 一句话 → 一条指令。只有快捷按钮发的那几句原话直接认，其他都交给本地模型（输出被语法锁死成下面这些 JSON）。

enum Command: Equatable {
    /// skip：这次先跳过的文件夹（用户说「除了 7day」之类，由模型填）
    case check(task: String?, skip: [String] = [])
    case push(task: String?, skip: [String] = [])
    case status
    case history(task: String?)
    case exclude(task: String?, path: String)
    case find(keyword: String, folder: String?)
    case mkdir(path: String)
    case rename(path: String, to: String)
    case move(path: String, to: String)
    case trash(path: String)
    case remember(String)
    /// 在手机工作区里跑一条命令（grep、git status…），见 Shell/ShellRunner.swift
    case run(String)
    case cloud(String)
    case say(String)
    /// 本地模型自己回答（关于自己、App 能做什么、简单问题）
    case answer(String)

    /// 给对话里「听懂了：…」小标签用
    var summary: String {
        switch self {
        case .check(let t, let k): return "检查 \(t ?? "这个任务") 的改动" + (k.isEmpty ? "" : "，跳过 " + k.joined(separator: "、"))
        case .push(let t, let k): return "推送 \(t ?? "这个任务")" + (k.isEmpty ? "" : "，跳过 " + k.joined(separator: "、"))
        case .status: return "看所有任务有没有改动"
        case .history(let t): return "看 \(t ?? "这个任务") 的推送记录"
        case .exclude(let t, let p): return "\(t ?? "这个任务") 不推 \(p)"
        case .find(let k, let f):
            if k.isEmpty { return "看看云盘" + (f == nil || f == "/" ? "根目录" : " \(f!)") + "里有什么" }
            return "找文件「\(k)」" + (f.map { "，在 \($0)" } ?? "")
        case .mkdir(let p): return "新建文件夹 \(p)"
        case .rename(let p, let to): return "把 \(p) 改名为 \(to)"
        case .move(let p, let to): return "移动 \(p) → \(to)"
        case .trash(let p): return "把 \(p) 放进回收站"
        case .remember(let s): return "记住：\(s)"
        case .run(let c): return "跑命令 \(c)"
        case .cloud: return "这件事要交给云端大模型"
        case .say: return "要再问你一句"
        case .answer: return "直接回答"
        }
    }

    /// 最近一条指令的一行摘要（下一句话的上下文，比如「再移回来」）
    var memoryLine: String? {
        switch self {
        case .say, .cloud, .status, .answer: return nil
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
        guard let raw = name?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return current ?? (tasks.count == 1 ? tasks[0].mapping : nil)
        }
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
        // 只认快捷按钮发出来的原话（一个字不差），其他都让模型自己理解
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "检查一下有什么改动": return .check(task: nil)
        case "推送": return .push(task: nil)
        case "推送记录": return .history(task: nil)
        case "所有任务": return .status
        default: return nil
        }
    }

    /// 小模型被语法逼着一定要选一条指令，闲聊或问题也会被硬翻成「找文件」「新建文件夹」。
    /// 原话里得有对应的意思才算数，不然当没听懂（交给云端或请用户说具体点）。
    static func plausible(_ c: Command, _ text: String) -> Bool {
        let s = text.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
        func mentions(_ path: String) -> Bool {
            let last = path.split(separator: "/").last.map { String($0).lowercased() } ?? path.lowercased()
            return !last.isEmpty && s.contains(last)
        }
        switch c {
        case .push: return has(["推", "push", "提交", "上传", "发布", "同步"])
        // 只看不改的（检查、记录、列文件、找文件）信模型；会改东西的才核对一下原话
        case .check, .history, .status, .find: return true
        case .exclude: return has(["不推", "别推", "不要推", "排除", "忽略", "跳过", "不用推", "以后", "一直"])
        case .mkdir: return has(["新建", "建", "创建", "加个", "mkdir"])
        case .rename(let p, _): return has(["改名", "重命名", "改成", "叫"]) && mentions(p)
        case .move(let p, _): return has(["移", "挪", "放到", "放进", "搬", "归档", "move"]) && mentions(p)
        case .trash(let p): return has(["删", "回收站", "扔", "清理", "不要了", "去掉"]) && mentions(p)
        case .run: return true  // 会改东西的命令执行前另有确认卡片（ShellSafety）
        case .remember: return has(["记住", "记得", "记一下", "以后", "下次", "别再", "不要再", "错了", "不对", "应该是"])
        case .cloud, .say, .answer: return true
        }
    }

    // MARK: 模型

    static func prompt(tasks: [TaskRef], current: Mapping?, memoryIndex: String, last: String?) -> (prefix: String, suffix: (String) -> String) {
        let taskLines = tasks.map { "- \($0.name)：\($0.mapping.sourceLabel) → \($0.mapping.repo)" }.joined(separator: "\n")
        let cur = current.flatMap { c in tasks.first { $0.mapping.id == c.id }?.name }
        var sys = """
        你是编码助手「小橘推送」里跑在 iPhone 上的本地模型 Qwen3.5-2B（不联网）。App 帮用户管代码：云盘里的代码文件夹推到 GitHub；写代码、改 bug、解释代码这类难事交给云端的 OpenCode（DeepSeek，能跑命令、读写仓库、画图发文件）。
        你能用的工具就是下面这些指令。把用户的一句话变成一条 JSON，只输出 JSON。
        指令：
        {"do":"push","task":任务名} 推送任务到 GitHub；这次要跳过某些文件夹就加 "skip":["文件夹"]
        {"do":"check","task":任务名} 检查任务有什么改动；这次不检查某些文件夹就加 "skip":["文件夹"]
        {"do":"status"} 看所有任务有没有改动
        {"do":"history","task":任务名} 看推送记录
        {"do":"exclude","task":任务名,"path":"文件夹"} 以后一直不推某个文件夹（只有说「以后」「一直」才用）
        {"do":"find","keyword":"关键词"} 或加 "folder":"/路径" 在云盘按名字找文件
        {"do":"list","folder":"/"} 看云盘（"/"）或某个文件夹里有哪些文件夹和文件
        {"do":"mkdir","path":"/路径"} 新建文件夹
        {"do":"rename","path":"/路径","to":"新名字"} 改名
        {"do":"move","path":"/路径","to":"/目标文件夹"} 移动
        {"do":"trash","path":"/路径"} 删除（放进回收站）
        {"do":"remember","text":"要记住的事"} 用户说「记住…」或纠正你
        {"do":"run","cmd":"命令"} 在当前任务的代码文件夹里跑一条命令：grep -rn 搜代码、ls、cat、head、wc、find、sed、git status/diff/log/add/commit。没有 bash/npm/python，复杂的用 sh -c
        {"do":"cloud","text":"用户原话"} 写代码、改 bug、解释代码、代码审查、写提交说明、批量整理，或你不确定路径或指的是什么
        {"do":"say","text":"问题"} 缺信息时反问，比如没说是哪个任务
        {"do":"answer","text":"回答"} 问你是谁、能做什么、有什么工具、怎么用这个 App、打招呼闲聊、简单常识：自己用中文直接回答，两三句
        回答要针对用户这句话，别套用例子。你的工具按连接器分：小橘云盘（找文件、看文件夹、新建/改名/移动文件、放进回收站、读写记忆）；GitHub（检查改动、推送、推送记录、设置不推的文件夹）；本机命令（在手机工作区里跑 grep、git 这些命令）；OpenCode 云端（写代码、改 bug、解释代码、跑命令）。问某个连接器能做什么，只说那一个的，别把别的连接器的工具算进去。用法：直接说一句话，会改东西的都会先出确认卡片。
        只有用户明确要做这件事才用对应指令。跟代码有关的问题、要写东西、你答不准的，用 cloud，不要猜。
        任务：
        \(taskLines.isEmpty ? "（还没有任务）" : taskLines)
        """
        if let cur { sys += "\n当前任务：\(cur)" }
        let mem = memoryIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mem.isEmpty { sys += "\n记忆（用户的约定，路径以这里为准）：\n" + String(mem.prefix(1200)) }
        sys += """

        例子：
        把 meta-work 推上去 → {"do":"push","task":"meta-work"}
        找一下 PushEngine → {"do":"find","keyword":"PushEngine"}
        把 /代码/demo 移到归档 → {"do":"move","path":"/代码/demo","to":"/归档"}
        记住提交说明用中文 → {"do":"remember","text":"提交说明用中文"}
        帮我看看这次改动有没有 bug → {"do":"cloud","text":"帮我看看这次改动有没有 bug"}
        meta-work 这次改了什么 → {"do":"check","task":"meta-work"}
        检查 xiaoju-video，除了 docs 文件夹不用检查 → {"do":"check","task":"xiaoju-video","skip":["docs"]}
        看看云盘里有哪些文件夹 → {"do":"list","folder":"/"}
        代码里哪里用了 cloudToken → {"do":"run","cmd":"grep -rn cloudToken ."}
        工作区里 git 改了哪些 → {"do":"run","cmd":"git status"}
        你是谁 → {"do":"answer","text":"我是小橘推送里的本地模型 Qwen3.5-2B，在你手机上跑，不联网。"}
        早上好 → {"do":"answer","text":"早上好！今天要推哪个项目？"}
        （上一句：把这个函数改成异步）交给云端处理 → {"do":"cloud","text":"把这个函数改成异步"}
        这个项目是干什么的 → {"do":"cloud","text":"这个项目是干什么的"}
        为什么推送失败了 → {"do":"cloud","text":"为什么推送失败了"}
        """
        // 连接器里关掉的工具：说明和例子里都拿掉，模型就不会想到用
        let off = Connectors.disabledKinds
        if !off.isEmpty {
            sys = sys.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                !off.contains { line.contains("{\"do\":\"\($0)\"") }
            }.joined(separator: "\n")
            sys += "\n这些事用户关掉了，做不了，被问到就用 answer 说一声：" + off.compactMap { Connectors.label(for: $0) }.joined(separator: "、")
        }
        let prefix = "<|im_start|>system\n\(sys)<|im_end|>\n"
        let lastLine = last.map { "（\($0)）\n" } ?? ""
        return (prefix, { text in
            "<|im_start|>user\n\(lastLine)\(text)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        })
    }

    /// GBNF：只允许上面这些 JSON，任务名只能从列表里选
    static func grammar(tasks: [TaskRef]) -> String {
        let names = tasks.map { "\"\\\"" + gbnfEscape(jsonEscape($0.name)) + "\\\"\"" }
        let task = names.isEmpty ? "str" : names.joined(separator: " | ")
        let on = Connectors.enabledKinds
        let alts = ["push", "check", "status", "history", "exclude", "find", "list", "mkdir", "rename", "move", "trash", "remember", "run", "cloud", "say", "answer"]
            .filter { on.contains($0) }.joined(separator: " | ")
        return #"""
        root ::= "{" ws "\"do\":" ws ( ALTS ) ws "}"
        push ::= "\"push\"," ws "\"task\":" ws task skip?
        check ::= "\"check\"," ws "\"task\":" ws task skip?
        skip ::= "," ws "\"skip\":" ws "[" ws str ( "," ws str ){0,5} ws "]"
        list ::= "\"list\"," ws "\"folder\":" ws str
        status ::= "\"status\""
        history ::= "\"history\"," ws "\"task\":" ws task
        exclude ::= "\"exclude\"," ws "\"task\":" ws task "," ws "\"path\":" ws str
        find ::= "\"find\"," ws "\"keyword\":" ws str ( "," ws "\"folder\":" ws str )?
        mkdir ::= "\"mkdir\"," ws "\"path\":" ws str
        rename ::= "\"rename\"," ws "\"path\":" ws str "," ws "\"to\":" ws str
        move ::= "\"move\"," ws "\"path\":" ws str "," ws "\"to\":" ws str
        trash ::= "\"trash\"," ws "\"path\":" ws str
        remember ::= "\"remember\"," ws "\"text\":" ws str
        run ::= "\"run\"," ws "\"cmd\":" ws cmd
        cmd ::= "\"" char{1,200} "\""
        cloud ::= "\"cloud\"," ws "\"text\":" ws str
        say ::= "\"say\"," ws "\"text\":" ws str
        answer ::= "\"answer\"," ws "\"text\":" ws long
        long ::= "\"" char{1,160} "\""
        task ::= TASKS
        str ::= "\"" char{1,120} "\""
        char ::= [^"\\\x00-\x1F] | "\\" ["\\/nt]
        ws ::= " "?
        """#.replacingOccurrences(of: "TASKS", with: task).replacingOccurrences(of: "ALTS", with: alts)
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
        func arr(_ k: String) -> [String] {
            ((o[k] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        func s(_ k: String) -> String? {
            (o[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch d {
        case "push": return .push(task: s("task"), skip: arr("skip"))
        case "check": return .check(task: s("task"), skip: arr("skip"))
        case "list": return .find(keyword: "", folder: s("folder") ?? "/")
        case "status": return .status
        case "history": return .history(task: s("task"))
        case "exclude": return s("path").map { .exclude(task: s("task"), path: $0) }
        case "find": return s("keyword").map { .find(keyword: $0, folder: s("folder")) }
        case "mkdir": return s("path").map { .mkdir(path: $0) }
        case "rename": if let p = s("path"), let t = s("to") { return .rename(path: p, to: t) }; return nil
        case "move": if let p = s("path"), let t = s("to") { return .move(path: p, to: t) }; return nil
        case "trash": return s("path").map { .trash(path: $0) }
        case "remember": return s("text").map { .remember($0) }
        case "run": return s("cmd").map { .run($0) }
        case "cloud": return s("text").map { .cloud($0) }
        case "say": return s("text").map { .say($0) }
        case "answer": return s("text").map { .answer($0) }
        default: return nil
        }
    }
}
