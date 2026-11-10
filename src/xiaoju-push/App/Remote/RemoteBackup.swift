import CryptoKit
import Foundation
import Security

/// 备用通道：云盘（家里电脑）停了，指令和回执改走公共信箱 ntfy.sh，内容加密。
/// 和安卓被控端 xiaoju-remote 的 BackupChannel.kt / BackupCrypto.kt、scripts/遥控/遥控.py 一样算，改了几边一起改。
///
/// 密钥是手机（被控端）随机生成的，云盘正常时存在 `/小橘推送/遥控/<设备名>/备用通道.json`。
/// 这边云盘正常时取一份存钥匙串，云盘停了就用它。没取到过就用不了备用通道。
/// 手机发现云盘连不上以后才开始收备用通道（一般几秒，最多几分钟），ntfy 会把消息留几个小时，所以这边多等一会儿就行。
enum RemoteBackup {
    struct Info: Codable {
        var server: String
        var key: String
        var cmd: String
        var reply: String
    }

    struct BackupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 云盘停了以后，等手机切过来的时间：比平时多等
    static let extraWait: TimeInterval = 300

    static func info(_ dev: String) -> Info? {
        let s = Keychain.read("remoteBackup-\(dev)")
        guard !s.isEmpty else { return nil }
        return try? JSONDecoder().decode(Info.self, from: Data(s.utf8))
    }

    @MainActor private static var refreshed = Set<String>()

    /// 云盘正常时调用：每次打开 App 每台设备取一次密钥（手机换了密钥也能跟上）。
    @MainActor static func refreshOnce(_ dev: String, _ cf: CloudFiles) async {
        guard !refreshed.contains(dev) else { return }
        guard let d = try? await cf.readData("/小橘推送/遥控/\(dev)/备用通道.json"),
              let i = try? JSONDecoder().decode(Info.self, from: d), Data(base64Encoded: i.key)?.count == 32 else { return }
        refreshed.insert(dev)
        Keychain.write("remoteBackup-\(dev)", String(decoding: try! JSONEncoder().encode(i), as: UTF8.self))
    }

    /// 发一条指令（带上发出时间 at，手机会拒绝 15 分钟以前的）。
    static func send(_ info: Info, _ cmd: [String: Any]) async throws {
        guard let key = Data(base64Encoded: info.key), let url = URL(string: "\(info.server)/\(info.cmd)") else {
            throw BackupError(message: "备用通道的密钥不对")
        }
        var c = cmd
        c["at"] = Int(Date().timeIntervalSince1970)
        let plain = try JSONSerialization.data(withJSONObject: c)
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = Data(BackupCrypto.sealText(key, plain).utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw BackupError(message: "备用通道 \(code)") }
    }

    /// 等这条指令的回执。onPending：对方回了「收到了」。到 deadline 还没有返回 nil。
    static func wait(_ info: Info, id: String, since: Date, deadline: Date,
                     onPending: @escaping () -> Void = {}) async -> [String: Any]? {
        guard let key = Data(base64Encoded: info.key) else { return nil }
        let t = Int(since.timeIntervalSince1970) - 5
        while Date() < deadline {
            guard let url = URL(string: "\(info.server)/\(info.reply)/json?since=\(t)") else { return nil }
            // ntfy 大约每 45 秒发一次 keepalive，90 秒没东西就当断了，重连
            let req = URLRequest(url: url, timeoutInterval: 90)
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                for try await line in bytes.lines {
                    if Date() >= deadline || Task.isCancelled { return nil }
                    guard let m = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                          (m["event"] as? String) == "message" else { continue }
                    var plain: Data?
                    if let att = m["attachment"] as? [String: Any], let s = att["url"] as? String, let u = URL(string: s) {
                        if let res = try? await URLSession.shared.data(from: u) { plain = BackupCrypto.open(key, res.0) }
                    } else if let text = m["message"] as? String {
                        plain = BackupCrypto.openText(key, text)
                    }
                    guard let p = plain, let r = (try? JSONSerialization.jsonObject(with: p)) as? [String: Any],
                          (r["id"] as? String) == id else { continue }
                    if (r["pending"] as? Bool) == true { onPending(); continue }
                    return r
                }
            } catch {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        return nil
    }
}

/// 加密：只用 HMAC-SHA256（Python 标准库没有 AES），算法见 xiaoju-remote 的 BackupCrypto.kt。
/// nonce(16) ‖ 明文 XOR 密钥流 ‖ tag(32)；密钥流第 i 块 = HMAC(enc, nonce ‖ i 的 4 字节大端)；tag = HMAC(mac, nonce ‖ 密文)。
enum BackupCrypto {
    static let prefix = "xj1."

    static func hmac(_ key: Data, _ parts: Data...) -> Data {
        var h = HMAC<SHA256>(key: SymmetricKey(data: key))
        for p in parts { h.update(data: p) }
        return Data(h.finalize())
    }

    private static func stream(_ enc: Data, _ nonce: Data, _ data: Data) -> Data {
        var out = Data(count: data.count)
        let src = [UInt8](data)
        var block: UInt32 = 0
        var off = 0
        while off < src.count {
            let ctr = Data([UInt8(block >> 24 & 0xff), UInt8(block >> 16 & 0xff), UInt8(block >> 8 & 0xff), UInt8(block & 0xff)])
            let ks = [UInt8](hmac(enc, nonce, ctr))
            let n = min(32, src.count - off)
            for i in 0..<n { out[off + i] = src[off + i] ^ ks[i] }
            off += n; block += 1
        }
        return out
    }

    static func seal(_ key: Data, _ plain: Data) -> Data {
        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let ct = stream(hmac(key, Data("xj-enc".utf8)), nonce, plain)
        return nonce + ct + hmac(hmac(key, Data("xj-mac".utf8)), nonce, ct)
    }

    static func open(_ key: Data, _ sealed: Data) -> Data? {
        let b = [UInt8](sealed)
        guard b.count >= 48 else { return nil }
        let nonce = Data(b[0..<16]), ct = Data(b[16..<(b.count - 32)]), tag = Data(b[(b.count - 32)...])
        let want = hmac(hmac(key, Data("xj-mac".utf8)), nonce, ct)
        // 定长比较
        guard want.count == tag.count, zip(want, tag).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { return nil }
        return stream(hmac(key, Data("xj-enc".utf8)), nonce, ct)
    }

    static func sealText(_ key: Data, _ plain: Data) -> String { prefix + seal(key, plain).base64EncodedString() }

    static func openText(_ key: Data, _ text: String) -> Data? {
        guard text.hasPrefix(prefix), let raw = Data(base64Encoded: String(text.dropFirst(prefix.count))) else { return nil }
        return open(key, raw)
    }
}
