import Foundation

// 从一句话里认出「这次不要检查 / 不要推」的文件夹，用固定规则，不靠小模型猜。
// 比如：「检查云盘代码 除了子目录下的7day文件夹不需要检查」→ ["7day"]
//      「推送，跳过 docs 和 7day」→ ["docs", "7day"]
//      「7day 不用推」→ ["7day"]
// 「除了 X 都不用检查」意思是只检查 X，这种不认（返回空），免得反着做。

enum ExcludeWords {
    private static let neg = "(?:不需要|不用|不要|无需|不必|别|不)"
    private static let act = "(?:检查|推送|推|看|管|对比|提交|上传)"
    private static let end = "(?:$|[，,。.；;！!？?\\n])"

    private static let patterns: [String] = [
        // 除了 X（之外）不需要检查
        "除了(.+?)(?:之外|以外)?(?:的)?(?:文件夹|目录)?" + neg + act,
        // 除了 X（之外），其他都要检查
        "除了(.+?)(?:之外|以外)?[，,\\s]*(?:其他|别的|其余|剩下)的?(?:都|全)",
        // 不用检查 X / 别推 X
        neg + act + "(?:一下)?(.+?)(?:文件夹|目录)?" + end,
        // 跳过 X / 忽略 X / 排除 X
        "(?:跳过|忽略|排除|去掉|绕过)(?:掉)?(.+?)(?:文件夹|目录)?" + end,
        // X 不用检查（X 是空格或标点后面的那一段）
        "([^\\s，,。；;：:]+?)\\s*(?:文件夹|目录)?\\s*(?:就|都|也)?" + neg + act,
    ]

    /// 这些词说的不是文件夹
    private static let notNames: Set<String> = [
        "了", "的", "了吧", "啊", "吗", "呢", "一下", "这个", "那个", "这些", "这次", "代码", "云盘", "仓库", "文件",
        "文件夹", "目录", "子目录", "全部", "所有", "都", "其他", "别的", "我", "你", "它", "直接", "先", "再", "就",
        "检查", "推送", "推", "改动", "github", "GitHub",
    ]

    /// 名字前面这些说法去掉（子目录下的 7day → 7day）
    private static let generic: Set<String> = ["子目录", "目录", "子文件夹", "文件夹", "云盘", "仓库", "项目", "代码", "工作区", "根目录", "里面", "下面"]

    static func parse(_ text: String, taskNames: [String] = []) -> [String] {
        // 「除了 X 都不…」= 只要 X，不当排除
        if text.range(of: "除了.+?(?:之外|以外)?都" + neg, options: .regularExpression) != nil { return [] }
        var out: [String] = []
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let r = m.range(at: 1)
                guard r.location != NSNotFound else { continue }
                for name in split(ns.substring(with: r)) {
                    let n = clean(name)
                    guard !n.isEmpty, !notNames.contains(n), !taskNames.contains(n), !out.contains(n),
                          !n.contains("检查"), !n.contains("推") else { continue }
                    out.append(n)
                }
            }
            if !out.isEmpty { break }
        }
        return out
    }

    private static func split(_ s: String) -> [String] {
        var t = s
        for sep in ["以及", "和", "跟", "及", "、", "，", ",", "还有"] { t = t.replacingOccurrences(of: sep, with: "\u{1}") }
        return t.split(separator: "\u{1}").map(String.init)
    }

    /// 「子目录下的7day文件夹」→「7day」；「src 下的 old」→「src/old」
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "「」“”\"'`《》()（）"))
        for p in ["这次", "这个", "那个", "这些", "一下", "掉", "里的", "里面的", "下面的", "下的"] where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count))
        }
        for s in ["里面的文件", "下面的文件", "下的文件", "里的文件", "的文件", "文件夹", "目录", "里面", "下面", "的"] where t.hasSuffix(s) {
            t = String(t.dropLast(s.count))
        }
        // 「A 下的 B」：A 是泛称就只要 B，不然拼成 A/B
        var parts: [String] = [t]
        for sep in ["下面的", "里面的", "下的", "里的", "中的"] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !generic.contains($0) }
        t = parts.joined(separator: "/")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "「」“”\"'` /"))
        // 太长的多半不是文件夹名，是整句话
        if t.count > 40 || t.contains(" 的 ") { return "" }
        return t
    }
}
