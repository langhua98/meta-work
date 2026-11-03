import Foundation

// 粘贴进来的代码（比如 DeepSeek 的回答）→ 一个个文件。
// 认文件名的顺序：代码块第一行 ```swift App/Theme.swift → 代码第一行注释 // Theme.swift → 代码块前一行里的文件名。
// 再去任务的文件里找位置：完整路径 → 路径结尾 → 文件名 → 代码里的类名 / 结构体名。

struct CodeBlock {
    var lang: String
    var hint: String?
    var code: String
}

/// 整理出来的一个文件
struct FileDraft: Identifiable, Equatable {
    let id = UUID()
    var path: String
    var code: String
    var isNew: Bool
    var how: String
    var added = 0
    var removed = 0
}

/// 一次粘贴整理的结果（对话里的卡片）
struct PasteDraft: Equatable {
    var task: Mapping
    var files: [FileDraft]
    var status: String?
}

enum CodePaste {
    /// 像不像一段要整理的代码：有 ``` 代码块，或者很长且多行像代码
    static func looksLikeCode(_ text: String) -> Bool {
        if text.contains("```") { return blocks(text).contains { $0.code.split(separator: "\n").count >= 2 } }
        let lines = text.split(separator: "\n")
        guard lines.count >= 8 else { return false }
        let codey = lines.filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.hasSuffix("{") || t.hasSuffix("}") || t.hasSuffix(";") || t.hasPrefix("import ") || t.hasPrefix("func ")
                || t.hasPrefix("def ") || t.hasPrefix("class ") || t.hasPrefix("struct ") || t.hasPrefix("//") || t.hasPrefix("#include")
        }.count
        return Double(codey) / Double(lines.count) > 0.3
    }

    static func blocks(_ text: String) -> [CodeBlock] {
        let lines = text.components(separatedBy: "\n")
        var out: [CodeBlock] = []
        var i = 0
        var lastProse = ""
        while i < lines.count {
            let l = lines[i]
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                let info = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                let parts = info.split(separator: " ", maxSplits: 1).map(String.init)
                var lang = parts.first ?? ""
                var hint: String? = parts.count > 1 ? parts[1] : nil
                // ```App/Theme.swift 这种只写了路径
                if hint == nil, looksLikePath(lang) { hint = lang; lang = (lang as NSString).pathExtension }
                if hint == nil, let first = body.first, let p = pathInComment(first) { hint = p; body.removeFirst() }
                if hint == nil { hint = pathInProse(lastProse) }
                if let h = hint { hint = cleanPath(h) }
                out.append(CodeBlock(lang: lang, hint: hint, code: body.joined(separator: "\n") + "\n"))
                lastProse = ""
            } else if !t.isEmpty {
                lastProse = t
            }
            i += 1
        }
        // 没有代码块：整段当一个文件
        if out.isEmpty, looksLikeCode(text) {
            var body = lines
            var hint: String?
            if let first = body.first, let p = pathInComment(first) { hint = cleanPath(p); body.removeFirst() }
            out.append(CodeBlock(lang: "", hint: hint, code: body.joined(separator: "\n")))
        }
        return out
    }

    static func looksLikePath(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "`*\"' :："))
        guard !t.isEmpty, !t.contains(" ") else { return false }
        let ext = (t as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 10 && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// 代码第一行的注释里写的文件名：// App/Theme.swift、# main.py、<!-- index.html -->、/* a.css */
    static func pathInComment(_ line: String) -> String? {
        var t = line.trimmingCharacters(in: .whitespaces)
        for p in ["//", "#", "<!--", "/*", "--", ";"] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)); break }
        for s in ["-->", "*/"] where t.hasSuffix(s) { t = String(t.dropLast(s.count)) }
        t = t.trimmingCharacters(in: .whitespaces)
        for p in ["文件：", "文件:", "File:", "file:", "路径：", "路径:", "Path:", "path:"] where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        return looksLikePath(t) ? t : nil
    }

    /// 代码块前一行（比如「### `App/Theme.swift`」「修改 ChatView.swift：」）里的文件名
    static func pathInProse(_ line: String) -> String? {
        let seps = CharacterSet(charactersIn: " `*\"'（）()：:，,。#")
        let words = line.components(separatedBy: seps).filter { !$0.isEmpty }
        return words.last(where: looksLikePath)
    }

    static func cleanPath(_ p: String) -> String {
        var t = p.trimmingCharacters(in: CharacterSet(charactersIn: "`*\"' :："))
        while t.hasPrefix("./") { t.removeFirst(2) }
        return PushEngine.clean(t).joined(separator: "/")
    }

    /// 代码里定义的名字：class / struct / enum / protocol / interface / def / func 后面那个词
    static func definedNames(_ code: String) -> [String] {
        let kw = ["class", "struct", "enum", "protocol", "interface", "actor", "def", "func", "function", "extension"]
        var names: [String] = []
        for line in code.split(separator: "\n").prefix(400) {
            let words = line.split(whereSeparator: { " \t(:<{".contains($0) }).map(String.init)
            for (i, w) in words.enumerated() where kw.contains(w) && i + 1 < words.count {
                let n = words[i + 1].trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                if n.count >= 3, !names.contains(n) { names.append(n) }
            }
        }
        return names
    }

    /// 在任务的文件里给一段代码找位置。返回（路径, 是不是新文件, 怎么找到的）
    static func resolve(_ b: CodeBlock, files: [String], read: (String) -> String?) -> (String, Bool, String)? {
        if let h = b.hint, !h.isEmpty {
            if files.contains(h) { return (h, false, "路径一样") }
            let tail = files.filter { $0.hasSuffix("/" + h) }
            if tail.count == 1 { return (tail[0], false, "按路径找到") }
            let name = (h as NSString).lastPathComponent
            let same = files.filter { ($0 as NSString).lastPathComponent == name }
            if same.count == 1 { return (same[0], false, "按文件名找到") }
            if same.count > 1, let best = same.first(where: { $0.hasSuffix(h) }) { return (best, false, "按文件名找到") }
            return (h, true, h.contains("/") ? "新文件" : "新文件，点路径可以改")
        }
        let names = definedNames(b.code)
        for n in names {
            let byStem = files.filter { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension == n }
            if byStem.count == 1 { return (byStem[0], false, "按里面的 \(n) 找到") }
        }
        // 文件内容里定义了同一个类型
        for n in names.prefix(3) {
            for kw in ["struct \(n)", "class \(n)", "enum \(n)", "def \(n)", "func \(n)", "interface \(n)"] {
                let hits = files.filter { f in read(f)?.contains(kw) ?? false }
                if hits.count == 1 { return (hits[0], false, "按里面的 \(n) 找到") }
            }
        }
        return nil
    }

    /// 文本文件（只在这些里面按内容找）
    static func isText(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["swift", "py", "js", "ts", "tsx", "jsx", "json", "md", "html", "css", "yml", "yaml", "toml", "kt", "java",
                "go", "rs", "c", "h", "cpp", "m", "sh", "txt", "vue", "rb", "php", "sql", "xml", "gradle"].contains(ext)
    }

    /// 复制给 AI 的文字：要求 + 回答格式 + 选中的文件
    static func prompt(repo: String, request: String, files: [(String, String)]) -> String {
        var s = "项目：\(repo)\n"
        s += "要求：\(request.isEmpty ? "（写在这里）" : request)\n\n"
        s += """
        回答格式（很重要，我会用工具自动拆文件）：
        - 每个要新建或修改的文件，给出完整内容，不要只给片段或省略号。
        - 代码块第一行写语言和文件路径，例如：
        ```swift App/Theme.swift
        （完整文件内容）
        ```
        - 路径用下面文件列表里的写法；新文件写清楚放在哪个目录。

        """
        s += "下面是现有文件：\n\n"
        for (p, c) in files {
            let lang = (p as NSString).pathExtension
            s += "```\(lang) \(p)\n\(c)\(c.hasSuffix("\n") ? "" : "\n")```\n\n"
        }
        return s
    }

    /// 按要求里的词先勾上可能相关的文件（文件名或路径里出现的词）
    static func guess(_ request: String, files: [String]) -> Set<String> {
        let words = request.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
        var hit: Set<String> = []
        for f in files {
            let lf = f.lowercased()
            if words.contains(where: { lf.contains($0) }) { hit.insert(f) }
        }
        return hit
    }
}
