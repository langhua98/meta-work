import Foundation
import UIKit

// 发送端：从这台 iPhone 给另一台（iPhone 或安卓）发一条遥控指令，等它把回执写回云盘。
// 协议和 scripts/遥控/遥控.py 一样：写 /小橘推送/遥控/<对方设备名>/收件/<id>.json，等 回执/<id>.json。
@MainActor
final class RemoteSender: ObservableObject {
    static let shared = RemoteSender()

    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var receipt = ""
    @Published private(set) var image: UIImage?
    @Published private(set) var fileNotes: [String] = []

    private init() {}

    func send(to target: String, action: String, params: [String: Any] = [:]) async {
        let s = Store.shared
        let dev = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dev.isEmpty else { status = "先填对方的设备名"; return }
        guard !s.cloudToken.isEmpty else { status = "先在连接器里填小橘云盘令牌"; return }
        guard !s.organizeToken.isEmpty else { status = "发指令要往云盘写文件，得在连接器里填「整理令牌」"; return }

        busy = true
        defer { busy = false }
        receipt = ""; image = nil; fileNotes = []

        let cf = CloudFiles(base: s.cloudURL.isEmpty ? Store.defaultCloudURL : s.cloudURL,
                            readToken: s.cloudToken, writeToken: s.organizeToken)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let id = f.string(from: Date()) + "-" + UUID().uuidString.prefix(6).lowercased()
        var cmd = params
        cmd["id"] = id
        cmd["pair"] = s.remotePair
        cmd["do"] = action

        // 快路：即时信箱（服务端没有时退回到文件信箱）
        var viaRelay = true
        do {
            try await cf.relaySend(RemoteBox.inbox(dev), cmd)
        } catch where CloudFiles.relayMissing(error) {
            viaRelay = false
        } catch {
            status = "发送失败：\(error.localizedDescription)"
            return
        }
        if !viaRelay {
            do {
                let data = try JSONSerialization.data(withJSONObject: cmd)
                try await cf.upload("/小橘推送/遥控/\(dev)/收件/\(id).json", data)
            } catch {
                status = "发送失败：\(error.localizedDescription)"
                return
            }
        }
        let sentAt = Date()
        status = "已发送「\(action)」给 \(dev)，等回执…"

        let receiptPath = "/小橘推送/遥控/\(dev)/回执/\(id).json"
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline && !Task.isCancelled {
            var r: [String: Any]?
            if viaRelay {
                let left = max(1, min(25, Int(deadline.timeIntervalSinceNow)))
                r = (try? await cf.relayWait(RemoteBox.receipt(dev, id), seconds: left))?.first
                if r == nil { try? await Task.sleep(nanoseconds: 300_000_000) }
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let d = try? await cf.readData(receiptPath) {
                    r = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                }
            }
            guard let r else { continue }
            receipt = (r["text"] as? String) ?? ""
            for entry in (r["files"] as? [Any]) ?? [] {
                if let o = entry as? [String: Any], let name = o["name"] as? String,
                   let b64 = o["data"] as? String, let fd = Data(base64Encoded: b64) {
                    show(name, fd, cloudPath: nil)
                } else if let p = entry as? String {
                    let name = (p as NSString).lastPathComponent
                    if let fd = try? await cf.readData(p) { show(name, fd, cloudPath: p) }
                    else { fileNotes.append("\(name)：下载失败") }
                }
            }
            let secs = String(format: "%.1f", Date().timeIntervalSince(sentAt))
            status = (r["ok"] as? Bool) == false ? "对方拒绝了这条指令" : "完成（\(secs) 秒\(viaRelay ? "" : "，走的文件信箱"))"
            return
        }
        status = "90 秒没收到回执。确认对方开着「待命」，设备名和配对口令跟这里一样。"
    }

    private func show(_ name: String, _ data: Data, cloudPath path: String?) {
        if let img = UIImage(data: data) { image = img; return }
        // 录音等文件存到 App 的文稿目录，「文件」App 里能找到
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("遥控")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? data.write(to: url)
        fileNotes.append("\(name)（\(data.count / 1024) KB）已存到 文件 App → 小橘推送 → 遥控\(path.map { "；云盘 \($0)" } ?? "")")
    }
}
