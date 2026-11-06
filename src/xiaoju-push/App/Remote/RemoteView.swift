import SwiftUI

// 设置 → 遥控。这台 iPhone 开「待命」后，被另一台设备通过云盘发指令调用硬件；
// 也可以在下面「遥控别的设备」里给另一台发指令（发送端）。
struct RemoteView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var center = RemoteCenter.shared
    @ObservedObject private var sender = RemoteSender.shared
    @AppStorage("remoteTarget") private var target = ""
    @State private var action = "info"
    @State private var front = false
    @State private var seconds = 5
    @State private var torchOn = true

    private let actions: [(String, String)] = [
        ("info", "设备信息"), ("photo", "拍照"), ("audio", "录音"), ("location", "定位"),
        ("torch", "手电筒"), ("vibrate", "震动"), ("ring", "响铃（找手机）"),
    ]

    private var params: [String: Any] {
        switch action {
        case "photo": return ["lens": front ? "front" : "back"]
        case "audio", "ring": return ["seconds": seconds]
        case "torch": return ["on": torchOn]
        case "vibrate": return ["ms": 800]
        default: return [:]
        }
    }

    var body: some View {
        Form {
            Section {
                Text("开「待命」后，另一台设备（安卓或 iPhone）通过小橘云盘发指令，调用这台的硬件：拍照、录音、定位、手电筒、震动、响铃。走云盘中转，不用同一个网络。")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            .listRowBackground(Theme.card)

            Section("这台设备") {
                TextField("设备名，比如 测试机B", text: $store.remoteDevice)
                SecureField("配对口令（两台要一样）", text: $store.remotePair)
            }
            .listRowBackground(Theme.card)

            Section {
                Button {
                    Haptics.tap()
                    center.running ? center.stop() : center.start()
                } label: {
                    Label(center.running ? "停止待命" : "开始待命",
                          systemImage: center.running ? "stop.circle" : "dot.radiowaves.left.and.right")
                        .foregroundStyle(center.running ? Theme.redText : Theme.orangeText)
                        .fontWeight(.semibold)
                }
            } footer: {
                Text(center.running ? "● 待命中 · 屏幕会保持常亮，别切后台（iOS 后台不能用摄像头麦克风）"
                                    : "○ 未运行")
                    .foregroundStyle(center.running ? Theme.green : Theme.muted)
            }
            .listRowBackground(Theme.card)

            Section {
                TextField("对方的设备名（和对方 App 里填的一样）", text: $target)
                Picker("指令", selection: $action) {
                    ForEach(actions, id: \.0) { Text($0.1).tag($0.0) }
                }
                if action == "photo" { Toggle("用前摄", isOn: $front) }
                if action == "audio" || action == "ring" { Stepper("\(seconds) 秒", value: $seconds, in: 1...60) }
                if action == "torch" { Toggle("打开", isOn: $torchOn) }
                Button {
                    Haptics.tap()
                    Task { await sender.send(to: target, action: action, params: params) }
                } label: {
                    Label(sender.busy ? "等回执…" : "发送", systemImage: "paperplane")
                        .foregroundStyle(Theme.orangeText).fontWeight(.semibold)
                }
                .disabled(sender.busy)
                if !sender.status.isEmpty {
                    Text(sender.status).font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                if !sender.receipt.isEmpty {
                    Text(sender.receipt).font(Theme.mono).textSelection(.enabled)
                }
                if let img = sender.image {
                    Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
                }
                ForEach(sender.fileNotes, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            } header: {
                Text("遥控别的设备")
            } footer: {
                Text("配对口令用上面填的那个，要和对方一样。对方得开着「待命」。")
            }
            .listRowBackground(Theme.card)

            if !center.log.isEmpty {
                Section("记录") {
                    ForEach(Array(center.log.suffix(60).enumerated()), id: \.offset) { _, line in
                        Text(line).font(Theme.mono).foregroundStyle(Theme.muted)
                    }
                }
                .listRowBackground(Theme.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("遥控")
        .navigationBarTitleDisplayMode(.inline)
    }
}
