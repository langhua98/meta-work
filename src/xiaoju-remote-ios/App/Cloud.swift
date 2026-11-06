import Foundation

struct CloudError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct CloudItem: Decodable {
    let id: String
    let name: String
    let type: String
    let size: Int64?
    let sha256: String?
    var isFolder: Bool { type == "folder" }
}

/// 小橘云盘 agent 接口（/api/agent/v1，Bearer xa_…）。和 iOS「小橘推送」同一个后端。
struct Cloud {
    let base: String
    let token: String

    private var session: URLSession { .shared }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw CloudError("云盘 \(code)\(msg.map { "：\($0)" } ?? "")")
        }
        return data
    }

    private func cloudGET(_ path: String, query: [String: String] = [:]) async throws -> Data {
        guard var c = URLComponents(string: base + path) else { throw CloudError("云盘地址不对") }
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { throw CloudError("云盘地址不对") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(req)
    }

    func me() async throws -> String {
        let j = try JSONSerialization.jsonObject(with: try await cloudGET("/api/agent/v1/me")) as? [String: Any]
        if let a = j?["agent"] as? [String: Any], let n = a["name"] as? String { return n }
        return "已连接"
    }

    private struct Listing: Decodable { let children: [CloudItem]?; let next_cursor: String? }

    /// 列目录；目录不存在时返回空数组而不是抛错。
    func list(_ path: String) async -> [CloudItem] {
        var out: [CloudItem] = []
        var cursor: String? = nil
        repeat {
            var q = ["path": path, "limit": "1000"]
            if let cursor { q["cursor"] = cursor }
            guard let data = try? await cloudGET("/api/agent/v1/items", query: q),
                  let l = try? JSONDecoder().decode(Listing.self, from: data) else { return out }
            out += l.children ?? []
            cursor = (l.next_cursor?.isEmpty == false) ? l.next_cursor : nil
        } while cursor != nil
        return out
    }

    func download(_ id: String) async throws -> Data {
        try await cloudGET("/api/agent/v1/items/\(id)/content")
    }

    /// 上传（覆盖）。约定 PUT /files?path=/… ，原始字节。
    func upload(_ path: String, _ data: Data, contentType: String = "application/octet-stream") async throws {
        guard var c = URLComponents(string: base + "/files") else { throw CloudError("云盘地址不对") }
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = c.url else { throw CloudError("云盘地址不对") }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        _ = try await send(req)
    }

    func uploadText(_ path: String, _ text: String) async throws {
        try await upload(path, Data(text.utf8), contentType: "application/json; charset=utf-8")
    }
}
