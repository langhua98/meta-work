import SwiftUI

// 设置 → 遥控（被控端）。这台 iPhone 开「待命」后，被另一台设备通过云盘发指令调用硬件。
struct RemoteView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var center = RemoteCenter.shared

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
