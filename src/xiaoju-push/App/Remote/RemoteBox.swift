import Foundation

/// 即时信箱的名字（控制端、被控端 langhua98/xiaoju-remote、遥控.py 要一致）
enum RemoteBox {
    static func inbox(_ dev: String) -> String { "遥控/\(dev)/收件" }
    static func receipt(_ dev: String, _ id: String) -> String { "遥控/\(dev)/回执/\(id)" }
    /// 实时画面的旧方式（服务端没有直播通道时，即时信箱一帧帧传）
    static func video(_ dev: String) -> String { "遥控/\(dev)/视频" }
    /// 回执里直接带的文件最大多少（base64 后要小于服务端单条 8 MB）
    static let inlineLimit = 5 << 20
}
