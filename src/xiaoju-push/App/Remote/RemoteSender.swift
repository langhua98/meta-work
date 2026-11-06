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

        do {
            let data = try JSONSerialization.data(withJSONObject: cmd)
            try await cf.upload("/小橘推送/遥控/\(dev)/收件/\(id).json", data)
        } catch {
            status = "发送失败：\(error.localizedDescription)"
            return
        }
        status = "已发送「\(action)」给 \(dev)，等回执…"

        let receiptPath = "/小橘推送/遥控/\(dev)/回执/\(id).json"
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let d = try? await cf.readData(receiptPath),
                  let r = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            receipt = (r["text"] as? String) ?? ""
            for p in (r["files"] as? [String]) ?? [] {
                let name = (p as NSString).lastPathComponent
                guard let fd = try? await cf.readData(p) else { fileNotes.append("\(name)：下载失败"); continue }
                if let img = UIImage(data: fd) { image = img } else { fileNotes.append("\(name)（\(fd.count / 1024) KB，在云盘 \(p)）") }
            }
            status = (r["ok"] as? Bool) == false ? "对方拒绝了这条指令" : "完成"
            return
        }
        status = "90 秒没收到回执。确认对方开着「待命」，设备名和配对口令跟这里一样。"
    }
}
