import Foundation

// 小橘云盘的文件操作（agent 接口）。读用推送的只读令牌就行；改名、移动、删除、写记忆要「整理」令牌。
// 删除永远只是放进回收站。

struct CloudEntry: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let type: String
    let path: String?
    let size: Int64?
    let etag: String?
    var isFolder: Bool { type == "folder" }
    var fullPath: String { path ?? "/" + name }
}

final class CloudFiles {
    private let base: String
    private let readToken: String
    private let writeToken: String

    static let memoryFolder = "/小橘推送/记忆"
    static let memoryIndex = "索引.md"

    init(base: String, readToken: String, writeToken: String) {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        self.base = b
        self.readToken = readToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = writeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.writeToken = w.isEmpty ? self.readToken : w
    }

    var canWrite: Bool { writeToken != readToken }

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                         json: Bool = true, write: Bool = false, headers: [String: String] = [:]) async throws -> Data {
        guard var c = URLComponents(string: base + "/api/agent/v1" + path) else { throw PushError("云盘地址不对") }
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { throw PushError("云盘地址不对") }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = method
        req.setValue("Bearer \(write ? writeToken : readToken)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue(json ? "application/json" : "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        var last: Error?
        for attempt in 0..<3 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) { return data }
                if code >= 500 && attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(3 + attempt * 5) * 1_000_000_000)
                    continue
                }
                throw PushError(Self.explain(code, data, write: write))
            } catch let e as PushError {
                throw e
            } catch {
                last = error
                if attempt < 2 { try await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
        throw PushError("连不上云盘：\(last?.localizedDescription ?? "网络错误")")
    }

    private static func explain(_ code: Int, _ data: Data, write: Bool) -> String {
        var msg = ""
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = j["error"] as? [String: Any] { msg = (e["message"] as? String) ?? "" }
            else if let m = j["message"] as? String { msg = m }
        }
        switch code {
        case 401: return "云盘令牌不对或过期了"
        case 403: return write ? "这个令牌没有改文件的权限，去设置里填「整理令牌」" : "这个令牌看不到这里"
        case 404: return "云盘里没有这个文件或文件夹"
        case 409: return msg.isEmpty ? "有冲突：可能同名的已经存在，或者文件刚被别人改过" : "有冲突：\(msg)"
        case 429: return "今天的次数用完了，明天再试"
        default: return "云盘出错（\(code)）\(msg.isEmpty ? "" : "：" + msg)"
        }
    }

    static func clean(_ p: String) -> String {
        let segs = PushEngine.clean(p)
        return "/" + segs.joined(separator: "/")
    }

    // MARK: 读

    private struct Listing: Decodable { let item: CloudEntry?; let children: [CloudEntry]?; let next_cursor: String? }
    private struct Items: Decodable { let items: [CloudEntry] }

    /// 按路径取一个文件或文件夹；没有返回 nil
    func item(_ path: String) async throws -> CloudEntry? {
        do {
            let d = try await request("GET", "/items", query: ["path": Self.clean(path), "limit": "1"])
            return try JSONDecoder().decode(Listing.self, from: d).item
        } catch let e as PushError where e.message.contains("没有这个") {
            return nil
        }
    }

    func list(_ path: String, limit: Int = 50) async throws -> [CloudEntry] {
        let d = try await request("GET", "/items", query: ["path": Self.clean(path), "limit": "\(limit)"])
        return try JSONDecoder().decode(Listing.self, from: d).children ?? []
    }

    func search(_ keyword: String, in folder: String? = nil, limit: Int = 20) async throws -> [CloudEntry] {
        var q = ["q": keyword, "limit": "\(limit)"]
        if let folder { q["in"] = Self.clean(folder) }
        let d = try await request("GET", "/search", query: q)
        return try JSONDecoder().decode(Items.self, from: d).items
    }

    /// 路径不完全对时按名字找：先原样找，找不到就搜最后一段名字
    func resolve(_ path: String) async throws -> [CloudEntry] {
        if let it = try await item(path) { return [it] }
        let name = PushEngine.clean(path).last ?? path
        let hits = try await search(name, limit: 10)
        let exact = hits.filter { $0.name == name }
        return exact.isEmpty ? Array(hits.prefix(5)) : exact
    }

    func readData(_ path: String) async throws -> Data? {
        guard let it = try await item(path), !it.isFolder else { return nil }
        return try await request("GET", "/items/\(it.id)/content")
    }

    func readText(_ path: String) async throws -> String? {
        guard let it = try await item(path), !it.isFolder else { return nil }
        let d = try await request("GET", "/items/\(it.id)/content")
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: 改（都要整理令牌）

    func mkdir(_ path: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["path": Self.clean(path)])
        _ = try await request("POST", "/folders", body: body, write: true)
    }

    func rename(_ e: CloudEntry, to name: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        _ = try await request("PATCH", "/items/\(e.id)", body: body, write: true,
                              headers: e.etag.map { ["If-Match": $0] } ?? [:])
    }

    func move(_ e: CloudEntry, to folder: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["to": Self.clean(folder)])
        _ = try await request("PATCH", "/items/\(e.id)", body: body, write: true,
                              headers: e.etag.map { ["If-Match": $0] } ?? [:])
    }

    func trash(_ e: CloudEntry) async throws {
        _ = try await request("DELETE", "/items/\(e.id)", write: true, headers: e.etag.map { ["If-Match": $0] } ?? [:])
    }

    /// 上传一个文件（同名不覆盖，云盘会自动加「 (2)」）
    func upload(_ path: String, _ data: Data) async throws {
        _ = try await request("PUT", "/files", query: ["path": Self.clean(path)], body: data, json: false, write: true)
    }

    /// 写一个文本文件（云盘不覆盖同名：先写临时文件，旧的放回收站，再改名）
    func writeText(_ path: String, _ text: String) async throws {
        let p = Self.clean(path)
        let name = PushEngine.clean(p).last ?? "记忆.md"
        let folder = "/" + PushEngine.clean(p).dropLast().joined(separator: "/")
        let tmp = folder + "/.\(name).\(Int(Date().timeIntervalSince1970)).tmp"
        _ = try await request("PUT", "/files", query: ["path": tmp], body: Data(text.utf8), json: false, write: true)
        if let old = try await item(p) { try await trash(old) }
        guard let t = try await item(tmp) else { throw PushError("写记忆失败") }
        try await rename(t, to: name)
    }

    // MARK: 即时信箱（服务端 relay.go：消息只在内存里，长轮询，不走存储端，比写文件快得多）

    /// 服务端还没上即时信箱时会报 404（「没有这个…」），调用方据此退回到文件信箱
    static func relayMissing(_ e: Error) -> Bool { (e as? PushError)?.message.contains("没有这个") == true }

    func relaySend(_ box: String, _ obj: [String: Any]) async throws {
        let body = try JSONSerialization.data(withJSONObject: obj)
        _ = try await request("POST", "/relay", query: ["box": box], body: body, write: true)
    }

    /// 取走信箱里的消息；没有就最多等 seconds 秒（消息一到马上返回）
    func relayWait(_ box: String, seconds: Int = 25) async throws -> [[String: Any]] {
        let d = try await request("GET", "/relay", query: ["box": box, "wait": "\(seconds)"])
        let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        return ((j?["messages"] as? [[String: Any]]) ?? []).compactMap { $0["body"] as? [String: Any] }
    }

    // MARK: 记忆

    func memoryIndex() async -> String {
        (try? await readText(Self.memoryFolder + "/" + Self.memoryIndex)) ?? ""
    }

    func memoryFiles() async throws -> [CloudEntry] {
        guard try await item(Self.memoryFolder) != nil else { return [] }
        return try await list(Self.memoryFolder, limit: 100).filter { !$0.isFolder && $0.name.hasSuffix(".md") }
    }
}
