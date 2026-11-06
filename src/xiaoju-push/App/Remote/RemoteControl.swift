import Foundation
import UIKit

// 控制端：发一条指令，等对方回执（可带照片）。
// 快路走即时信箱 /relay（内存中转，不写 Telegram，1 秒左右）；服务端不支持时退回文件信箱。
// 信箱名和被控端、安卓版、scripts/遥控.py 保持一致。
@MainActor
final class RemoteControl: ObservableObject {
    static let shared = RemoteControl()

    @Published private(set) var sending = false
    @Published private(set) var replies: [RemoteReply] = []

    private init() {}

    struct RemoteReply: Identifiable {
        let id = UUID()
        let at: String
        let action: String
        let text: String
        var image: UIImage?
    }

    func send(_ action: String, to target: String,
              lens: String? = nil, seconds: Int? = nil, on: Bool? = nil) async {
        let s = Store.shared
        let dev = target.trimmingCharacters(in: .whitespaces)
        guard !dev.isEmpty else { log("先填要控制的设备名"); return }
        guard !s.cloudToken.isEmpty else { log("先在设置里填小橘云盘令牌"); return }

        sending = true
        defer { sending = false }

        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-"
        let id = f.string(from: Date()) + String(UUID().uuidString.prefix(6))
        var cmd: [String: Any] = ["id": id, "do": action]
        if !s.remotePair.isEmpty { cmd["pair"] = s.remotePair }
        if let lens { cmd["lens"] = lens }
        if let seconds { cmd["seconds"] = seconds }
        if let on { cmd["on"] = on }

        // 读内联/云盘路径里的文件都可能要用到云盘客户端
        let cf = CloudFiles(base: s.cloudURL, readToken: s.cloudToken, writeToken: s.cloudToken)

        // 快路：即时信箱
        let relay = RemoteRelay(base: s.cloudURL, token: s.cloudToken)
        do {
            try await relay.post(RemoteBox.inbox(dev), cmd)
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                let msgs = (try? await relay.wait(RemoteBox.receipt(dev, id), seconds: 20)) ?? []
                if let r = msgs.first(where: { ($0["id"] as? String) == id }) ?? msgs.first {
                    await present(action: action, receipt: r, cf: cf)
                    return
                }
            }
            log("等不到回执。确认对方开着待命、口令和设备名一致。")
            return
        } catch {
            guard RemoteRelay.missing(error) else { log("发送失败：\(error.localizedDescription)"); return }
            // 服务端还没有即时信箱 → 退回文件信箱
        }

        await sendViaFiles(cmd: cmd, id: id, dev: dev, action: action, cf: cf)
    }

    // MARK: 文件信箱兜底（老服务端）

    private func sendViaFiles(cmd: [String: Any], id: String, dev: String, action: String, cf: CloudFiles) async {
        let inbox = "/小橘推送/遥控/\(dev)/收件/\(id).json"
        let outbox = "/小橘推送/遥控/\(dev)/回执"
        do { try await cf.upload(inbox, jsonData(cmd)) }
        catch { log("发送失败：\(error.localizedDescription)"); return }

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let items = (try? await cf.list(outbox, limit: 200)) ?? []
            guard let hit = items.first(where: { $0.name == "\(id).json" }) else { continue }
            guard let data = try? await cf.readData("\(outbox)/\(hit.name)"),
                  let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            await present(action: action, receipt: r, cf: cf)
            return
        }
        log("等不到回执。确认对方开着待命、口令和设备名一致。")
    }

    // MARK: 回执 → 显示

    /// files 每项有两种：即时信箱里是 {"name","data"(base64)}，文件信箱里是云盘路径字符串。
    private func present(action: String, receipt: [String: Any], cf: CloudFiles) async {
        let text = (receipt["text"] as? String) ?? ""
        var image: UIImage?
        if let files = receipt["files"] as? [Any], let first = files.first {
            if let inline = first as? [String: Any], let b64 = inline["data"] as? String,
               let data = Data(base64Encoded: b64) {
                image = UIImage(data: data)
            } else if let path = first as? String, let data = try? await cf.readData(path) {
                image = UIImage(data: data)
            }
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        replies.insert(RemoteReply(at: f.string(from: Date()), action: action, text: text, image: image), at: 0)
        if replies.count > 50 { replies.removeLast(replies.count - 50) }
    }

    private func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        replies.insert(RemoteReply(at: f.string(from: Date()), action: "提示", text: s, image: nil), at: 0)
    }

    private func jsonData(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }
}
