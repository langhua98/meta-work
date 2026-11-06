import Foundation
import UIKit

// 控制端：给另一台设备发一条指令（先走即时信箱，服务端没有时写云盘收件箱），等它的回执（和照片）。
// 和被控端、安卓版、scripts/遥控/遥控.py 共用同一套云盘信箱。
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

        // 发指令要写云盘。直接用主云盘令牌（需带写权限），不依赖「整理令牌」那个字段，省得填错。
        let cf = CloudFiles(base: s.cloudURL.isEmpty ? Store.defaultCloudURL : s.cloudURL,
                            readToken: s.cloudToken, writeToken: s.cloudToken)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-"
        let id = f.string(from: Date()) + String(UUID().uuidString.prefix(6))

        var cmd: [String: Any] = ["id": id, "do": action]
        if !s.remotePair.isEmpty { cmd["pair"] = s.remotePair }
        if let lens { cmd["lens"] = lens }
        if let seconds { cmd["seconds"] = seconds }
        if let on { cmd["on"] = on }

        let inbox = "/小橘推送/遥控/\(dev)/收件/\(id).json"
        let outbox = "/小橘推送/遥控/\(dev)/回执"

        // 快路：云盘的即时信箱（内存里，长轮询，发了对方马上收到）；服务端还没有时退回到写文件
        var viaRelay = true
        do {
            try await cf.relaySend(RemoteBox.inbox(dev), cmd)
        } catch where CloudFiles.relayMissing(error) {
            viaRelay = false
        } catch {
            log("发送失败：\(error.localizedDescription)"); return
        }
        if !viaRelay {
            do {
                try await cf.upload(inbox, jsonData(cmd))
            } catch {
                log("发送失败：\(error.localizedDescription)"); return
            }
        }
        let sentAt = Date()

        // 等回执（最多 90 秒）
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            var r: [String: Any]?
            if viaRelay {
                let left = max(1, min(25, Int(deadline.timeIntervalSinceNow)))
                r = (try? await cf.relayWait(RemoteBox.receipt(dev, id), seconds: left))?.first
                if r == nil { try? await Task.sleep(nanoseconds: 300_000_000) }
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let items = (try? await cf.list(outbox, limit: 1000)) ?? []
                if let hit = items.first(where: { $0.name == "\(id).json" }),
                   let data = try? await cf.readData("\(outbox)/\(hit.name)") {
                    r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                }
            }
            guard let r else { continue }
            await present(action: action, receipt: r, cf: cf,
                          took: Date().timeIntervalSince(sentAt), viaRelay: viaRelay)
            return
        }
        log("等不到回执。确认对方开着待命、口令和设备名一致。")
    }

    private func present(action: String, receipt: [String: Any], cf: CloudFiles,
                         took: TimeInterval, viaRelay: Bool) async {
        var text = (receipt["text"] as? String) ?? ""
        text += String(format: "\n（%.1f 秒%@）", took, viaRelay ? "" : "，走的文件信箱")
        var image: UIImage?
        // 即时信箱：照片直接放在回执里（{"name","data": base64}）；文件信箱：回执里是云盘路径
        for entry in (receipt["files"] as? [Any]) ?? [] where image == nil {
            if let o = entry as? [String: Any], let b64 = o["data"] as? String, let d = Data(base64Encoded: b64) {
                image = UIImage(data: d)
            } else if let p = entry as? String, let d = try? await cf.readData(p) {
                image = UIImage(data: d)
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
