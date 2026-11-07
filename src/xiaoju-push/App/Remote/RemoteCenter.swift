import Foundation
import UIKit

// 被控端「待命」：在即时信箱上长轮询（指令一到马上执行），服务端没有即时信箱时退回到轮询云盘里的收件箱文件。
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
        let cf = CloudFiles(base: s.cloudURL.isEmpty ? Store.defaultCloudURL : s.cloudURL,
                            readToken: s.cloudToken, writeToken: s.cloudToken) // 写回执用主令牌（要有写权限），不依赖「整理令牌」
        let dev = device
        let inbox = "/小橘推送/遥控/\(dev)/收件"
        let filesDir = "/小橘推送/遥控/\(dev)/文件"
        var lastError = ""
        var useRelay = true
        var lastFileCheck = Date.distantPast

        while !Task.isCancelled {
            // 快路：即时信箱，长轮询，指令一到马上返回
            if useRelay {
                do {
                    let msgs = try await cf.relayWait(RemoteBox.inbox(dev))
                    lastError = ""
                    for cmd in msgs { await execute(cf, cmd, dev: dev, viaRelay: true, filesDir: filesDir) }
                } catch {
                    if CloudFiles.relayMissing(error) {
                        useRelay = false
                        push("云盘服务端还没有即时信箱，先用文件信箱（会慢一些）")
                    } else {
                        note(error, &lastError)
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
                // 老的发送端（旧版 App、遥控.py）还会写文件信箱，隔一会儿看一眼
                if Date().timeIntervalSince(lastFileCheck) < 30 { continue }
            }
            lastFileCheck = Date()
            do {
                let items = (try await cf.list(inbox, limit: 1000))
                    .filter { !$0.isFolder && $0.name.hasSuffix(".json") }
                    .sorted { $0.name < $1.name }
                for it in items where !isSeen(it.id) {
                    markSeen(it.id)
                    guard let data = try? await cf.readData("\(inbox)/\(it.name)"),
                          let cmd = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                        push("收到一条看不懂的指令，跳过"); continue
                    }
                    var c = cmd
                    if c["id"] == nil { c["id"] = it.name.replacingOccurrences(of: ".json", with: "") }
                    await execute(cf, c, dev: dev, viaRelay: false, filesDir: filesDir)
                }
                if !useRelay { lastError = "" }
            } catch {
                // 收件箱还不存在时 list 会报「没有这个文件夹」，正常，静默
                if !CloudFiles.relayMissing(error) { note(error, &lastError) }
            }
            if !useRelay { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
    }

    /// 别的错（令牌不对、连不上云盘）要显示出来，不然看着在待命其实一直收不到。同一个错只记一次。
    private func note(_ error: Error, _ last: inout String) {
        let msg = error.localizedDescription
        if msg != last { push("收件箱读不了：\(msg)") }
        last = msg
    }

    /// 执行一条指令，回执原路返回：从即时信箱来的回到即时信箱（照片直接放在回执里），从文件来的写回执文件。
    private func execute(_ cf: CloudFiles, _ cmd: [String: Any], dev: String, viaRelay: Bool, filesDir: String) async {
        let s = Store.shared
        let id = (cmd["id"] as? String) ?? UUID().uuidString
        let outbox = "/小橘推送/遥控/\(dev)/回执"

        func reply(_ r: [String: Any]) async {
            do {
                if viaRelay { try await cf.relaySend(RemoteBox.receipt(dev, id), r) }
                else { try await cf.upload("\(outbox)/\(id).json", jsonData(r)) }
            } catch { push("传回执失败：\(error.localizedDescription)") }
        }

        if !s.remotePair.isEmpty, (cmd["pair"] as? String) != s.remotePair {
            push("有一条指令口令不对，拒绝")
            await reply(["id": id, "ok": false, "text": "配对口令不对"])
            return
        }

        let action = cmd["do"] as? String ?? ""
        push("执行：\(action)")
        let result = await RemoteCommands.run(cmd)

        var files: [Any] = []
        for (name, bytes) in result.files {
            if viaRelay && bytes.count <= RemoteBox.inlineLimit {
                files.append(["name": name, "data": bytes.base64EncodedString()])
                continue
            }
            let path = "\(filesDir)/\(id)-\(name)"
            if (try? await cf.upload(path, bytes)) != nil { files.append(path) }
            else { push("传文件失败：\(name)") }
        }

        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
        await reply(["id": id, "do": action, "ok": true,
                     "text": result.text, "files": files, "at": f.string(from: Date())])
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

/// 即时信箱的名字（发送端、被控端、遥控.py 要一致）
enum RemoteBox {
    static func inbox(_ dev: String) -> String { "遥控/\(dev)/收件" }
    static func receipt(_ dev: String, _ id: String) -> String { "遥控/\(dev)/回执/\(id)" }
    /// 实时画面的旧方式（服务端没有直播通道时，即时信箱一帧帧传）
    static func video(_ dev: String) -> String { "遥控/\(dev)/视频" }
    /// 回执里直接带的文件最大多少（base64 后要小于服务端单条 8 MB）
    static let inlineLimit = 5 << 20
}
