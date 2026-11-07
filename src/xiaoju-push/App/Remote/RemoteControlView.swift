import SwiftUI
import UIKit

// 控制端：选目标设备，发指令，看回执和照片。
struct RemoteControlView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var control = RemoteControl.shared
    @State private var seconds = 5

    private var target: String { store.remoteTarget.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section("控制谁") {
                TextField("对方的设备名（和它那边填的一样）", text: $store.remoteTarget)
                SecureField("配对口令（两台要一样）", text: $store.remotePair)
            }
            .listRowBackground(Theme.card)

            Section("实时画面") {
                NavigationLink {
                    RemoteVideoView(target: target)
                } label: {
                    Label("看对方的实时画面", systemImage: "video").foregroundStyle(Theme.orangeText)
                }
                .disabled(target.isEmpty)
            }
            .listRowBackground(Theme.card)

            Section("发指令") {
                btn("拍照（后摄）", "camera") { await control.send("photo", to: target, lens: "back") }
                btn("拍照（前摄）", "camera.rotate") { await control.send("photo", to: target, lens: "front") }
                btn("录音 \(seconds) 秒", "mic") { await control.send("audio", to: target, seconds: seconds) }
                Stepper("录音时长：\(seconds) 秒", value: $seconds, in: 1...60)
                btn("定位", "location") { await control.send("location", to: target) }
                btn("手电筒 开", "flashlight.on.fill") { await control.send("torch", to: target, on: true) }
                btn("手电筒 关", "flashlight.off.fill") { await control.send("torch", to: target, on: false) }
                btn("响铃找手机", "bell") { await control.send("ring", to: target, seconds: seconds) }
                btn("设备信息", "info.circle") { await control.send("info", to: target) }
            }
            .listRowBackground(Theme.card)
            .disabled(control.sending || target.isEmpty)

            if control.sending {
                Section { Label("发出去了，等对方回…", systemImage: "hourglass").foregroundStyle(Theme.muted) }
                    .listRowBackground(Theme.card)
            }

            if !control.replies.isEmpty {
                Section("回执") {
                    ForEach(control.replies) { r in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(r.at) · \(r.action)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Text(r.text).font(.system(size: 14)).foregroundStyle(Theme.text)
                            if let img = r.image {
                                Image(uiImage: img).resizable().scaledToFit()
                                    .frame(maxHeight: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listRowBackground(Theme.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    private func btn(_ title: String, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button {
            Haptics.tap()
            Task { await action() }
        } label: {
            Label(title, systemImage: icon).foregroundStyle(Theme.orangeText)
        }
    }
}
