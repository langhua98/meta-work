import AVFoundation
import Foundation

// 实时画面的声音和音画同步。
// 被控端给每帧画面、每包声音都打上它自己的采集时间（单调时钟，毫秒）。这边：
//   1. 对表：offset ≈ 本机到达时间 − 对方采集时间，取最快到的那些包（网络偶尔变慢不算进去）；
//   2. 播放时间 = 采集时间 + offset + 缓冲（300 ms，挡住网络抖动）；
//   3. 声音按播放时间排进播放器（正常时一包接一包无缝播，对不上了才重新对齐），画面到了播放时间才显示。
// 两边用同一条时间线，所以声音和画面是对齐的。

/// 本机单调时钟（毫秒），和 AVAudioTime 的 hostTime 同一个基准，方便告诉播放器「几点播」。
enum LiveClock {
    static func nowMs() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1000 }
    static func hostTime(ms: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: ms / 1000) }
}

/// 两台手机的时间线。
struct LiveTimeline {
    let delay: Double                      // 缓冲，毫秒
    private(set) var offset: Double?

    init(delay: Double) { self.delay = delay }

    mutating func observe(senderMs: Double, arrivedMs: Double) {
        let v = arrivedMs - senderMs
        guard let o = offset else { offset = v; return }
        // 更快到的包：立刻按它对表；更慢的：慢慢跟上（网络整体变慢、两边时钟有一点点漂移时用）
        offset = v < o ? v : o + (v - o) * 0.01
    }

    func playout(_ senderMs: Double) -> Double? { offset.map { senderMs + $0 + delay } }
}

/// 播放对方的声音（μ-law，单声道），按时间线排进播放器。只在主线程用。
final class LiveAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var endMs: Double?   // 已经排进去的声音在本机时钟上播到几点

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    init() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .default)
        try s.setActive(true)
        engine.attach(player)
    }

    private func ensure(rate: Double) -> AVAudioFormat? {
        if let f = format, f.sampleRate == rate { return f }
        if format != nil {
            player.stop()
            engine.stop()
            engine.disconnectNodeOutput(player)
        }
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return nil }
        engine.connect(player, to: engine.mainMixerNode, format: f)
        do { try engine.start() } catch { return nil }
        player.play()
        format = f
        endMs = nil
        return f
    }

    /// 排一包声音；at = 这一包第一个样本应该在本机几点（毫秒）播。
    func schedule(ulaw: Data, rate: Double, at: Double) {
        guard !ulaw.isEmpty, let f = ensure(rate: rate),
              let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(ulaw.count)),
              let out = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(ulaw.count)
        var i = 0
        for b in ulaw { out[i] = LiveUlaw.table[Int(b)]; i += 1 }
        let dur = Double(ulaw.count) / rate * 1000
        let now = LiveClock.nowMs()
        if at + dur < now - 50 { return }  // 早就过了播放时间，丢掉，免得越拖越晚
        if let e = endMs, e > now, abs(e - at) <= 80 {
            player.scheduleBuffer(buf, completionHandler: nil)  // 接着上一包无缝播
            endMs = e + dur
        } else {
            // 第一包，或者断过、对不上了：按时间线重新对齐
            let start = max(at, now + 5)
            player.scheduleBuffer(buf, at: AVAudioTime(hostTime: LiveClock.hostTime(ms: start)), options: [], completionHandler: nil)
            endMs = start + dur
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// G.711 μ-law 解码表（和安卓 Ulaw.kt 对应），输出 -1…1 的浮点。
enum LiveUlaw {
    static let table: [Float] = (0..<256).map { i in
        let u = ~UInt8(i)
        let exponent = Int((u >> 4) & 0x07)
        let sample = (((Int(u & 0x0F) << 3) + 0x84) << exponent) - 0x84
        return Float((u & 0x80) != 0 ? -sample : sample) / 32768
    }
}

extension Data {
    /// 从第 at 个字节起读 8 字节大端整数（被控端的毫秒时间戳）
    func liveTimestamp(at: Int) -> Double {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(self[startIndex + at + k]) }
        return Double(Int64(bitPattern: v))
    }
}
