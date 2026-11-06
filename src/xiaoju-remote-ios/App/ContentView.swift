import AVFoundation
import CoreLocation
import SwiftUI

let brandOrange = Color(red: 1.0, green: 0.48, blue: 0.09)

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var engine: RemoteEngine
    @State private var locMgr = CLLocationManager()

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("这台 iPhone 开「待命」后，等另一台设备发来的指令：拍照、录音、定位、手电筒、震动、响铃。被远程使用时屏幕会一直亮着，动作都记在下面。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("云盘") {
                    TextField("云盘地址", text: $store.base)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                    SecureField("云盘令牌 xa_…", text: $store.token)
                }
                Section("这台设备") {
                    TextField("设备名，比如 测试机B", text: $store.device)
                    SecureField("配对口令（两台要一样）", text: $store.pair)
                }

                Section {
                    Button("授权硬件（相机 / 麦克风 / 定位）") { requestPermissions() }
                    Button(engine.running ? "停止待命" : "开始待命") {
                        engine.running ? engine.stop() : engine.start()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(engine.running ? Color.red : brandOrange)
                } footer: {
                    Text(engine.running ? "● 待命中（设备名：\(store.device)）" : "○ 未运行")
                        .foregroundStyle(engine.running ? .green : .secondary)
                        .font(.body.weight(.semibold))
                }

                Section("记录") {
                    if engine.log.isEmpty {
                        Text("还没有动作").foregroundStyle(.secondary).font(.footnote)
                    } else {
                        ForEach(Array(engine.log.suffix(60).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption2, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("小橘遥控")
        }
        .navigationViewStyle(.stack)
        .tint(brandOrange)
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        locMgr.requestWhenInUseAuthorization()
    }
}
