import SwiftUI

// 代码对比（一个个文件翻看）和推送记录。

// MARK: 代码对比

struct DiffPager: View {
    let changes: [Change]
    @State var index: Int

    private var safeIndex: Int {
        guard !changes.isEmpty else { return 0 }
        return min(max(index, 0), changes.count - 1)
    }

    private var current: Change? {
        changes.isEmpty ? nil : changes[safeIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            chips
            if let c = current {
                DiffFilePage(change: c)
                    .id(c.repoPath)
                    .transition(.opacity)
            } else {
                Spacer()
                Text("没有改动的文件").foregroundStyle(Theme.muted)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("代码对比")
        .navigationBarTitleDisplayMode(.inline)
    }

    // 顶部文件名小标签
    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(changes.enumerated()), id: \.element.id) { pair in
                        chip(pair.element, at: pair.offset)
                            .id(pair.offset)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onAppear { proxy.scrollTo(safeIndex, anchor: .center) }
            .onChange(of: index) { _, newValue in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Theme.divider.frame(height: 1) }
    }

    private func chip(_ c: Change, at i: Int) -> some View {
        let on = i == safeIndex
        let name = (c.repoPath as NSString).lastPathComponent
        return Button {
            guard i != safeIndex else { return }
            Haptics.select()
            go(to: i)
        } label: {
            Text(name)
                .font(.system(size: 13, weight: on ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(on ? Theme.blueText : Theme.muted)
                .background(on ? Theme.blueSoft : Theme.card, in: Capsule())
                .overlay(Capsule().stroke(on ? Theme.blueFill : Theme.border, lineWidth: 1))
        }
        .buttonStyle(PressStyle(scale: 0.92))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.select()
                go(to: safeIndex - 1)
            } label: {
                Label("上一个文件", systemImage: "chevron.left")
            }
            .buttonStyle(BigButtonStyle(kind: .plain))
            .disabled(safeIndex <= 0)

            Button {
                Haptics.select()
                go(to: safeIndex + 1)
            } label: {
                HStack(spacing: 6) {
                    Text("下一个文件")
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(BigButtonStyle(kind: .plain))
            .disabled(safeIndex >= changes.count - 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.bg)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
    }

    private func go(to i: Int) {
        guard !changes.isEmpty else { return }
        let target = min(max(i, 0), changes.count - 1)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            index = target
        }
    }
}

/// 一个文件的对比页
private struct DiffFilePage: View {
    let change: Change

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let note = change.diff.note {
                noteView(note)
            }
            if !change.diff.lines.isEmpty {
                DiffBody(lines: change.diff.lines)
                    .card()
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(change.repoPath)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            Text("+\(change.diff.added)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.green)
            Text("−\(change.diff.removed)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.red)
            KindTag(isNew: change.isNew)
        }
        .padding(.horizontal, 16)
    }

    private func noteView(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(note).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
    }
}

/// 可上下左右滑的代码行
private struct DiffBody: View {
    let lines: [DiffLine]

    private static let numWidth: CGFloat = 34
    private static let signWidth: CGFloat = 16
    private static let charWidth: CGFloat = 7.3

    /// 按最长一行估算宽度，让每行底色一样长
    private var contentWidth: CGFloat {
        var longest = 0
        for l in lines where l.kind != .gap {
            let n = l.text.count
            if n > longest { longest = n }
        }
        return Self.numWidth * 2 + Self.signWidth + 16 + CGFloat(longest) * Self.charWidth
    }

    var body: some View {
        GeometryReader { geo in
            let width: CGFloat = max(geo.size.width, contentWidth)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        DiffRow(line: line, width: width, visibleWidth: geo.size.width)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private struct DiffRow: View {
    let line: DiffLine
    let width: CGFloat
    let visibleWidth: CGFloat

    var body: some View {
        if line.kind == .gap {
            gapRow
        } else {
            codeRow
        }
    }

    private var gapRow: some View {
        HStack(spacing: 0) {
            Text("⋯ 中间没改动的代码省略了")
                .font(.system(size: 12))
                .foregroundStyle(Theme.blueText)
                .padding(.horizontal, 12)
                .frame(width: visibleWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .frame(minWidth: width, alignment: .leading)
        .background(Theme.blueSoft)
    }

    private var codeRow: some View {
        HStack(spacing: 0) {
            number(line.oldNo)
            number(line.newNo)
            Text(sign)
                .font(Theme.mono)
                .foregroundStyle(fg)
                .frame(width: 16, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(Theme.mono)
                .foregroundStyle(fg)
                .fixedSize()
                .padding(.trailing, 16)
        }
        .padding(.vertical, 1)
        .frame(minWidth: width, alignment: .leading)
        .background(bg)
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map { String($0) } ?? "")
            .font(Theme.mono)
            .foregroundStyle(Theme.faint)
            .lineLimit(1)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 0)
    }

    private var sign: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        case .same, .gap: return " "
        }
    }

    private var fg: Color {
        switch line.kind {
        case .added: return Theme.greenText
        case .removed: return Theme.redText
        case .same: return Theme.text
        case .gap: return Theme.blueText
        }
    }

    private var bg: Color {
        switch line.kind {
        case .added: return Theme.greenSoft
        case .removed: return Theme.redSoft
        case .same: return Color.clear
        case .gap: return Theme.blueSoft
        }
    }
}

// MARK: 推送记录

struct HistoryView: View {
    let mapping: Mapping
    @EnvironmentObject var store: Store
    @State private var expanded: UUID?

    private struct DayGroup: Identifiable {
        let day: Date
        let entries: [HistoryEntry]
        var id: Date { day }
    }

    private var groups: [DayGroup] {
        let cal = Calendar.current
        let all: [HistoryEntry] = store.history(for: mapping).sorted { $0.date > $1.date }
        var result: [DayGroup] = []
        var currentDay: Date?
        var bucket: [HistoryEntry] = []
        for e in all {
            let d = cal.startOfDay(for: e.date)
            if let c = currentDay, c != d {
                result.append(DayGroup(day: c, entries: bucket))
                bucket = []
            }
            currentDay = d
            bucket.append(e)
        }
        if let c = currentDay, !bucket.isEmpty {
            result.append(DayGroup(day: c, entries: bucket))
        }
        return result
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            .navigationTitle("推送记录 · \(mapping.title)")
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        let gs = groups
        if gs.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(gs) { g in
                        section(g)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Theme.faint)
            Text("还没有推送记录")
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
        }
    }

    private func section(_ g: DayGroup) -> some View {
        VStack(spacing: 0) {
            SectionTitle(Self.dayTitle(g.day))
            VStack(spacing: 0) {
                ForEach(Array(g.entries.enumerated()), id: \.element.id) { pair in
                    HistoryRow(entry: pair.element,
                               isOpen: expanded == pair.element.id,
                               last: pair.offset == g.entries.count - 1) {
                        Haptics.tap()
                        let id = pair.element.id
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            expanded = expanded == id ? nil : id
                        }
                    }
                }
            }
            .card()
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "今天" }
        if cal.isDateInYesterday(day) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        let sameYear = cal.component(.year, from: day) == cal.component(.year, from: Date())
        f.dateFormat = sameYear ? "M月d日" : "yyyy年M月d日"
        return f.string(from: day)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let isOpen: Bool
    let last: Bool
    let onTap: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) { summary }
                .buttonStyle(PressStyle(scale: 0.98))
            if isOpen {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .rowDivider(!last)
    }

    private var metaLine: String {
        let time = Self.timeFormatter.string(from: entry.date)
        return "+\(entry.added) −\(entry.removed) · \(entry.files.count) 个文件 · \(time)"
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(entry.sha.prefix(7)))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.blueText)
                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(metaLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                if !entry.branch.isEmpty {
                    Pill(text: entry.branch, mono: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.faint)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entry.files, id: \.self) { f in
                    Text(f)
                        .font(Theme.mono)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if let url = URL(string: entry.url), !entry.url.isEmpty {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                        Text("在 GitHub 查看")
                    }
                }
                .buttonStyle(BigButtonStyle(kind: .plain))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
