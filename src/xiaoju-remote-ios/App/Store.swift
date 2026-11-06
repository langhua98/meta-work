import Foundation
import Security
import UIKit

/// 令牌存钥匙串，其它设置存 UserDefaults。
final class Store: ObservableObject {
    @Published var base: String { didSet { d.set(base, forKey: "base") } }
    @Published var device: String { didSet { d.set(device, forKey: "device") } }
    @Published var pair: String { didSet { Keychain.set("pair", pair) } }
    @Published var token: String { didSet { Keychain.set("token", token) } }

    private let d = UserDefaults.standard

    init() {
        base = d.string(forKey: "base")?.nonEmpty ?? "https://langhua1998-xiaoju-cloud.hf.space"
        device = d.string(forKey: "device")?.nonEmpty ?? UIDeviceName()
        pair = Keychain.get("pair") ?? ""
        token = Keychain.get("token") ?? ""
    }

    // 处理过的指令 id（避免重复执行）
    func markSeen(_ id: String) {
        var s = Set(d.stringArray(forKey: "seen") ?? [])
        s.insert(id)
        d.set(Array(s.suffix(500)), forKey: "seen")
    }
    func isSeen(_ id: String) -> Bool {
        (d.stringArray(forKey: "seen") ?? []).contains(id)
    }
}

private func UIDeviceName() -> String {
    #if canImport(UIKit)
    return UIDevice.current.name
    #else
    return "iPhone"
    #endif
}

extension String { var nonEmpty: String? { isEmpty ? nil : self } }

enum Keychain {
    static func set(_ key: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "xiaoju-remote",
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = value.data(using: .utf8)!
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "xiaoju-remote",
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
