import Foundation

// 哪些命令可以直接跑，哪些要先出确认卡片。
// 规则很保守：每一段（| ; && || 分开）都是「只看不改」的命令，并且没有写文件（>），才直接跑；其他都先问。

enum ShellSafety {
    enum Verdict: Equatable {
        case safe
        /// 要确认，附一句为什么
        case confirm(String)
        /// 手机上没有这个命令
        case missing(String)
    }

    /// 只看不改的命令
    static let readOnly: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "egrep", "fgrep", "wc", "find", "pwd", "echo", "diff", "stat", "du",
        "sort", "uniq", "date", "uname", "md5", "sha1", "sha256", "cksum", "sum", "basename", "dirname", "realpath",
        "readlink", "printenv", "env", "whoami", "uptime", "true", "type", "tr", "cd", "awk",
    ]
    /// git 里只看不改的子命令
    static let gitReadOnly: Set<String> = ["status", "diff", "log", "show", "blame", "ls-files", "rev-parse", "describe", "version", "help", "cat-file", "for-each-ref", "ls-remote"]

    static func check(_ command: String) -> Verdict {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if cmd.isEmpty { return .confirm("命令是空的") }
        // 写文件
        if hasRedirect(cmd) { return .confirm("会写文件（>）") }
        for seg in segments(cmd) {
            let words = seg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard var name = words.first else { continue }
            // 去掉前面的 VAR=值
            var rest = Array(words.dropFirst())
            while name.contains("="), let n = rest.first { name = n; rest.removeFirst() }
            if !ShellRunner.commands.isEmpty, !ShellRunner.commands.contains(name) { return .missing(name) }
            switch name {
            case "git", "lg2":
                let sub = rest.first(where: { !$0.hasPrefix("-") }) ?? ""
                if sub == "branch" && rest.filter({ !$0.hasPrefix("-") }).count == 1 { continue }
                if sub == "remote" && (rest.count == 1 || rest.contains("-v")) { continue }
                if !gitReadOnly.contains(sub) {
                    if sub == "push" { return .confirm("会推到 GitHub，推了不好撤回") }
                    if ["reset", "checkout", "clean", "rebase", "merge", "pull", "stash", "rm"].contains(sub) { return .confirm("会改动工作区里的文件") }
                    return .confirm("会改 git 仓库（\(sub.isEmpty ? "git" : "git " + sub)）")
                }
            case "sed":
                if rest.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }) { return .confirm("会直接改文件内容") }
            case "find":
                if rest.contains(where: { ["-delete", "-exec", "-execdir", "-ok"].contains($0) }) { return .confirm("会对找到的文件做操作") }
            case "awk":
                if seg.contains("system(") || seg.contains("print >") { return .confirm("awk 会写文件或跑别的命令") }
            case "rm", "rmdir", "unlink": return .confirm("会删除文件")
            case "mv": return .confirm("会移动或改名文件")
            case "curl":
                let writes = rest.contains { ["-X", "-d", "--data", "-F", "--form", "-T", "--upload-file", "-o", "-O", "--output"].contains($0) || $0.hasPrefix("--data") }
                if writes { return .confirm("会往网上发数据或存文件") }
            default:
                if !readOnly.contains(name) { return .confirm("会改动文件（\(name)）") }
            }
        }
        return .safe
    }

    /// 按 | ; && || 分段（引号里的不算）
    static func segments(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil
        let it = Array(s)
        var i = 0
        while i < it.count {
            let c = it[i]
            if let q = quote { cur.append(c); if c == q { quote = nil }; i += 1; continue }
            if c == "'" || c == "\"" { quote = c; cur.append(c); i += 1; continue }
            if c == "|" || c == ";" || c == "&" {
                out.append(cur); cur = ""
                if i + 1 < it.count, it[i + 1] == c { i += 1 }
                i += 1; continue
            }
            cur.append(c); i += 1
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 引号外有没有 > 或 >>（2>&1 这种把错误并进输出的不算）
    static func hasRedirect(_ s: String) -> Bool {
        var quote: Character? = nil
        let a = Array(s)
        for (i, c) in a.enumerated() {
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "'" || c == "\"" { quote = c; continue }
            if c == ">" {
                let next = i + 1 < a.count ? a[i + 1] : " "
                let prev = i > 0 ? a[i - 1] : " "
                if next == "&" && (prev == "2" || prev == "1") { continue }
                if prev == "2" && s.dropFirst(i + 1).hasPrefix("/dev/null") { continue }
                return true
            }
        }
        return false
    }
}
