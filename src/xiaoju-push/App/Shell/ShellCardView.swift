import SwiftUI

// 对话里的命令卡片（设计画布「手机上跑命令」两屏）：
// 黑底，第一行 ✓/✗/转圈 + $ 命令 + 用时（跑的时候带停止键），下面是输出。
// 会改东西的命令先停在卡片上等「运行 / 不要」；输出超过 10 行只留最后几行，点「展开全部」看完整的。

struct ShellCard: Equatable {
    enum State: Equatable {
        /// 等确认，附一句为什么要确认
        case pending(String)
        case running
        case ok
        case failed(Int32)
        case killed
        case rejected
    }

    var command: String
    /// 在哪个文件夹跑（「工作区 / meta-work」）
    var folder: String
    var output = ""
    var state: State
    var started: Date?
    var seconds: Double?
}

struct ShellCardView: View {
    let card: ShellCard
    let approve: () -> Void
    let reject: () -> Void
    let stop: () -> Void
    @State private var expanded = false

    private static let foldAt = 10
    private static let keep = 6
    private let bg = Color(dark: 0x1a1a18, light: 0x22211f)
    private let line = Color(dark: 0x2f2e2b, light: 0x3a3936)
    private let fg = Color(dark: 0xc9c6be, light: 0xd6d3cb)
    private let head = Color(dark: 0xecebe6, light: 0xf2f0ea)

    private var lines: [Substring] {
        let t = card.output.trimmingCharacters(in: .newlines)
        return t.isEmpty ? [] : t.split(separator: "\n", omittingEmptySubsequences: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            outputView
            if case .pending(let why) = card.state { confirm(why) }
            if case .rejected = card.state {
                Text("没跑").font(.system(size: 13)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            if lines.count > Self.foldAt {
                Button {
                    Haptics.tap()
                    withAnimation(.spring(response: 0.3)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "收起" : "展开全部 \(lines.count) 行")
                        .font(.system(size: 13)).foregroundStyle(Color(dark: 0xa6a39b, light: 0xb5b2aa))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .overlay(alignment: .top) { line.frame(height: 1) }
            }
        }
        .background(bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(dark: 0x3a3936, light: 0x3a3936), lineWidth: 1))
        .animation(.spring(response: 0.3), value: card.state)
    }

    private var header: some View {
        HStack(spacing: 8) {
            stateIcon.frame(width: 16)
            Text("$ " + card.command)
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(head)
                .lineLimit(expanded ? 4 : 1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            time
            if card.state == .running {
                Button { Haptics.tap(); stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 10))
                        .foregroundStyle(head)
                        .frame(width: 32, height: 32)
                        .background(Color(dark: 0x33322f, light: 0x3a3936), in: Circle())
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel("停止这条命令")
            }
        }
        .padding(.leading, 12).padding(.trailing, card.state == .running ? 0 : 12)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { if !lines.isEmpty || card.state == .running { line.frame(height: 1) } }
    }

    @ViewBuilder private var stateIcon: some View {
        switch card.state {
        case .running: ProgressView().controlSize(.mini).tint(Theme.orange)
        case .ok: Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.green)
        case .failed, .killed: Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.red)
        case .pending: Text("?").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Theme.yellow)
        case .rejected: Image(systemName: "minus").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint)
        }
    }

    @ViewBuilder private var time: some View {
        let style = Font.system(size: 12, design: .monospaced)
        let c = Color(dark: 0xa6a39b, light: 0xb5b2aa)
        switch card.state {
        case .running:
            if let s = card.started {
                TimelineView(.periodic(from: s, by: 1)) { ctx in
                    Text(Self.clock(ctx.date.timeIntervalSince(s))).font(style).foregroundStyle(c)
                }
            }
        case .pending: Text("等你确认").font(.system(size: 12)).foregroundStyle(Theme.yellow)
        case .rejected: EmptyView()
        default:
            if let s = card.seconds { Text(Self.short(s)).font(style).foregroundStyle(c) }
        }
    }

    @ViewBuilder private var outputView: some View {
        let all = lines
        let shown: [Substring] = (!expanded && all.count > Self.foldAt) ? Array(all.suffix(Self.keep)) : all
        if !all.isEmpty || card.state == .running || isFailed || card.state == .ok {
            VStack(alignment: .leading, spacing: 2) {
                if !expanded && all.count > Self.foldAt {
                    Text("…（前面 \(all.count - Self.keep) 行收起来了）").foregroundStyle(Color(dark: 0x7a776f, light: 0x9a978f))
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, l in
                    Text(l.isEmpty ? " " : String(l)).lineLimit(expanded ? nil : 1).truncationMode(.tail)
                }
                if all.isEmpty && card.state == .running {
                    Text("…").foregroundStyle(Color(dark: 0x7a776f, light: 0x9a978f))
                }
                if case .failed(let code) = card.state {
                    Text("✗ 出错了（退出码 \(code)）").foregroundStyle(Theme.red)
                }
                if card.state == .killed {
                    Text("✗ 停了").foregroundStyle(Theme.red)
                }
                if card.state == .ok || isFailed {
                    Text("在「\(card.folder)」里跑").font(.system(size: 11)).foregroundStyle(Color(dark: 0x7a776f, light: 0x9a978f))
                        .padding(.top, 4)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(fg)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
    }

    private var isFailed: Bool {
        switch card.state { case .failed, .killed: return true; default: return false }
    }

    private func confirm(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(why + "。在「\(card.folder)」里跑。")
                .font(.system(size: 13)).foregroundStyle(Color(dark: 0xe8b48f, light: 0xe8b48f))
                .lineSpacing(2)
            HStack(spacing: 8) {
                Button { Haptics.tap(); approve() } label: {
                    Text("运行").font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(Color(dark: 0x1a1a18, light: 0x1a1a18))
                        .background(Theme.orange, in: Capsule())
                }
                Button { Haptics.tap(); reject() } label: {
                    Text("不要").font(.system(size: 15))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(head)
                        .overlay(Capsule().stroke(Color(dark: 0x45443f, light: 0x5a5953), lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
    }

    static func clock(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func short(_ t: Double) -> String {
        t < 10 ? String(format: "%.1fs", t) : (t < 60 ? "\(Int(t))s" : clock(t))
    }
}
