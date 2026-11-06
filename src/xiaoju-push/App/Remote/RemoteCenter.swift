import Foundation
import UIKit

// 被控端「待命」：轮询云盘收件箱，执行指令，把结果写回回执箱。
// 复用 App 自己的 CloudFiles（读用 cloudToken，写回执/照片用 organizeToken）。
@MainActor
final class RemoteCenter: ObservableObject {
    static let shared = RemoteCenter()

    @Published private(set) var running = false
    @Published private(set) var log: [String] = []

    private var task: Task<Void, Never>?
    private let seenKey = "remoteSeen"

    private init() {}

    var device: String { Store.shared.remoteDevice.isEmpty ? UIDevice.current.name : Store.shared.remoteDevice }

    func start() {
        guard !running else { return }
        let s = Store.shared
        guard !s.cloudToken.isEmpty else { push("先在设置里填小橘云盘令牌"); return }
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        push("开始待命（设备名：\(device)）")
        task = Task { await loop() }
    }

    func stop() {
        guard running else { return }
        running = false
        task?.cancel(); task = nil
        UIApplication.shared.isIdleTimerDisabled = false
        push("已停止")
    }

    private func push(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func loop() async {
        let s = Store.shared
        let cf = CloudFiles(base: s.cloudURL, readToken: s.cloudToken, writeToken: s.cloudToken)
        let dev = device
        let inbox = "/小橘推送/遥控/\(dev)/收件"
        let outbox = "/小橘推送/遥控/\(dev)/回执"
        let filesDir = "/小橘推送/遥控/\(dev)/文件"

        while !Task.isCancelled {
            do {
                let items = (try await cf.list(inbox, limit: 200))
                    .filter { !$0.isFolder && $0.name.hasSuffix(".json") }
                    .sorted { $0.name < $1.name }
                for it in items where !isSeen(it.id) {
                    await handle(cf, it, inbox: inbox, outbox: outbox, filesDir: filesDir)
                    markSeen(it.id)
                }
            } catch {
                // 收件箱还不存在时 list 会报「没有这个文件夹」，正常，静默
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    private func handle(_ cf: CloudFiles, _ item: CloudEntry, inbox: String, outbox: String, filesDir: String) async {
        let s = Store.shared
        guard let data = try? await cf.readData("\(inbox)/\(item.name)"),
              let cmd = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            push("收到一条看不懂的指令，跳过"); return
        }
        let id = (cmd["id"] as? String) ?? item.name.replacingOccurrences(of: ".json", with: "")

        if !s.remotePair.isEmpty, (cmd["pair"] as? String) != s.remotePair {
            push("有一条指令口令不对，拒绝")
            try? await cf.upload("\(outbox)/\(id).json", jsonData(["id": id, "ok": false, "text": "配对口令不对"]))
            return
        }

        let action = cmd["do"] as? String ?? ""
        push("执行：\(action)")
        let result = await RemoteCommands.run(cmd)

        var filePaths: [String] = []
        for (name, bytes) in result.files {
            let path = "\(filesDir)/\(id)-\(name)"
            if (try? await cf.upload(path, bytes)) != nil { filePaths.append(path) }
            else { push("传文件失败：\(name)") }
        }

        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
        let receipt: [String: Any] = ["id": id, "do": action, "ok": true,
                                      "text": result.text, "files": filePaths, "at": f.string(from: Date())]
        try? await cf.upload("\(outbox)/\(id).json", jsonData(receipt))
        push("完成：\(action) — \(result.text.split(separator: "\n").first.map(String.init) ?? "")")
    }

    private func jsonData(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    // MARK: 处理过的指令 id（避免重复执行）

    private func isSeen(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: seenKey) ?? []).contains(id)
    }
    private func markSeen(_ id: String) {
        var s = UserDefaults.standard.stringArray(forKey: seenKey) ?? []
        s.append(id)
        if s.count > 500 { s.removeFirst(s.count - 500) }
        UserDefaults.standard.set(s, forKey: seenKey)
    }
}
