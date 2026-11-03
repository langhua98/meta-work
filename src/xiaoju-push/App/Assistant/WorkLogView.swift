import SwiftUI

// OpenCode 干活的过程，做成一块终端：跑的时候滚动显示最新几步，跑完收成一行，点开看全部，点某一步看完整命令和输出。

struct WorkLog {
    var title: String
    var status: String
    var steps: [CloudStep] = []
    var started = Date()
    var finished: Date?
    var failed = false

    var running: Bool { finished == nil }
    var failedSteps: Int { steps.filter(\.failed).count }
}

extension CloudStep {
    enum Kind { case shell, read, write, search, web, skill, other }

    var kind: Kind {
        let n = name.lowercased()
        if n.contains("bash") || n.contains("shell") || n.contains("exec") { return .shell }
        if n.contains("read") || n.contains("view") || n.contains("list") { return .read }
        if n.contains("write") || n.contains("edit") || n.contains("patch") { return .write }
        if n.contains("grep") || n.contains("glob") || n.contains("search") || n.contains("find") { return .search }
        if n.contains("fetch") || n.contains("web") { return .web }
        if n.contains("skill") { return .skill }
        return .other
    }

    /// 一行能看懂的样子：去掉「cd 工作目录 &&」，python -c 长脚本只写「python 脚本」
    var line: String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .shell:
            if let r = s.range(of: #"^cd\s+\S+\s*&&\s*"#, options: .regularExpression) { s.removeSubrange(r) }
            if let r = s.range(of: #"^(/\S*/)?python3?\s+-c\s+"#, options: .regularExpression) {
                let code = s[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "'\" \n"))
                let first = code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty && !$0.hasPrefix("import") && !$0.hasPrefix("from ") && !$0.hasPrefix("#") }
                return "python 脚本" + (first.map { "  · " + $0 } ?? "")
            }
            return s.split(separator: "\n").first.map(String.init) ?? s
        case .read: return "读取 " + s
        case .write: return "写入 " + s
        case .search: return "搜索 " + s
        case .web: return "打开 " + s
        case .skill: return "技能 " + s
        case .other: return (name.isEmpty ? "工具" : name) + (s.isEmpty ? "" : " " + s)
        }
    }

    var prompt: String { kind == .shell ? "$" : "›" }
}

struct WorkLogView: View {
    let log: WorkLog
    @State private var expanded = false
    @State private var open: String?

    private static let term = Color(dark: 0x0a0d12, light: 0x161b22)
    private static let termText = Color(red: 0.86, green: 0.89, blue: 0.93)
    private static let termMuted = Color(red: 0.55, green: 0.59, blue: 0.65)
    private static let purple = Color(dark: 0xbc8cff, light: 0x8250df)

    /// 跑的时候只看最后 3 步；跑完收起，展开看全部
    private var visible: [CloudStep] {
        if log.running { return Array(log.steps.suffix(3)) }
        return expanded ? log.steps : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !visible.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if log.running && log.steps.count > 3 {
                        Text("… 前面还有 \(log.steps.count - 3) 步")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Self.termMuted)
                            .padding(.horizontal, 12).padding(.top, 8)
                    }
                    ForEach(visible, id: \.id) { st in row(st) }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Self.term)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: log.steps.count)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: expanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: log.running)
    }

    private var header: some View {
        Button {
            guard !log.running, !log.steps.isEmpty else { return }
            Haptics.tap()
            expanded.toggle()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color(dark: 0x271f3a, light: 0xfbefff))
                    if log.running { ProgressView().controlSize(.small).tint(Self.purple) }
                    else { Image(systemName: log.failed ? "exclamationmark.triangle.fill" : "terminal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(log.failed ? Theme.red : Self.purple) }
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(log.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(summary(now: ctx.date)).font(.system(size: 12))
                            .foregroundStyle(log.failed ? Theme.redText : Theme.muted).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if !log.running && !log.steps.isEmpty {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func summary(now: Date) -> String {
        let secs = Int((log.finished ?? now).timeIntervalSince(log.started))
        let time = secs >= 60 ? "\(secs / 60) 分 \(secs % 60) 秒" : "\(secs) 秒"
        if log.running {
            return log.steps.isEmpty ? "\(log.status) · \(time)" : "正在运行 · 第 \(log.steps.count) 步 · \(time)"
        }
        if log.failed { return log.status }
        if log.steps.isEmpty { return "完成 · \(time)" }
        let bad = log.failedSteps
        return "运行了 \(log.steps.count) 步" + (bad > 0 ? "，\(bad) 步出错" : "") + " · \(time)"
    }

    private func row(_ st: CloudStep) -> some View {
        let isOpen = open == st.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                Haptics.select()
                open = isOpen ? nil : st.id
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(st)
                    Text(st.prompt).foregroundStyle(Self.purple)
                    Text(st.line).foregroundStyle(st.failed ? Theme.redText : Self.termText)
                        .lineLimit(isOpen ? nil : 1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12, design: .monospaced))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(full(st)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Self.termMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.leading, 16)
                }
            } else if log.running && !st.done && !st.output.isEmpty {
                // 正在跑的那一步，实时显示输出最后两行
                Text(st.tail.split(separator: "\n").suffix(2).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Self.termMuted)
                    .lineLimit(2).padding(.leading, 16)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    @ViewBuilder private func marker(_ st: CloudStep) -> some View {
        if !st.done {
            ProgressView().controlSize(.mini).tint(Self.termMuted).frame(width: 8)
        } else {
            Circle().fill(st.failed ? Theme.red : Self.termMuted.opacity(0.6)).frame(width: 6, height: 6).frame(width: 8)
        }
    }

    /// 展开后：完整命令 + 输出（都打过码）
    private func full(_ st: CloudStep) -> String {
        var s = "\(st.prompt) " + OpenCodeClient.mask(st.input)
        let out = OpenCodeClient.mask(st.output).trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty {
            let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
            s += "\n" + lines.suffix(80).joined(separator: "\n")
            if lines.count > 80 { s += "\n…（只显示最后 80 行）" }
        }
        return s
    }
}
