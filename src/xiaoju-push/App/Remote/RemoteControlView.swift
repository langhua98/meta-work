import SwiftUI
import UIKit

// 云控：选一台设备，发指令，看回执和照片。
// 上面选设备（法莉娅是 A～D，别的设备点「其他」填名字），中间是画面和常用指令的方块，
// 云台、测速这些不常用的收在「更多」里，最下面是等回执和回执。
struct RemoteControlView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var control = RemoteControl.shared
    @State private var seconds = 5
    @State private var custom = false
    @State private var showMore = false

    private static let devices = ["A", "B", "C", "D"]
    private var target: String { store.remoteTarget.trimmingCharacters(in: .whitespaces) }
    /// 名字不是 A～D（iPhone 被控端、老版本安卓）：显示输入框
    private var isCustom: Bool { custom || (!target.isEmpty && !Self.devices.contains(target)) }

    var body: some View {
        Form {
            deviceSection
            viewSection
            commandSection
            moreSection
            pendingSection
            replySection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }

    // MARK: 选设备

    private var deviceSection: some View {
        Section {
            Picker("设备", selection: Binding(
                get: { isCustom ? "其他" : (target.isEmpty ? "" : target) },
                set: { v in
                    Haptics.tap()
                    if v == "其他" { custom = true; if Self.devices.contains(target) { store.remoteTarget = "" } }
                    else { custom = false; store.remoteTarget = v }
                })) {
                ForEach(Self.devices + ["其他"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            if isCustom {
                TextField("设备名（iPhone 被控端、旧版安卓）", text: $store.remoteTarget)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            SecureField("配对口令（空着 = 0）", text: $store.remotePair)
        } header: {
            Text("控制哪台")
        } footer: {
            Text(target.isEmpty ? "先选一台。法莉娅（安卓）的设备名是 A～D，在它的 App 里选。"
                                : "发给「\(target)」。口令要和那台一样。")
        }
        .listRowBackground(Theme.card)
    }

    // MARK: 画面

    private var viewSection: some View {
        Section("画面") {
            NavigationLink { RemoteVideoView(target: target) } label: {
                row("实时画面", "看摄像头，带声音", "video.fill")
            }
            NavigationLink { RemoteMonitorView(target: target) } label: {
                row("移动侦测", "有动静就录，录像和提醒", "figure.walk.motion")
            }
        }
        .listRowBackground(Theme.card)
        .disabled(target.isEmpty)
    }

    // MARK: 常用指令（方块）

    private var commandSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                tile("拍照", "camera.fill", "photo") { await control.send("photo", to: target, lens: "back") }
                tile("前摄拍照", "camera.rotate.fill", "photo") { await control.send("photo", to: target, lens: "front") }
                tile("录音 \(seconds) 秒", "mic.fill", "audio") { await control.send("audio", to: target, seconds: seconds) }
                tile("手电 开", "flashlight.on.fill", "torch") { await control.send("torch", to: target, on: true) }
                tile("手电 关", "flashlight.off.fill", "torch") { await control.send("torch", to: target, on: false) }
                tile("响铃找手机", "bell.fill", "ring") { await control.send("ring", to: target, seconds: seconds) }
                tile("定位", "location.fill", "location") { await control.send("location", to: target) }
                tile("设备信息", "info.circle.fill", "info") { await control.send("info", to: target) }
                tile("更新到最新", "arrow.down.circle.fill", "update") { await control.send("update", to: target, wait: 300) }
            }
            .padding(.vertical, 4)
            Stepper("录音、响铃 \(seconds) 秒", value: $seconds, in: 1...60)
        } header: {
            Text("指令")
        }
        .listRowBackground(Theme.card)
        .disabled(target.isEmpty)
    }

    // MARK: 更多（云台、测速、查更新）

    private var moreSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showMore) {
                Button { send("update", wait: 60, extra: ["check": true]) } label: { row("查更新", "只看有没有新版本，不装（安卓 0.19+）", "arrow.triangle.2.circlepath") }
                Button { send("bench", wait: 180) } label: { row("模型测速", "大约 1 分钟（安卓 0.10+）", "speedometer") }
                VStack(alignment: .leading, spacing: 10) {
                    Text("云台（大疆 OM，夹着 iPhone 的那台）").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    HStack(spacing: 0) {
                        gimbalPad("arrow.left", "左转 30°") { ["action": "turn", "yaw": -30] }
                        gimbalPad("arrow.up", "抬头 15°") { ["action": "turn", "pitch": 15] }
                        gimbalPad("scope", "回中") { ["action": "center"] }
                        gimbalPad("arrow.down", "低头 15°") { ["action": "turn", "pitch": -15] }
                        gimbalPad("arrow.right", "右转 30°") { ["action": "turn", "yaw": 30] }
                    }
                    HStack(spacing: 0) {
                        gimbalPad("link", "连接") { ["action": "connect"] }
                        gimbalPad("info.circle", "状态") { ["action": "status"] }
                        gimbalPad("stop.circle", "停") { ["action": "stop"] }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("更多", systemImage: "ellipsis.circle").foregroundStyle(Theme.text)
            }
        }
        .listRowBackground(Theme.card)
        .disabled(target.isEmpty)
    }

    // MARK: 等回执、回执

    @ViewBuilder private var pendingSection: some View {
        if !control.pending.isEmpty {
            Section("等回执") {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(control.pending) { p in
                            HStack {
                                ProgressView()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(control.label(p.action)) → \(p.target)").foregroundStyle(Theme.text)
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
    }

    @ViewBuilder private var replySection: some View {
        if !control.replies.isEmpty {
            Section("回执") {
                ForEach(control.replies) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(control.label(r.action)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.orangeText)
                            Spacer()
                            Text(r.at).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        Text(r.text).font(.system(size: 14)).foregroundStyle(Theme.text).textSelection(.enabled)
                        if let img = r.image {
                            Image(uiImage: img).resizable().scaledToFit()
                                .frame(maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listRowBackground(Theme.card)
        }
    }

    // MARK: 小部件

    /// 一行：图标、标题、小字说明
    private func row(_ title: String, _ sub: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.orangeText).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.text)
                Text(sub).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 2)
    }

    /// 常用指令的方块：图标 + 字；这个指令还在等回执时转圈
    private func tile(_ title: String, _ icon: String, _ action: String, _ run: @escaping () async -> Void) -> some View {
        Button {
            Haptics.tap()
            Task { await run() }
        } label: {
            VStack(spacing: 6) {
                if control.isPending(action) {
                    ProgressView().frame(height: 22)
                } else {
                    Image(systemName: icon).font(.system(size: 20, weight: .semibold)).frame(height: 22)
                }
                Text(title).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .foregroundStyle(target.isEmpty ? Theme.faint : Theme.orangeText)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.raised))
        }
        .buttonStyle(.borderless)
    }

    /// 云台方向键：一个图标 + 小字，点一下发一条 gimbal 指令（闭环转动要几秒）
    private func gimbalPad(_ icon: String, _ title: String, _ args: @escaping () -> [String: Any]) -> some View {
        Button {
            Haptics.tap()
            let a = args()
            Task { await control.send("gimbal", to: target, wait: (a["action"] as? String) == "connect" ? 30 : 40, extra: a) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(Theme.orangeText)
        }
        .buttonStyle(.borderless)
    }

    private func send(_ action: String, wait: TimeInterval = 90, extra: [String: Any] = [:]) {
        Haptics.tap()
        Task { await control.send(action, to: target, wait: wait, extra: extra) }
    }
}
