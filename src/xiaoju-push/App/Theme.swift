import SwiftUI
import UIKit

// 界面风格：仿 GitHub 手机 App（深色 / 浅色跟着系统），小橘橙做品牌色。
// 绿色只给推送和成功，红色只给删除和失败。

extension Color {
    /// 深色、浅色各一种颜色
    init(dark: UInt32, light: UInt32) {
        self.init(UIColor { t in UIColor(hex: t.userInterfaceStyle == .dark ? dark : light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

enum Theme {
    static let bg = Color(dark: 0x0d1117, light: 0xf6f8fa)
    static let card = Color(dark: 0x161b22, light: 0xffffff)
    static let raised = Color(dark: 0x21262d, light: 0xf6f8fa)
    static let border = Color(dark: 0x30363d, light: 0xd0d7de)
    static let divider = Color(dark: 0x21262d, light: 0xd8dee4)
    static let text = Color(dark: 0xe6edf3, light: 0x1f2328)
    static let muted = Color(dark: 0x8d96a0, light: 0x59636e)
    static let faint = Color(dark: 0x6e7681, light: 0x818b98)
    static let blue = Color(dark: 0x4493f8, light: 0x0969da)
    static let blueFill = Color(dark: 0x1f6feb, light: 0x0969da)
    static let blueSoft = Color(dark: 0x1f2a37, light: 0xddf4ff)
    static let blueText = Color(dark: 0x79b8ff, light: 0x0969da)
    static let green = Color(dark: 0x3fb950, light: 0x1a7f37)
    static let greenFill = Color(dark: 0x238636, light: 0x1f883d)
    static let greenSoft = Color(dark: 0x12261e, light: 0xdafbe1)
    static let greenText = Color(dark: 0x7ee787, light: 0x116329)
    static let red = Color(dark: 0xf85149, light: 0xd1242f)
    static let redFill = Color(dark: 0xda3633, light: 0xcf222e)
    static let redSoft = Color(dark: 0x3c1618, light: 0xffebe9)
    static let redText = Color(dark: 0xffa198, light: 0xa40e26)
    static let yellow = Color(dark: 0xe3b341, light: 0x9a6700)
    static let yellowSoft = Color(dark: 0x3b2e10, light: 0xfff8c5)
    static let orange = Color(red: 0xf0 / 255, green: 0x88 / 255, blue: 0x3e / 255)
    static let orangeSoft = Color(dark: 0x2d1d0f, light: 0xfff1e5)
    static let orangeText = Color(dark: 0xf0883e, light: 0xbc4c00)
    static let mono = Font.system(size: 12, design: .monospaced)
}

// MARK: 震动

enum Haptics {
    /// 点按钮、进文件夹、每步完成
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    /// 勾选文件、切换文件
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    /// 全选、左滑到底
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    /// 按下推送
    static func heavy() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }

    /// 推送成功：成功震动后再补两下轻震
    static func celebrate() {
        success()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { tap() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { tap() }
    }
}

// MARK: 按钮

/// 所有可点的东西：按下缩小一点、变暗，松手弹簧回弹
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// 底部大按钮
struct BigButtonStyle: ButtonStyle {
    enum Kind { case push, blue, plain, danger }
    var kind: Kind = .push
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(enabled ? fg : Theme.muted)
            .background(enabled ? bg : Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(kind == .plain || !enabled ? Theme.border : Color.white.opacity(0.08), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
    }

    private var bg: Color {
        switch kind {
        case .push: return Theme.greenFill
        case .blue: return Theme.blueFill
        case .plain: return Theme.raised
        case .danger: return Theme.raised
        }
    }

    private var fg: Color {
        switch kind {
        case .push, .blue: return .white
        case .plain: return Theme.text
        case .danger: return Theme.redText
        }
    }
}

/// 小圆角标签：分支名、改动数
struct Pill: View {
    let text: String
    var fg: Color = Theme.blueText
    var bg: Color = Theme.blueSoft
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(fg)
            .background(bg, in: Capsule())
    }
}

/// 灰色小标题（列表分组用）
struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)
    }
}

/// 圆角卡片框
struct CardBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
    }
}

extension View {
    func card() -> some View { modifier(CardBox()) }

    /// 列表里每行之间的细线
    func rowDivider(_ show: Bool = true) -> some View {
        overlay(alignment: .bottom) { if show { Theme.divider.frame(height: 1) } }
    }
}

/// 改动类型小方块：新 / 改
struct KindTag: View {
    let isNew: Bool
    var body: some View {
        Text(isNew ? "A" : "M")
            .font(.system(size: 12, weight: .bold))
            .frame(width: 22, height: 22)
            .foregroundStyle(isNew ? Theme.green : Theme.yellow)
            .background(isNew ? Theme.greenSoft : Theme.yellowSoft, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 勾选圆圈，选中时弹一下
struct CheckCircle: View {
    let on: Bool
    var body: some View {
        ZStack {
            Circle().stroke(Theme.faint, lineWidth: 2).opacity(on ? 0 : 1)
            Circle().fill(Theme.blueFill).scaleEffect(on ? 1 : 0.3).opacity(on ? 1 : 0)
            Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
                .scaleEffect(on ? 1 : 0.3).opacity(on ? 1 : 0)
        }
        .frame(width: 24, height: 24)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: on)
    }
}

/// 左右抖一下（失败时）
struct Shake: GeometryEffect {
    var amount: CGFloat = 10
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(animatableData * .pi * 4), y: 0))
    }
}

/// 彩纸飘落（推送成功）
struct Confetti: View {
    @State private var fall = false
    private let pieces: [(x: CGFloat, color: Color, delay: Double, spin: Double)] = (0..<24).map { i in
        let colors: [Color] = [Theme.orange, Theme.green, Theme.blue, Theme.yellow]
        return (CGFloat((i * 37) % 100) / 100, colors[i % colors.count], Double(i % 8) * 0.12, Double(180 + (i * 53) % 360))
    }

    var body: some View {
        GeometryReader { g in
            ForEach(pieces.indices, id: \.self) { i in
                let p = pieces[i]
                RoundedRectangle(cornerRadius: 2)
                    .fill(p.color)
                    .frame(width: 8, height: 14)
                    .rotationEffect(.degrees(fall ? p.spin : 0))
                    .position(x: p.x * g.size.width, y: fall ? g.size.height + 20 : -20)
                    .opacity(fall ? 0 : 1)
                    .animation(.easeIn(duration: 2.4).delay(p.delay), value: fall)
            }
        }
        .allowsHitTesting(false)
        .onAppear { fall = true }
    }
}
