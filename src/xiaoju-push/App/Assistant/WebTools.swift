import Foundation

// 上网：搜索（自己部署在 HF 上的 SearXNG）和读网页（下载网页，去掉标签只留正文）。
// HF 的机器常被 Google、DuckDuckGo 拦，所以只用试过能出结果的几个引擎。

struct WebResult: Equatable {
    var title: String
    var url: URL
    var snippet: String
}

enum WebTools {
    static let searchBase = "https://langhua1998-douyin-proxy.hf.space/sx/search"
    static let engines = "bing,yahoo,sogou,stackoverflow"

    enum Failure: LocalizedError {
        case bad(String)
        var errorDescription: String? { if case .bad(let s) = self { return s }; return nil }
    }

    /// 搜索，最多 limit 条（同一个网址只留一条）
    static func search(_ q: String, limit: Int = 8) async throws -> [WebResult] {
        var c = URLComponents(string: searchBase)!
        c.queryItems = [.init(name: "q", value: q), .init(name: "format", value: "json"), .init(name: "engines", value: engines)]
        var req = URLRequest(url: c.url!, timeoutInterval: 40)
        req.setValue("XiaojuPush", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.bad("搜索服务没响应（HF 上的 SearXNG 可能在睡觉，过一会儿再试）")
        }
        var seen = Set<String>(), out: [WebResult] = []
        for r in (o["results"] as? [[String: Any]]) ?? [] {
            guard let s = r["url"] as? String, let u = URL(string: s), !seen.contains(s) else { continue }
            seen.insert(s)
            out.append(WebResult(title: clean((r["title"] as? String) ?? s), url: u, snippet: clean((r["content"] as? String) ?? "")))
            if out.count >= limit { break }
        }
        return out
    }

    struct Page { var title: String; var text: String; var url: URL }

    /// 读网页：HTML 去掉脚本、样式和标签，只留文字；JSON、纯文本原样。最多 maxChars 字
    static func fetch(_ raw: String, maxChars: Int = 20_000) async throws -> Page {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw Failure.bad("网址不对：\(raw)")
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        // 有些网站不给不像浏览器的请求返回正文
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        guard let code = http?.statusCode, (200..<400).contains(code) else {
            throw Failure.bad("网页打不开（\(http?.statusCode ?? 0)）")
        }
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let body = decode(data, type: type)
        let final = http?.url ?? url
        if !type.contains("html") && !body.lowercased().contains("<html") {
            return Page(title: final.lastPathComponent, text: String(body.prefix(maxChars)), url: final)
        }
        let title = clean(first(body, #"<title[^>]*>([\s\S]*?)</title>"#) ?? final.host ?? "")
        return Page(title: title, text: String(htmlText(body).prefix(maxChars)), url: final)
    }

    // MARK: 文字处理

    private static func decode(_ d: Data, type: String) -> String {
        if let r = type.range(of: "charset=") {
            let cs = type[r.upperBound...].split(separator: ";").first.map(String.init) ?? ""
            let enc = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(cs as CFString))
            if enc != UInt(kCFStringEncodingInvalidId), let s = String(data: d, encoding: String.Encoding(rawValue: enc)) { return s }
        }
        if let s = String(data: d, encoding: .utf8) { return s }
        // 老的中文网站常是 GBK
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: d, encoding: String.Encoding(rawValue: gb)) ?? String(decoding: d, as: UTF8.self)
    }

    private static func first(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func replace(_ s: String, _ pattern: String, _ with: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    static func htmlText(_ html: String) -> String {
        var s = html
        // 正文多半在 <main> 或 <article> 里，有就只要这一段
        if let m = first(s, #"<main[^>]*>([\s\S]*?)</main>"#) ?? first(s, #"<article[^>]*>([\s\S]*?)</article>"#), m.count > 500 { s = m }
        for tag in ["script", "style", "noscript", "svg", "head", "nav", "footer", "form", "iframe"] {
            s = replace(s, "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", " ")
        }
        s = replace(s, #"<!--[\s\S]*?-->"#, " ")
        // 块级标签换行，代码块保留
        s = replace(s, #"<(br|/p|/div|/li|/h[1-6]|/tr|/pre|/blockquote|/section)[^>]*>"#, "\n")
        s = replace(s, #"<li[^>]*>"#, "\n• ")
        s = replace(s, #"<h[1-6][^>]*>"#, "\n\n")
        s = replace(s, #"<[^>]+>"#, "")
        s = entities(s)
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces) }
            .map { replace($0, " {2,}", " ") }
        var out: [String] = [], blank = false
        for l in lines {
            if l.isEmpty { if !blank && !out.isEmpty { out.append("") }; blank = true } else { out.append(l); blank = false }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func entities(_ s: String) -> String {
        var t = s
        for (k, v) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–",
                       "&hellip;": "…", "&copy;": "©", "&middot;": "·", "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’"] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        // &#20013; &#x4e2d;
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = t as NSString
            var res = "", last = 0
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                res += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                if let n = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(n) { res.append(Character(u)) }
                last = m.range.location + m.range.length
            }
            res += ns.substring(from: last)
            t = res
        }
        return t.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func clean(_ s: String) -> String {
        entities(replace(s, "<[^>]+>", "")).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
