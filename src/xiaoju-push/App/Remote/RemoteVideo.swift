import SwiftUI
import UIKit

/// 实时画面查看器。
/// 新：WebSocket 直播通道（/api/agent/v1/stream），不限时长，点停止才停。这边每收到一帧马上回一句 ok，
/// 服务端最多让 8 帧在路上（延迟不越拖越长，离得远帧率也上得去）。
/// 服务端支持时要被控端用硬件 H.264 编码（数据量只有 JPEG 的几分之一），这边用硬件解码；「兼容模式」或旧服务端用 JPEG。
/// 旧：服务端还没有直播通道（404）时，退回即时信箱一帧帧长轮询（最多 60 秒）。
@MainActor
final class RemoteVideo: ObservableObject {
    @Published private(set) var frame: UIImage?
    @Published private(set) var running = false
    @Published private(set) var note = ""
    @Published private(set) var frames = 0
    @Published private(set) var fps = 0

    @Published var muted = false { didSet { audio?.volume = muted ? 0 : 1 } }
    @Published private(set) var tip = ""   // 调参数后对方回的话
    @Published private(set) var codec = ""     // 正在收的画面：H.264 / JPEG
    @Published private(set) var kbps = 0
    @Published private(set) var bufferMs = 0   // 有声音时的缓冲
    @Published private(set) var serverH264 = false
    @Published private(set) var askedH264 = false
    @Published private(set) var route = ""     // 经服务器 / Wi-Fi 直连

    private var target = ""

    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var window = (t: Date(), n: 0)
    // 有声音时：声音和画面按同一条时间线播（见 RemoteAV.swift）；没声音时画面一到就显示，延迟最低
    private var withAudio = false
    private var audio: LiveAudio?
    private var timeline = LiveTimeline(delay: 200)
    private var pending: [(at: Double, img: UIImage)] = []
    private var display: Task<Void, Never>?
    private var decoder = LiveH264Decoder()
    private var bytes = (t: Date(), n: 0)
    private var room = ""
    private static let direct = "Wi-Fi 直连"
    private static let viaServer = "经服务器"

    func start(target: String, seconds: Int, fps wantFps: Int, width: Int, quality: Int, sound: Bool = false,
               lens: String = "back", compat: Bool = false, flip: Bool = false, stamp: Bool = true) {
        guard !running else { return }
        let s = Store.shared
        let dev = target.trimmingCharacters(in: .whitespaces)
        guard !dev.isEmpty else { note = "先填设备名"; return }
        guard !s.cloudToken.isEmpty else { note = "先在设置里填云盘令牌"; return }

        running = true; frame = nil; frames = 0; fps = 0; note = "连接直播通道…"
        withAudio = sound; pending = []; timeline = LiveTimeline(delay: 200); tip = ""
        codec = ""; kbps = 0; bufferMs = 0; serverH264 = false; askedH264 = false; route = ""
        decoder = LiveH264Decoder(); bytes = (Date(), 0)
        self.target = dev
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
        var base: [String: Any] = ["id": id, "do": "video", "lens": lens,
                                   "fps": wantFps, "width": width, "quality": quality,
                                   "av": true, "audio": sound,
                                   // 上下翻转、日期时间戳（安卓 0.17+，那边会记住，侦测录像也照这个来）
                                   "flip": flip, "stamp": stamp]
        if !s.remotePair.isEmpty { base["pair"] = s.remotePair }
        let firstCmd = base

        task = Task {
            var cmd = firstCmd
            // 每次随机一个房间名，放在指令里，别人猜不到
            let room = "遥控/\(dev)/视频/" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
            self.room = room
            guard let ws = openSocket(base: s.cloudURL, token: s.cloudToken, room: room) else {
                note = "云盘地址不对"; running = false; return
            }
            socket = ws
            // 第一条消息是 {"pub":false}（新服务端还带 "h264":true）；连不上时看是不是服务端还没有直播通道
            let hello: URLSessionWebSocketTask.Message
            do { hello = try await ws.receive() } catch {
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
            if case .string(let t) = hello, t.contains("\"h264\":true") { serverH264 = true }
            route = Self.viaServer
            askedH264 = serverH264 && !compat
            cmd["codec"] = askedH264 ? "h264" : "jpeg"
            cmd["transport"] = "ws"; cmd["room"] = room
            do { try await relay.post(RemoteBox.inbox(dev), cmd) } catch {
                note = "发起失败：\(error.localizedDescription)"; ws.cancel(); running = false; return
            }
            note = "等对方开始推流…"
            // 对方出错（没相机权限、连不上直播通道）会回一条 ok:false 的回执；
            // 成功的回执里有 lan（对方在局域网里的地址）：同一个 Wi-Fi 就直接连过去，不绕服务器
            Task { [weak self] in
                for _ in 0..<2 {
                    let msgs = (try? await relay.wait(RemoteBox.receipt(dev, id), seconds: 20)) ?? []
                    guard let self, self.running else { return }
                    if let r = msgs.first {
                        if (r["ok"] as? Bool) == false {
                            self.note = (r["text"] as? String) ?? "对方没开始推流"
                            self.stop()
                        } else if let lan = r["lan"] as? [String], !lan.isEmpty {
                            await self.tryDirect(lan)
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
                        URLQueryItem(name: "window", value: "8"), URLQueryItem(name: "room", value: room)]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: req)
        ws.maximumMessageSize = 2 << 20
        ws.resume()
        return ws
    }

    /// 收：第 1 字节是类型。1 = 画面（旧）[1][角度/90][JPEG]；3 = 画面带时间戳 [3][角度/90][时间 8 字节][JPEG]；
    /// 4 = H.264 [4][角度/90][时间 8 字节][标志][Annex-B]；2 = 声音 [2][格式][时间 8 字节][μ-law]（格式 1 = 16 kHz，2 = 8 kHz）。
    /// 每收到一帧画面马上回 ok（不等解码），服务端才接着发；声音不用回。
    private func receiveLoop(_ first: URLSessionWebSocketTask) async {
        var ws = first
        var seenPub = false
        while running {
            let msg: URLSessionWebSocketTask.Message
            do { msg = try await ws.receive() } catch {
                guard running else { return }
                // 换了连接（切到 Wi-Fi 直连了）：接着收新的
                if let s = socket, s !== ws { ws = s; continue }
                // 直连断了（离开了 Wi-Fi）：换回服务器
                if route == Self.direct, let back = await backToServer() { ws = back; continue }
                return
            }
            let arrived = LiveClock.nowMs()
            switch msg {
            case .data(let d):
                guard d.count > 2 else { continue }
                count(d.count)
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
                guard kind == 1 || kind == 3 || kind == 4 else { continue }
                ws.send(.string("ok")) { _ in }
                let head = kind == 4 ? 11 : (kind == 3 ? 10 : 2)
                guard d.count > head else { continue }
                var at: Double?
                if kind != 1, withAudio {
                    let ts = d.liveTimestamp(at: 2)
                    timeline.observe(senderMs: ts, arrivedMs: arrived)
                    at = timeline.playout(ts)
                }
                let rot = Int(d[d.startIndex + 1]) * 90
                let payload = d.subdata(in: (d.startIndex + head)..<d.endIndex)
                let img: UIImage?
                if kind == 4 {
                    if codec != "H.264" { codec = "H.264" }
                    let dec = decoder   // 按顺序一帧帧解（H.264 后面的帧要靠前面的）
                    img = await Task.detached { dec.decode(payload).map { UIImage(cgImage: $0) } }.value
                } else {
                    if codec != "JPEG" { codec = "JPEG" }
                    img = await Task.detached { UIImage(data: payload)?.preparingForDisplay() }.value
                }
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

    /// 同一个 Wi-Fi：直接连对方手机（ws://局域网地址），连上了就把经服务器的那条关掉。
    private func tryDirect(_ addrs: [String]) async {
        for a in addrs {
            guard var c = URLComponents(string: "ws://\(a)/stream") else { continue }
            c.queryItems = [URLQueryItem(name: "room", value: room), URLQueryItem(name: "ack", value: "1"),
                            URLQueryItem(name: "window", value: "8")]
            guard let url = c.url else { continue }
            let ws = URLSession.shared.webSocketTask(with: url)
            ws.maximumMessageSize = 2 << 20
            ws.resume()
            guard running, case .string(let t)? = await firstMessage(ws, timeout: 2.5), t.contains("\"pub\":true") else {
                ws.cancel(); continue
            }
            let old = socket
            socket = ws
            route = Self.direct
            decoder = LiveH264Decoder()   // 直连从关键帧重新开始
            old?.cancel(with: .goingAway, reason: nil)
            return
        }
    }

    /// 直连断了：用同一个房间重新连服务器（对方还连着服务器）。
    private func backToServer() async -> URLSessionWebSocketTask? {
        let s = Store.shared
        guard let ws = openSocket(base: s.cloudURL, token: s.cloudToken, room: room),
              await firstMessage(ws, timeout: 8) != nil, running else { return nil }
        socket = ws
        route = Self.viaServer
        decoder = LiveH264Decoder()
        return ws
    }

    /// 等第一条消息，超时返回 nil（超时会断开这条连接）。
    private func firstMessage(_ ws: URLSessionWebSocketTask, timeout: Double) async -> URLSessionWebSocketTask.Message? {
        // 注意：收到消息后会取消这个计时器，被取消时 sleep 会提前返回，这时绝不能断开连接
        // （以前就是这里把刚连上的 Wi-Fi 直连和换回的服务器连接都断掉了，直播一帧都收不到）
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { ws.cancel() }
        }
        defer { timer.cancel() }
        return try? await ws.receive()
    }

    /// 网速：每秒算一次收到多少 kbps。
    private func count(_ n: Int) {
        bytes.n += n
        let dt = Date().timeIntervalSince(bytes.t)
        guard dt >= 1 else { return }
        kbps = Int(Double(bytes.n) * 8 / dt / 1000)
        bufferMs = withAudio ? Int(timeline.delay) : 0
        bytes = (Date(), 0)
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

    /// 直播中调参数（lens / width / quality / fps / exposure / zoom / torch），对方回的话放进 tip。
    func adjust(_ changes: [String: Any]) {
        guard running, !target.isEmpty else { return }
        if changes["codec"] != nil {
            guard serverH264 else { tip = "云盘服务端还不能转 H.264，只能用 JPEG"; return }
            askedH264 = (changes["codec"] as? String) == "h264"
        }
        let s = Store.shared
        let relay = RemoteRelay(base: s.cloudURL, token: s.cloudToken)
        let dev = target
        let id = idString()
        var cmd = changes
        cmd["id"] = id; cmd["do"] = "video_set"
        if !s.remotePair.isEmpty { cmd["pair"] = s.remotePair }
        let send = cmd
        tip = "调整中…"
        Task {
            do { try await relay.post(RemoteBox.inbox(dev), send) } catch { tip = "没发出去：\(error.localizedDescription)"; return }
            let r = (try? await relay.wait(RemoteBox.receipt(dev, id), seconds: 15))?.first
            tip = (r?["text"] as? String) ?? "对方没回话"
        }
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
    @State private var lens = "back"
    @State private var width = 480
    @State private var quality = 50.0
    @State private var exposure = 0.0
    @State private var zoom = 0.0
    @State private var torch = false
    @AppStorage("remoteVideoCompat") private var compat = false
    @AppStorage("remoteVideoFlip") private var flip = false
    @AppStorage("remoteVideoStamp") private var stamp = true

    private let widths = [320, 480, 640, 960]
    private func widthName(_ w: Int) -> String { [320: "流畅", 480: "标准", 640: "高清", 960: "超清"][w] ?? "\(w)" }

    var body: some View {
        ScrollView {
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
                        Text(stats).font(.footnote).foregroundStyle(Theme.muted)
                        Spacer()
                        if sound {
                            Button { Haptics.tap(); video.muted.toggle() } label: {
                                Image(systemName: video.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            }
                        }
                    }
                    if video.askedH264 && video.codec == "JPEG" {
                        Text("对方发的是 JPEG：安卓端要更新到 0.7，或者那台手机的硬件编码用不了").font(.footnote)
                            .foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !video.tip.isEmpty {
                        Text(video.tip).font(.footnote).foregroundStyle(Theme.orangeText).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Button {
                    Haptics.tap()
                    if video.running { video.stop() }
                    else {
                        video.start(target: target, seconds: 0, fps: fps, width: width, quality: Int(quality),
                                    sound: sound, lens: lens, compat: compat, flip: flip, stamp: stamp)
                    }
                } label: {
                    Label(video.running ? "停止" : "开始看画面", systemImage: video.running ? "stop.circle" : "play.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(video.running ? Theme.redText : Theme.orangeText).fontWeight(.semibold)
                }
                .buttonStyle(.bordered)

                controls

                Text("一直播到点「停止」。画面经云盘服务器中转，不写存储。对方那台要开着待命。直播中调参数大约 1 秒生效。")
                    .font(.caption2).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle("实时画面")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { video.stop() }
    }

    /// 开始前选好；直播中改了马上发给对方。
    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("镜头", selection: $lens) {
                Text("后置").tag("back")
                Text("前置").tag("front")
            }
            .pickerStyle(.segmented)
            .onChange(of: lens) {
                if lens == "front" { torch = false }
                video.adjust(["lens": lens])
            }

            HStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    flip.toggle()
                    video.adjust(["flip": flip])
                } label: {
                    Label(flip ? "已上下翻转" : "上下翻转", systemImage: "arrow.up.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(flip ? Theme.orangeText : nil)
                Toggle("印日期时间", isOn: $stamp)
                    .onChange(of: stamp) { video.adjust(["stamp": stamp]) }
            }

            Picker("清晰度", selection: $width) {
                ForEach(widths, id: \.self) { w in Text(widthName(w)).tag(w) }
            }
            .pickerStyle(.segmented)
            .onChange(of: width) { video.adjust(["width": width]) }

            row("画质 \(Int(quality))") {
                Slider(value: $quality, in: 20...85, step: 5) { editing in
                    if !editing { video.adjust(["quality": Int(quality)]) }
                }
            }
            Stepper("帧率 \(fps) 帧/秒", value: $fps, in: 1...15)
                .onChange(of: fps) { video.adjust(["fps": fps]) }

            if video.running {
                row("亮度 \(exposure == 0 ? "自动" : String(format: "%+.1f", exposure))") {
                    Slider(value: $exposure, in: -1...1, step: 0.1) { editing in
                        if !editing { video.adjust(["exposure": exposure]) }
                    }
                }
                row("变焦 \(Int(zoom * 100))%") {
                    Slider(value: $zoom, in: 0...1, step: 0.05) { editing in
                        if !editing { video.adjust(["zoom": zoom]) }
                    }
                }
                Toggle("手电（后置镜头才有）", isOn: $torch)
                    .disabled(lens == "front")
                    .onChange(of: torch) { video.adjust(["torch": torch]) }
            } else {
                Toggle("声音（和画面同步，按网络情况自动缓冲 0.1～0.6 秒）", isOn: $sound)
            }
            Toggle("兼容模式（JPEG：费流量、没那么流畅，H.264 画面不对时用）", isOn: $compat)
                .onChange(of: compat) { video.adjust(["codec": compat ? "jpeg" : "h264"]) }
        }
        .font(.subheadline)
    }

    private var stats: String {
        var parts = [String]()
        if !video.route.isEmpty { parts.append(video.route) }
        if !video.codec.isEmpty { parts.append(video.codec) }
        parts.append("\(video.fps) 帧/秒")
        if video.kbps > 0 { parts.append("\(video.kbps) kbps") }
        if video.bufferMs > 0 { parts.append("缓冲 \(video.bufferMs) ms") }
        return parts.joined(separator: " · ")
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(Theme.muted).font(.footnote)
            content()
        }
    }
}
