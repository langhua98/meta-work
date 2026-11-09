import SwiftUI
import UIKit

// 首页 → 工具 → 遥控。这台只做控制端：选目标设备，看画面、转云台、发指令，看回执和照片。
// 被控端都在 langhua98/xiaoju-remote（iPhone、安卓）。
struct RemoteControlView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var control = RemoteControl.shared
    @State private var seconds = 5

    private var target: String { store.remoteTarget.trimmingCharacters(in: .whitespaces) }
    private var ready: Bool { !target.isEmpty }

    private let grid = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                targetCard

                if !control.pending.isEmpty { pendingCard }

                group("实时画面") {
                    HStack(spacing: 10) {
                        NavigationLink { RemoteVideoView(target: target) } label: {
                            BigTile(icon: "video.fill", title: "实时画面", sub: "看 · 听 · 调参数")
                        }
                        NavigationLink { RemoteMonitorView(target: target) } label: {
                            BigTile(icon: "figure.walk.motion", title: "移动侦测", sub: "安卓 0.8+")
                        }
                    }
                    .buttonStyle(PressStyle())
                }
                .disabled(!ready).opacity(ready ? 1 : 0.45)

                group("云台（大疆 OM）",
                      footer: "对方是夹在 OM 云台上的 iPhone（机器人模式）。看着云台姿态一点点转，一次要几秒，误差几度。") {
                    HStack(alignment: .center, spacing: 16) {
                        dpad
                        VStack(spacing: 8) {
                            chip("连接", "link") { await control.send("gimbal", to: target, wait: 30, extra: ["action": "connect"]) }
                            chip("状态", "info.circle") { await control.send("gimbal", to: target, extra: ["action": "status"]) }
                            chip("停", "stop.fill", danger: true) { await control.send("gimbal", to: target, extra: ["action": "stop"]) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(!ready).opacity(ready ? 1 : 0.45)

                group("指令") {
                    VStack(spacing: 10) {
                        LazyVGrid(columns: grid, spacing: 10) {
                            tile("后摄拍照", "camera") { await control.send("photo", to: target, lens: "back") }
                            tile("前摄拍照", "camera.rotate") { await control.send("photo", to: target, lens: "front") }
                            tile("录音 \(seconds) 秒", "mic") { await control.send("audio", to: target, seconds: seconds) }
                            tile("定位", "location") { await control.send("location", to: target) }
                            tile("响铃 \(seconds) 秒", "bell") { await control.send("ring", to: target, seconds: seconds) }
                            tile("设备信息", "info.circle") { await control.send("info", to: target) }
                            tile("手电筒 开", "flashlight.on.fill") { await control.send("torch", to: target, on: true) }
                            tile("手电筒 关", "flashlight.off.fill") { await control.send("torch", to: target, on: false) }
                        }
                        Stepper(value: $seconds, in: 1...60) {
                            Label("录音 / 响铃 \(seconds) 秒", systemImage: "timer")
                                .font(.system(size: 15)).foregroundStyle(Theme.text)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .disabled(!ready).opacity(ready ? 1 : 0.45)

                group("安卓维护", footer: "测速约 1 分钟；更新要安卓 0.19 以上。") {
                    LazyVGrid(columns: grid, spacing: 10) {
                        tile("模型测速", "speedometer") { await control.send("bench", to: target, wait: 180) }
                        tile("查更新", "arrow.triangle.2.circlepath") {
                            await control.send("update", to: target, wait: 60, extra: ["check": true])
                        }
                        tile("更新到最新", "arrow.down.circle") { await control.send("update", to: target, wait: 300) }
                    }
                }
                .disabled(!ready).opacity(ready ? 1 : 0.45)

                if !control.replies.isEmpty { repliesCard }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
            .animation(.easeInOut(duration: 0.2), value: control.pending.count)
            .animation(.easeInOut(duration: 0.2), value: control.replies.count)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .navigationTitle("遥控")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 控制谁

    private var targetCard: some View {
        group("控制谁", footer: ready ? nil : "填对方的设备名（和它那边填的一样）后才能发指令。") {
            VStack(spacing: 0) {
                field("iphone.gen2") {
                    TextField("对方的设备名", text: $store.remoteTarget)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Divider().overlay(Theme.divider).padding(.leading, 48)
                field("key") {
                    SecureField("配对口令（两台要一样）", text: $store.remotePair)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func field<F: View>(_ icon: String, @ViewBuilder _ content: () -> F) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Theme.orangeText).frame(width: 24)
            content().font(.system(size: 16)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 12).frame(minHeight: 50)
    }

    // MARK: 云台方向键

    private var dpad: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                padKey("arrow.up", "抬头 15°") { ["action": "turn", "pitch": 15] }
                Color.clear.frame(width: 1, height: 1)
            }
            GridRow {
                padKey("arrow.left", "左转 30°") { ["action": "turn", "yaw": -30] }
                padKey("scope", "回中", center: true) { ["action": "center"] }
                padKey("arrow.right", "右转 30°") { ["action": "turn", "yaw": 30] }
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                padKey("arrow.down", "低头 15°") { ["action": "turn", "pitch": -15] }
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    /// 方向键：点一下发一条 gimbal 指令（闭环转动要几秒）
    private func padKey(_ icon: String, _ title: String, center: Bool = false,
                        _ args: @escaping () -> [String: Any]) -> some View {
        Button {
            Haptics.tap()
            Task { await control.send("gimbal", to: target, wait: 40, extra: args()) }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 58, height: 52)
            .foregroundStyle(center ? Theme.onAccent : Theme.orangeText)
            .background(center ? Theme.orange : Theme.orangeSoft,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .accessibilityLabel(title)
    }

    private func chip(_ title: String, _ icon: String, danger: Bool = false,
                      _ action: @escaping () async -> Void) -> some View {
        Button {
            Haptics.tap()
            Task { await action() }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(danger ? Theme.redText : Theme.text)
                .background(danger ? Theme.redSoft : Theme.raised, in: Capsule())
        }
        .buttonStyle(PressStyle())
    }

    // MARK: 指令格子

    private func tile(_ title: String, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button {
            Haptics.tap()
            Task { await action() }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.orangeText)
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 78)
            .padding(.horizontal, 4)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressStyle(scale: 0.95))
    }

    // MARK: 回执

    private var pendingCard: some View {
        group("等回执") {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 0) {
                    ForEach(control.pending) { p in
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(control.label(p.action)).font(.system(size: 15)).foregroundStyle(Theme.text)
                                Text("\(p.received ? "对方收到了，正在做" : "已发出，等对方收到") · \(Int(ctx.date.timeIntervalSince(p.started))) 秒")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button("取消") { Haptics.tap(); Task { await control.cancel(p) } }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.redText)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        if p.id != control.pending.last?.id {
                            Divider().overlay(Theme.divider).padding(.leading, 14)
                        }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .transition(.opacity)
    }

    private var repliesCard: some View {
        group("回执") {
            VStack(spacing: 10) {
                ForEach(control.replies) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(r.action).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.orangeText)
                            Spacer()
                            Text(r.at).font(.system(size: 12)).foregroundStyle(Theme.faint)
                        }
                        Text(r.text).font(.system(size: 14)).foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let img = r.image {
                            Image(uiImage: img).resizable().scaledToFit()
                                .frame(maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    // MARK: 分组

    private func group<C: View>(_ title: String, footer: String? = nil,
                                @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                .padding(.leading, 4)
            content()
            if let footer {
                Text(footer).font(.system(size: 12)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 实时画面 / 移动侦测的大块入口
private struct BigTile: View {
    let icon: String
    let title: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.orangeText)
                .frame(width: 42, height: 42)
                .background(Theme.orangeSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text(sub).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
