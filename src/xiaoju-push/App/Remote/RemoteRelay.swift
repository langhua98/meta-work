import Foundation

/// 小橘云盘的即时信箱（/api/agent/v1/relay）：消息在服务端内存里，长轮询，几乎没延迟。
/// 实时画面必须走这个（文件信箱太慢）。信箱名要和安卓被控端、xiaoju-remote 一致。
struct RemoteRelay {
    let base: String
    let token: String

    struct RelayError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }
    /// 服务端还没有即时信箱时是 404 / 405 / 501
    static func missing(_ e: Error) -> Bool { [404, 405, 501].contains((e as? RelayError)?.status ?? 0) }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw RelayError(status: code, message: "云盘 \(code)\(msg.map { "：\($0)" } ?? "")")
        }
        return data
    }

    private func url(_ box: String, wait: Int? = nil) -> URL? {
        guard var c = URLComponents(string: base + "/api/agent/v1/relay") else { return nil }
        var items = [URLQueryItem(name: "box", value: box)]
        if let wait { items.append(URLQueryItem(name: "wait", value: "\(wait)")) }
        c.queryItems = items
        return c.url
    }

    func wait(_ box: String, seconds: Int = 20) async throws -> [[String: Any]] {
        guard let u = url(box, wait: seconds) else { throw RelayError(status: 0, message: "云盘地址不对") }
        var req = URLRequest(url: u, timeoutInterval: TimeInterval(seconds + 20))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let j = (try? JSONSerialization.jsonObject(with: try await send(req))) as? [String: Any]
        return ((j?["messages"] as? [[String: Any]]) ?? []).compactMap { $0["body"] as? [String: Any] }
    }

    func post(_ box: String, _ obj: [String: Any]) async throws {
        guard let u = url(box) else { throw RelayError(status: 0, message: "云盘地址不对") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: obj)
        _ = try await send(req)
    }
}

/// 即时信箱的名字（发送端、被控端、遥控.py 要一致）
enum RemoteBox {
    static func inbox(_ dev: String) -> String { "遥控/\(dev)/收件" }
    static func receipt(_ dev: String, _ id: String) -> String { "遥控/\(dev)/回执/\(id)" }
    /// 实时画面的旧方式（服务端没有直播通道时，即时信箱一帧帧传）
    static func video(_ dev: String) -> String { "遥控/\(dev)/视频" }
    /// 回执里直接带的文件最大多少（base64 后要小于服务端单条 8 MB）
    static let inlineLimit = 5 << 20
}
