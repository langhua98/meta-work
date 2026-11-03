import Foundation

// 推送前的风险提醒：像密码 / 令牌的内容、敏感文件名、大文件、一次推太多文件。
struct Risk: Identifiable {
    enum Level { case secret, warn }
    let id = UUID()
    let level: Level
    let title: String
    let detail: String

    private static let patterns: [(String, String)] = [
        ("GitHub 令牌", #"(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}"#),
        ("GitHub 令牌", #"github_pat_[A-Za-z0-9_]{50,}"#),
        ("小橘云盘令牌", #"\bxa_[A-Za-z0-9_\-]{30,}"#),
        ("Hugging Face 令牌", #"\bhf_[A-Za-z0-9]{30,}"#),
        ("API 密钥", #"\bsk-[A-Za-z0-9_\-]{20,}"#),
        ("AWS 密钥", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("私钥", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("密码", #"(?i)(password|passwd|secret|api_?key)\s*[:=]\s*["'][^"'\s]{8,}["']"#),
    ]
    private static let regexes: [(String, NSRegularExpression)] = patterns.compactMap { name, p in
        (try? NSRegularExpression(pattern: p)).map { (name, $0) }
    }
    private static let secretNames: Set<String> = [".env", ".env.local", ".env.production", "id_rsa", "id_ed25519",
                                                   "credentials.json", ".npmrc", ".netrc"]
    private static let secretExts: Set<String> = ["pem", "p12", "pfx", "key", "mobileprovision", "keystore", "jks"]

    static func scan(_ changes: [Change]) -> [Risk] {
        var out: [Risk] = []
        for c in changes {
            let name = (c.repoPath as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            if secretNames.contains(name) || secretExts.contains(ext) {
                out.append(Risk(level: .secret, title: "\(name) 可能是密钥文件", detail: c.repoPath))
            }
            if c.data.count > 10 * 1024 * 1024 {
                let size = ByteCountFormatter.string(fromByteCount: Int64(c.data.count), countStyle: .file)
                out.append(Risk(level: .warn, title: "\(name) 很大（\(size)）", detail: "大文件会让仓库变慢，确认真的要提交"))
            }
            guard c.diff.note == nil || c.isNew, let text = String(data: c.data.prefix(2_000_000), encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for (label, re) in regexes {
                if let m = re.firstMatch(in: text, range: range) {
                    let line = text[..<(Range(m.range, in: text)?.lowerBound ?? text.startIndex)]
                        .reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                    out.append(Risk(level: .secret, title: "\(name) 里像是有\(label)", detail: "\(c.repoPath) 第 \(line) 行"))
                    break
                }
            }
        }
        if changes.count > 50 {
            out.append(Risk(level: .warn, title: "一次要推 \(changes.count) 个文件", detail: "确认没有选错文件夹"))
        }
        return out
    }
}
