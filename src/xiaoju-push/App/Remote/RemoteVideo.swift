import SwiftUI
import UIKit

/// 实时画面查看器：发一条 video 指令让对方开始推流，然后长轮询视频信箱，取最新一帧显示。
@MainActor
final class RemoteVideo: ObservableObject {
    @Published private(set) var frame: UIImage?
    @Published private(set) var running = false
    @Published private(set) var note = ""
    @Published private(set) var frames = 0
    @Published private(set) var fps = 0

    private var task: Task<Void, Never>?

    func start(target: String, seconds: Int, fps wantFps: Int, width: Int, quality: Int) {
        guard !running else { return }
        let s = Store.shared
        let dev = target.trimmingCharacters(in: .whitespaces)
        guard !dev.isEmpty else { note = "先填设备名"; return }
        guard !s.cloudToken.isEmpty else { note = "先在设置里填云盘令牌"; return }

        running = true; frame = nil; frames = 0; note = "连接中…"
        let relay = RemoteRelay(base: s.cloudURL, token: s.cloudToken)
        let box = RemoteBox.video(dev)
        let id = idString()
        var cmd: [String: Any] = ["id": id, "do": "video", "lens": "back",
                                  "seconds": seconds, "fps": wantFps, "width": width, "quality": quality]
        if !s.remotePair.isEmpty { cmd["pair"] = s.remotePair }

        task = Task {
            do { try await relay.post(RemoteBox.inbox(dev), cmd) }
            catch {
                note = RemoteRelay.missing(error) ? "云盘服务端还不支持实时画面" : "发起失败：\(error.localizedDescription)"
                running = false; return
            }
            note = "等画面…"
            let end = Date().addingTimeInterval(TimeInterval(seconds + 12))
            var window = (t: Date(), n: 0)
            while running && Date() < end {
                let msgs = (try? await relay.wait(box, seconds: 15)) ?? []
                guard running else { break }
                if let last = msgs.last, let b64 = last["jpg"] as? String,
                   let data = Data(base64Encoded: b64), let img = UIImage(data: data) {
                    frame = rotated(img, (last["rot"] as? Int) ?? 0)
                    frames += msgs.count
                    note = ""
                    // 算实时帧率
                    window.n += msgs.count
                    if Date().timeIntervalSince(window.t) >= 1 {
                        fps = window.n; window = (Date(), 0)
                    }
                }
            }
            if running { note = "直播结束" }
            running = false
        }
    }

    func stop() {
        running = false
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
    @State private var seconds = 20
    @State private var fps = 3

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
                Text("已收到 \(video.frames) 帧 · \(video.fps) 帧/秒").font(.footnote).foregroundStyle(Theme.muted)
            } else {
                HStack {
                    Stepper("时长 \(seconds) 秒", value: $seconds, in: 5...60, step: 5)
                }
                Stepper("帧率 \(fps) 帧/秒", value: $fps, in: 1...8)
            }

            Button {
                Haptics.tap()
                if video.running { video.stop() }
                else { video.start(target: target, seconds: seconds, fps: fps, width: 480, quality: 40) }
            } label: {
                Label(video.running ? "停止" : "开始看画面", systemImage: video.running ? "stop.circle" : "play.circle")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .foregroundStyle(video.running ? Theme.redText : Theme.orangeText).fontWeight(.semibold)
            }
            .buttonStyle(.bordered)

            Text("1–2 秒延迟，画面走云盘中转。对方那台要开着待命、在前台。")
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
