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
                NavigationLink {
                    RemoteMonitorView(target: target)
                } label: {
                    Label("移动侦测（安卓 0.8+）", systemImage: "figure.walk.motion").foregroundStyle(Theme.orangeText)
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
                btn("模型测速（安卓 0.10+，约 1 分钟）", "speedometer") { await control.send("bench", to: target, wait: 180) }
            }
            .listRowBackground(Theme.card)
            .disabled(target.isEmpty)

            if !control.pending.isEmpty {
                Section("等回执") {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(control.pending) { p in
                                HStack {
                                    ProgressView()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(control.label(p.action)).foregroundStyle(Theme.text)
                                        Text("\(p.received ? "对方收到了，正在做" : "已发出，等对方收到") · \(Int(ctx.date.timeIntervalSince(p.started))) 秒")
                                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    Button("取消") { Haptics.tap(); Task { await control.cancel(p) } }
                                        .buttonStyle(.borderless).foregroundStyle(Theme.redText)
                                }
                            }
                        }
                    }
                }
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
