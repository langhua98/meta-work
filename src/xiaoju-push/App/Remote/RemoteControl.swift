import Foundation
import UIKit

// 控制端：给另一台设备发指令（先走即时信箱，服务端没有时写云盘收件箱），等它的回执（和照片）。
// 和被控端、安卓版、scripts/遥控/遥控.py 共用同一套云盘信箱。
// 可以一条没回就接着发下一条：每条各等各的。安卓 0.11 收到慢指令会先回一句「收到了」（pending），
// 这边就知道对方收到了、在做，接着等正式的回执；做太久可以取消。
@MainActor
final class RemoteControl: ObservableObject {
    static let shared = RemoteControl()

    @Published private(set) var pending: [PendingCommand] = []
    @Published private(set) var replies: [RemoteReply] = []

    /// 还在等回执的指令
    struct PendingCommand: Identifiable {
        let id: String
        let action: String
        let target: String
        let started: Date
        var received = false   // 对方回了「收到了」
    }

    var sending: Bool { !pending.isEmpty }
    func isPending(_ action: String) -> Bool { pending.contains { $0.action == action } }

    private init() {}

    struct RemoteReply: Identifiable {
        let id = UUID()
        let at: String
        let action: String
        let text: String
        var image: UIImage?
    }

    /// extra：别的字段原样放进指令（比如云台的 action、yaw、pitch）
    func send(_ action: String, to target: String,
              lens: String? = nil, seconds: Int? = nil, on: Bool? = nil, wait: TimeInterval = 90,
              extra: [String: Any] = [:]) async {
        let s = Store.shared
        let dev = target.trimmingCharacters(in: .whitespaces)
        guard !dev.isEmpty else { log("先填要控制的设备名"); return }
        guard !s.cloudToken.isEmpty else { log("先在设置里填小橘云盘令牌"); return }

        // 发指令要写云盘。直接用主云盘令牌（需带写权限），不依赖「整理令牌」那个字段，省得填错。
        let cf = CloudFiles(base: s.cloudURL.isEmpty ? Store.defaultCloudURL : s.cloudURL,
                            readToken: s.cloudToken, writeToken: s.cloudToken)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-"
        let id = f.string(from: Date()) + String(UUID().uuidString.prefix(6))

        var cmd: [String: Any] = ["id": id, "do": action, "ack": true]
        for (k, v) in extra { cmd[k] = v }
        cmd["pair"] = s.remotePair.isEmpty ? "0" : s.remotePair  // 空着就发默认口令 0（法莉娅 0.20 默认口令是 0）
        if let lens { cmd["lens"] = lens }
        if let seconds { cmd["seconds"] = seconds }
        if let on { cmd["on"] = on }

        let inbox = "/小橘推送/遥控/\(dev)/收件/\(id).json"
        let outbox = "/小橘推送/遥控/\(dev)/回执"

        // 快路：云盘的即时信箱（内存里，长轮询，发了对方马上收到）；服务端还没有时退回到写文件。
        // 云盘连不上（家里电脑关机）：改走备用通道（ntfy.sh，加密，见 RemoteBackup）
        var viaRelay = true
        var backup: RemoteBackup.Info?
        do {
            try await cf.relaySend(RemoteBox.inbox(dev), cmd)
            await RemoteBackup.refreshOnce(dev, cf)   // 云盘好着：顺便取一下备用通道的密钥
        } catch where CloudFiles.relayMissing(error) {
            viaRelay = false
        } catch {
            guard let info = RemoteBackup.info(dev) else {
                log("发送失败：\(error.localizedDescription)。备用通道还没准备好：云盘正常时给这台设备发过一次指令，才会取到备用通道的密钥。")
                return
            }
            do {
                try await RemoteBackup.send(info, cmd)
                backup = info
                log("云盘连不上（\(error.localizedDescription)），改走备用通道，手机切过来可能要等一会儿")
            } catch {
                log("发送失败：云盘和备用通道都连不上（\(error.localizedDescription)）"); return
            }
        }
        if !viaRelay {
            do {
                try await cf.upload(inbox, jsonData(cmd))
            } catch {
                log("发送失败：\(error.localizedDescription)"); return
            }
        }
        let sentAt = Date()
        pending.append(PendingCommand(id: id, action: action, target: dev, started: sentAt))
        defer { pending.removeAll { $0.id == id } }

        if let info = backup {
            // 备用通道：手机发现云盘停了才开始收，多等一会儿
            let r = await RemoteBackup.wait(info, id: id, since: sentAt,
                                            deadline: Date().addingTimeInterval(wait + RemoteBackup.extraWait)) { [weak self] in
                Task { @MainActor in
                    if let self, let i = self.pending.firstIndex(where: { $0.id == id }) { self.pending[i].received = true }
                }
            }
            guard pending.contains(where: { $0.id == id }) else { return }   // 被取消了
            if let r {
                await present(action: action, receipt: r, cf: cf, took: Date().timeIntervalSince(sentAt), via: "，走的备用通道")
            } else {
                log("\(label(action))：备用通道等不到回执。手机可能没开待命、没联网，或者还没升级到 0.31。")
            }
            return
        }

        // 等回执（一般最多 90 秒；模型测速要一分多钟）。对方说「收到了」以后再多等一会儿
        var deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            guard pending.contains(where: { $0.id == id }) else { return }   // 被取消了
            var got: [[String: Any]] = []
            if viaRelay {
                let left = max(1, min(25, Int(deadline.timeIntervalSinceNow)))
                got = (try? await cf.relayWait(RemoteBox.receipt(dev, id), seconds: left)) ?? []
                if got.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let items = (try? await cf.list(outbox, limit: 1000)) ?? []
                if let hit = items.first(where: { $0.name == "\(id).json" }),
                   let data = try? await cf.readData("\(outbox)/\(hit.name)"),
                   let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    got = [r]
                }
            }
            if let r = got.first(where: { ($0["pending"] as? Bool) != true }) {
                await present(action: action, receipt: r, cf: cf,
                              took: Date().timeIntervalSince(sentAt), via: viaRelay ? "" : "，走的文件信箱")
                return
            }
            if !got.isEmpty, let i = pending.firstIndex(where: { $0.id == id }), !pending[i].received {
                pending[i].received = true
                deadline = max(deadline, Date().addingTimeInterval(max(wait, 120)))
            }
        }
        log("\(label(action))：等不到回执。确认对方开着待命、口令和设备名一致。")
    }

    /// 不等这条了；对方是安卓 0.11+ 的话，那边也停下来（测速、录音之类）。
    func cancel(_ p: PendingCommand) async {
        pending.removeAll { $0.id == p.id }
        log("\(label(p.action))：已取消")
        let s = Store.shared
        let cf = CloudFiles(base: s.cloudURL.isEmpty ? Store.defaultCloudURL : s.cloudURL,
                            readToken: s.cloudToken, writeToken: s.cloudToken)
        var cmd: [String: Any] = ["id": "cancel-" + String(UUID().uuidString.prefix(8)), "do": "cancel", "target": p.id]
        cmd["pair"] = s.remotePair.isEmpty ? "0" : s.remotePair  // 空着就发默认口令 0（法莉娅 0.20 默认口令是 0）
        do { try await cf.relaySend(RemoteBox.inbox(p.target), cmd) } catch {
            if let info = RemoteBackup.info(p.target) { try? await RemoteBackup.send(info, cmd) }
        }
    }

    func label(_ action: String) -> String {
        ["photo": "拍照", "audio": "录音", "location": "定位", "torch": "手电筒", "ring": "响铃",
         "info": "设备信息", "bench": "模型测速", "vibrate": "震动", "gimbal": "云台", "update": "更新"][action] ?? action
    }

    private func present(action: String, receipt: [String: Any], cf: CloudFiles,
                         took: TimeInterval, via: String) async {
        var text = (receipt["text"] as? String) ?? ""
        text += String(format: "\n（%.1f 秒%@）", took, via)
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
