import SwiftUI

enum PushPhase: Equatable {
    case idle
    case pushing(step: Int, detail: String)
    case done(sha: String, url: String, title: String, count: Int, added: Int, removed: Int, branch: String)
    case failed(String)
}

// 推送全屏画面：推送中（三步依次亮起）→ 成功（对勾 + 彩纸）或失败（抖动 + 大白话原因）。
struct PushPhaseView: View {
    let phase: PushPhase
    let repo: String
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onBack: () -> Void
    let onHome: () -> Void

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch phase {
            case .idle, .pushing:
                pushing
            case let .done(sha, url, title, count, added, removed, branch):
                DoneView(sha: sha, url: url, title: title, count: count, added: added, removed: removed,
                         target: "\(repo) / \(branch)", onBack: onBack, onHome: onHome)
            case .failed(let msg):
                FailView(message: msg, onRetry: onRetry, onBack: onBack)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: phase)
        .interactiveDismissDisabled()
    }

    private var step: Int { if case .pushing(let s, _) = phase { return s }; return 0 }
    private var detail: String { if case .pushing(_, let d) = phase { return d }; return "" }

    private var pushing: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 120)
            Bouncing()
            Text("正在推送…").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text).padding(.top, 24)
            Text(repo).font(.system(size: 15)).foregroundStyle(Theme.muted).padding(.top, 6)

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(Theme.orange).frame(width: g.size.width * CGFloat(step + 1) / 3.5)
                        .animation(.easeInOut(duration: 0.5), value: step)
                }
            }
            .frame(height: 8).padding(.horizontal, 16).padding(.top, 24)

            VStack(spacing: 0) {
                stepRow(0, "上传文件")
                stepRow(1, "创建提交")
                stepRow(2, "更新分支", last: true)
            }
            .card().padding(.top, 20)

            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                .padding(.horizontal, 16).padding(.top, 10)
            Spacer()
            Button("取消推送") { Haptics.tap(); onCancel() }
                .buttonStyle(BigButtonStyle(kind: .danger))
                .padding(.horizontal, 16).padding(.bottom, 24)
        }
    }

    private func stepRow(_ i: Int, _ label: String, last: Bool = false) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if i < step {
                    Circle().fill(Theme.greenFill)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
                } else if i == step {
                    ProgressView().tint(Theme.orange)
                } else {
                    Circle().stroke(Theme.faint, lineWidth: 2)
                }
            }
            .frame(width: 24, height: 24)
            .transition(.scale)
            Text(label).font(.system(size: 15)).foregroundStyle(i > step ? Theme.muted : Theme.text)
            Spacer()
        }
        .padding(.horizontal, 14).frame(height: 56)
        .rowDivider(!last)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: step)
    }

    /// 错误信息换成大白话：标题 + 怎么办
    static func friendly(_ msg: String) -> (title: String, advice: String) {
        if msg.contains("已取消") { return ("已取消", "什么都没推上去，随时可以重来。") }
        if msg.contains("（422）") || msg.contains("分支一直在变") {
            return ("分支刚被别人更新过", "点「重试」会先拿到最新内容再推，你的文件不会丢。")
        }
        if msg.contains("（401）") { return ("GitHub 令牌不对或过期了", "去设置里换一个新的 GitHub 令牌。") }
        if msg.contains("（403）") {
            return ("GitHub 令牌没有写权限", "令牌要能写这个仓库（Contents: Read and write），或者用了太多次，过一会儿再试。")
        }
        if msg.contains("（404）") { return ("找不到仓库或分支", "检查任务里的仓库名和分支有没有写错，令牌能不能看到这个仓库。") }
        if msg.contains("云盘") { return ("云盘没连上", "小橘云盘可能在睡觉，等半分钟再试；或者检查云盘令牌。") }
        if msg.contains("网络") || msg.contains("offline") || msg.contains("timed out") || msg.contains("超时") {
            return ("网络不通", "检查一下网络，再点重试。")
        }
        return ("没推上去", "看看下面的详情，或者稍后重试。")
    }
}

private struct Bouncing: View {
    @State private var up = false
    var body: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 40, weight: .bold))
            .foregroundStyle(Theme.orangeText)
            .frame(width: 96, height: 96)
            .background(Theme.orangeSoft, in: Circle())
            .offset(y: up ? -6 : 0)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: up)
            .onAppear { up = true }
    }
}

private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.width * 0.24, y: r.height * 0.53))
        p.addLine(to: CGPoint(x: r.width * 0.43, y: r.height * 0.71))
        p.addLine(to: CGPoint(x: r.width * 0.77, y: r.height * 0.33))
        return p
    }
}

private struct DoneView: View {
    let sha: String
    let url: String
    let title: String
    let count: Int
    let added: Int
    let removed: Int
    let target: String
    let onBack: () -> Void
    let onHome: () -> Void
    @State private var pop = false
    @State private var drawn = false
    @State private var ring = false

    var body: some View {
        ZStack {
            Confetti().ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer().frame(height: 120)
                ZStack {
                    Circle().stroke(Theme.green, lineWidth: 3)
                        .scaleEffect(ring ? 1.8 : 1).opacity(ring ? 0 : 0.6)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: ring)
                    Circle().fill(Theme.greenFill).scaleEffect(pop ? 1 : 0.4).opacity(pop ? 1 : 0)
                        .animation(.spring(response: 0.45, dampingFraction: 0.5), value: pop)
                    CheckShape().trim(from: 0, to: drawn ? 1 : 0)
                        .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                        .animation(.easeOut(duration: 0.4).delay(0.3), value: drawn)
                }
                .frame(width: 112, height: 112)
                Text("推送成功").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text).padding(.top, 28)
                Text("\(count) 个文件已推到 \(target)").font(.system(size: 15)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).padding(.top, 6).padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(String(sha.prefix(7))).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.blueText)
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                    }
                    HStack(spacing: 12) {
                        Text("+\(added)").foregroundStyle(Theme.green)
                        Text("−\(removed)").foregroundStyle(Theme.red)
                        Text("刚刚").foregroundStyle(Theme.muted)
                    }
                    .font(.system(size: 13, design: .monospaced))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).card().padding(.top, 28)

                Spacer()
                VStack(spacing: 10) {
                    if let u = URL(string: url) {
                        Link(destination: u) { Text("在 GitHub 查看这次提交") }
                            .buttonStyle(BigButtonStyle(kind: .plain))
                            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                    }
                    Button("继续推剩下的") { Haptics.tap(); onBack() }.buttonStyle(BigButtonStyle(kind: .plain))
                    Button("返回任务列表") { Haptics.tap(); onHome() }.buttonStyle(BigButtonStyle(kind: .blue))
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
        }
        .onAppear { pop = true; drawn = true; ring = true }
    }
}

private struct FailView: View {
    let message: String
    let onRetry: () -> Void
    let onBack: () -> Void
    @State private var shakes: CGFloat = 0
    @State private var open = false

    var body: some View {
        let f = PushPhaseView.friendly(message)
        VStack(spacing: 0) {
            Spacer().frame(height: 120)
            Image(systemName: "exclamationmark")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(Theme.red)
                .frame(width: 96, height: 96)
                .background(Theme.redSoft, in: Circle())
                .modifier(Shake(animatableData: shakes))
            Text(f.title).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text).padding(.top, 24)
            Text(f.advice).font(.system(size: 15)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).padding(.horizontal, 32).padding(.top, 8)

            VStack(spacing: 0) {
                Button {
                    Haptics.tap()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { open.toggle() }
                } label: {
                    HStack {
                        Text("技术详情").foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .font(.system(size: 15))
                    .padding(.horizontal, 14).frame(height: 48)
                }
                .buttonStyle(PressStyle())
                if open {
                    Text(message).font(Theme.mono).foregroundStyle(Theme.redText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).background(Theme.bg)
                        .textSelection(.enabled)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .card().padding(.top, 24)

            Spacer()
            VStack(spacing: 10) {
                Button { Haptics.heavy(); onRetry() } label: { Label("重试", systemImage: "arrow.clockwise") }
                    .buttonStyle(BigButtonStyle(kind: .push))
                Button("返回改动列表") { Haptics.tap(); onBack() }.buttonStyle(BigButtonStyle(kind: .plain))
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.5)) { shakes += 1 } }
    }
}
