import SwiftUI
import UIKit

/// 实时画面查看器。
/// 新：WebSocket 直播通道（/api/agent/v1/stream，服务端只转最新一帧，这边每收一帧回一句 ok，延迟不越拖越长），不限时长，点停止才停。
/// 旧：服务端还没有直播通道（404）时，退回即时信箱一帧帧长轮询（最多 60 秒）。
@MainActor
final class RemoteVideo: ObservableObject {
    @Published private(set) var frame: UIImage?
    @Published private(set) var running = false
    @Published private(set) var note = ""
    @Published private(set) var frames = 0
    @Published private(set) var fps = 0

    @Published var muted = false { didSet { audio?.volume = muted ? 0 : 1 } }

    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var window = (t: Date(), n: 0)
    // 有声音时：声音和画面按同一条时间线播（见 RemoteAV.swift）；没声音时画面一到就显示，延迟最低
    private var withAudio = false
    private var audio: LiveAudio?
    private var timeline = LiveTimeline(delay: 300)
    private var pending: [(at: Double, img: UIImage)] = []
    private var display: Task<Void, Never>?

    func start(target: String, seconds: Int, fps wantFps: Int, width: Int, quality: Int, sound: Bool = false) {
        guard !running else { return }
        let s = Store.shared
        let dev = target.trimmingCharacters(in: .whitespaces)
        guard !dev.isEmpty else { note = "先填设备名"; return }
        guard !s.cloudToken.isEmpty else { note = "先在设置里填云盘令牌"; return }

        running = true; frame = nil; frames = 0; fps = 0; note = "连接直播通道…"
        withAudio = sound; pending = []; timeline = LiveTimeline(delay: 300)
        if sound {
            audio = try? LiveAudio()
            audio?.volume = muted ? 0 : 1
            display = Task { [weak self] in
                while let self, self.running {
                    self.showDue()
                    try? await Task.sleep(nanoseconds: 15_000_000)
                }
            }
        }
        let relay = RemoteRelay(base: s.cloudURL, token: s.cloudToken)
        let id = idString()
        var base: [String: Any] = ["id": id, "do": "video", "lens": "back",
                                   "fps": wantFps, "width": width, "quality": quality,
                                   "av": true, "audio": sound]
        if !s.remotePair.isEmpty { base["pair"] = s.remotePair }
        let firstCmd = base

        task = Task {
            var cmd = firstCmd
            // 每次随机一个房间名，放在指令里，别人猜不到
            let room = "遥控/\(dev)/视频/" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
            guard let ws = openSocket(base: s.cloudURL, token: s.cloudToken, room: room) else {
                note = "云盘地址不对"; running = false; return
            }
            socket = ws
            // 第一条消息是 {"pub":false}；连不上时看是不是服务端还没有直播通道
            do { _ = try await ws.receive() } catch {
                let code = (ws.response as? HTTPURLResponse)?.statusCode ?? 0
                ws.cancel()
                if code == 404 {
                    cmd["seconds"] = 60
                    await relayFallback(relay: relay, dev: dev, cmd: cmd)
                } else {
                    note = "连不上直播通道：\(code > 0 ? "HTTP \(code)" : error.localizedDescription)"
                }
                running = false; return
            }
            cmd["transport"] = "ws"; cmd["room"] = room
            do { try await relay.post(RemoteBox.inbox(dev), cmd) } catch {
                note = "发起失败：\(error.localizedDescription)"; ws.cancel(); running = false; return
            }
            note = "等对方开始推流…"
            // 对方出错（没相机权限、连不上直播通道）会回一条 ok:false 的回执
            Task { [weak self] in
                for _ in 0..<2 {
                    let msgs = (try? await relay.wait(RemoteBox.receipt(dev, id), seconds: 20)) ?? []
                    guard let self, self.running else { return }
                    if let r = msgs.first {
                        if (r["ok"] as? Bool) == false {
                            self.note = (r["text"] as? String) ?? "对方没开始推流"
                            self.stop()
                        }
                        return
                    }
                }
            }
            await receiveLoop(ws)
            if running { note = frames > 0 ? "直播结束" : (note.isEmpty ? "对方没有推流" : note) }
            running = false
        }
    }

    private func openSocket(base: String, token: String, room: String) -> URLSessionWebSocketTask? {
        let wsBase = base.hasPrefix("https") ? "wss" + base.dropFirst(5) : "ws" + base.dropFirst(4)
        guard var c = URLComponents(string: wsBase + "/api/agent/v1/stream") else { return nil }
        c.queryItems = [URLQueryItem(name: "role", value: "sub"), URLQueryItem(name: "ack", value: "1"),
                        URLQueryItem(name: "room", value: room)]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: req)
        ws.maximumMessageSize = 2 << 20
        ws.resume()
        return ws
    }

    /// 收：第 1 字节是类型。1 = 画面（旧）[1][角度/90][JPEG]；3 = 画面带时间戳 [3][角度/90][时间 8 字节][JPEG]；
    /// 2 = 声音 [2][格式][时间 8 字节][μ-law]（格式 1 = 16 kHz，2 = 8 kHz）。
    /// 每收到一帧画面回 ok，服务端才发下一帧；声音不用回。
    private func receiveLoop(_ ws: URLSessionWebSocketTask) async {
        var seenPub = false
        while running {
            guard let msg = try? await ws.receive() else { return }
            let arrived = LiveClock.nowMs()
            switch msg {
            case .data(let d):
                guard d.count > 2 else { continue }
                let kind = d[d.startIndex]
                if kind == 2 {
                    guard withAudio, let audio, d.count > 10 else { continue }
                    let ts = d.liveTimestamp(at: 2)
                    timeline.observe(senderMs: ts, arrivedMs: arrived)
                    guard let at = timeline.playout(ts) else { continue }
                    let rate: Double = d[d.startIndex + 1] == 2 ? 8000 : 16000
                    audio.schedule(ulaw: d.subdata(in: (d.startIndex + 10)..<d.endIndex), rate: rate, at: at)
                    continue
                }
                guard kind == 1 || kind == 3 else { continue }
                let head = kind == 3 ? 10 : 2
                guard d.count > head else { continue }
                var at: Double?
                if kind == 3, withAudio {
                    let ts = d.liveTimestamp(at: 2)
                    timeline.observe(senderMs: ts, arrivedMs: arrived)
                    at = timeline.playout(ts)
                }
                let rot = Int(d[d.startIndex + 1]) * 90
                let jpeg = d.subdata(in: (d.startIndex + head)..<d.endIndex)
                let img = await Task.detached { UIImage(data: jpeg)?.preparingForDisplay() }.value
                try? await ws.send(.string("ok"))
                guard running, let img else { continue }
                let shown = rotated(img, rot)
                if let at {
                    pending.append((at, shown))
                    if pending.count > 30 { pending.removeFirst(pending.count - 30) }
                } else {
                    show(shown)
                }
            case .string(let t):
                if t.contains("\"pub\":true") { seenPub = true; if frames == 0 { note = "对方开始推流了…" } }
                else if t.contains("\"pub\":false"), seenPub { return }   // 推流端断开
            @unknown default:
                continue
            }
        }
    }

    /// 有声音时：把到了播放时间的最新一帧显示出来，更早的扔掉。
    private func showDue() {
        let now = LiveClock.nowMs()
        guard let i = pending.lastIndex(where: { $0.at <= now }) else { return }
        show(pending[i].img)
        pending.removeFirst(i + 1)
    }

    private func show(_ img: UIImage) {
        frame = img
        frames += 1
        note = ""
        window.n += 1
        if Date().timeIntervalSince(window.t) >= 1 { fps = window.n; window = (Date(), 0) }
    }

    /// 旧服务端：即时信箱一帧帧长轮询。
    private func relayFallback(relay: RemoteRelay, dev: String, cmd: [String: Any]) async {
        do { try await relay.post(RemoteBox.inbox(dev), cmd) } catch {
            note = RemoteRelay.missing(error) ? "云盘服务端还不支持实时画面" : "发起失败：\(error.localizedDescription)"
            return
        }
        note = "服务端还没有直播通道，用旧方式（较慢，最多 60 秒）…"
        let end = Date().addingTimeInterval(72)
        while running && Date() < end {
            let msgs = (try? await relay.wait(RemoteBox.video(dev), seconds: 15)) ?? []
            guard running else { break }
            if let last = msgs.last, let b64 = last["jpg"] as? String,
               let data = Data(base64Encoded: b64), let img = UIImage(data: data) {
                frame = rotated(img, (last["rot"] as? Int) ?? 0)
                frames += msgs.count
                window.n += msgs.count
                if Date().timeIntervalSince(window.t) >= 1 { fps = window.n; window = (Date(), 0) }
            }
        }
        if running { note = "直播结束" }
    }

    func stop() {
        running = false
        display?.cancel(); display = nil
        audio?.stop(); audio = nil
        pending = []
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        task?.cancel(); task = nil
    }

    private func idString() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-"
        return f.string(from: Date()) + String(UUID().uuidString.prefix(6))
    }

    /// 按被控端给的角度转正（在 iPhone 上转很便宜，不动那台老手机的 CPU）
    private func rotated(_ img: UIImage, _ rot: Int) -> UIImage {
        guard let cg = img.cgImage else { return img }
        let o: UIImage.Orientation = switch ((rot % 360) + 360) % 360 {
            case 90: .right
            case 180: .down
            case 270: .left
            default: .up
        }
        return UIImage(cgImage: cg, scale: img.scale, orientation: o)
    }
}

struct RemoteVideoView: View {
    let target: String
    @StateObject private var video = RemoteVideo()
    @State private var fps = 10
    @State private var sound = true

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Rectangle().fill(Color.black)
                if let img = video.frame {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        if video.running { ProgressView().tint(.white) }
                        Text(video.note.isEmpty ? "没有画面" : video.note).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .aspectRatio(4.0/3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if video.running {
                HStack {
                    Text("已显示 \(video.frames) 帧 · \(video.fps) 帧/秒").font(.footnote).foregroundStyle(Theme.muted)
                    Spacer()
                    if sound {
                        Button { Haptics.tap(); video.muted.toggle() } label: {
                            Image(systemName: video.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                    }
                }
            } else {
                Stepper("帧率 \(fps) 帧/秒", value: $fps, in: 1...15)
                Toggle("声音（和画面同步，多 0.3 秒缓冲）", isOn: $sound)
            }

            Button {
                Haptics.tap()
                if video.running { video.stop() }
                else { video.start(target: target, seconds: 0, fps: fps, width: 480, quality: 50, sound: sound) }
            } label: {
                Label(video.running ? "停止" : "开始看画面", systemImage: video.running ? "stop.circle" : "play.circle")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .foregroundStyle(video.running ? Theme.redText : Theme.orangeText).fontWeight(.semibold)
            }
            .buttonStyle(.bordered)

            Text("一直播到点「停止」。画面经云盘服务器中转，不写存储。对方那台要开着待命。")
                .font(.caption2).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(16)
        .background(Theme.bg)
        .navigationTitle("实时画面")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { video.stop() }
    }
}
