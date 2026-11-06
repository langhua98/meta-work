import Foundation
import UIKit

@MainActor
final class RemoteEngine: ObservableObject {
    @Published var running = false
    @Published var log: [String] = []

    private let store: Store
    private var task: Task<Void, Never>?

    init(store: Store) { self.store = store }

    func start() {
        guard !running else { return }
        guard !store.token.isEmpty else { push("先填云盘令牌"); return }
        running = true
        UIApplication.shared.isIdleTimerDisabled = true   // 待命时屏幕不自动锁
        push("开始待命")
        task = Task { await loop() }
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
        UIApplication.shared.isIdleTimerDisabled = false
        push("已停止")
    }

    private func push(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func loop() async {
        let cloud = Cloud(base: store.base, token: store.token)
        let device = store.device
        let inbox = "/小橘推送/遥控/\(device)/收件"
        let outbox = "/小橘推送/遥控/\(device)/回执"
        let filesDir = "/小橘推送/遥控/\(device)/文件"

        if let name = try? await cloud.me() { push("云盘：\(name)") } else { push("连不上云盘") }

        while !Task.isCancelled {
            let items = await cloud.list(inbox)
                .filter { !$0.isFolder && $0.name.hasSuffix(".json") }
                .sorted { $0.name < $1.name }
            for it in items where !store.isSeen(it.id) {
                await handle(cloud, it, outbox: outbox, filesDir: filesDir)
                store.markSeen(it.id)
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    private func handle(_ cloud: Cloud, _ item: CloudItem, outbox: String, filesDir: String) async {
        guard let data = try? await cloud.download(item.id),
              let cmd = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            push("收到一条看不懂的指令，跳过"); return
        }
        let id = (cmd["id"] as? String) ?? item.name.replacingOccurrences(of: ".json", with: "")

        if !store.pair.isEmpty, (cmd["pair"] as? String) != store.pair {
            push("有一条指令口令不对，拒绝")
            try? await cloud.uploadText("\(outbox)/\(id).json",
                jsonString(["id": id, "ok": false, "text": "配对口令不对"]))
            return
        }

        let action = cmd["do"] as? String ?? ""
        push("执行：\(action)")
        let result = await Commands.run(cmd)

        var filePaths: [String] = []
        for (name, bytes) in result.files {
            let path = "\(filesDir)/\(id)-\(name)"
            let ctype = name.hasSuffix(".jpg") ? "image/jpeg" : "application/octet-stream"
            if (try? await cloud.upload(path, bytes, contentType: ctype)) != nil { filePaths.append(path) }
            else { push("传文件失败：\(name)") }
        }

        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
        let receipt: [String: Any] = ["id": id, "do": action, "ok": true,
                                      "text": result.text, "files": filePaths, "at": f.string(from: Date())]
        try? await cloud.uploadText("\(outbox)/\(id).json", jsonString(receipt))
        push("完成：\(action) — \(result.text.split(separator: "\n").first.map(String.init) ?? "")")
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}
