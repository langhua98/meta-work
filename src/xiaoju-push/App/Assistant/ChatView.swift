import SwiftUI

// 对话框：所有功能都在这里。上面是对话（工具卡片、确认卡片、文件列表），下面是快捷按钮和输入框。

struct ChatView: View {
    @EnvironmentObject var store: Store
    @StateObject private var model: ChatModel
    @State private var input = ""
    @FocusState private var focused: Bool
    let mapping: Mapping?

    init(mapping: Mapping?) {
        self.mapping = mapping
        _model = StateObject(wrappedValue: ChatModel(store: Store.shared, mapping: mapping))
    }

    private var title: String {
        guard let m = mapping else { return "编码助手" }
        return m.repo.split(separator: "/").last.map(String.init) ?? m.title
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.items.isEmpty { welcome }
                    ForEach(model.items) { it in
                        row(it).id(it.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.items.count) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let m = mapping {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { PushView(mapping: m) } label: { Image(systemName: "list.bullet.rectangle") }
                        .accessibilityLabel("原来的推送页面")
                }
            }
        }
        .navigationDestination(item: $model.pickMapping) { m in PushView(mapping: m) }
        .onAppear { model.start() }
        .onDisappear { model.leave() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("说一句话就行").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Text("比如「推送 \(TaskRef.list(store.mappings).first?.name ?? "meta-work")」「这次改了什么」「找一下 PushEngine」「帮我看看这次改动有没有 bug」「记住提交说明用中文」。会改东西的都会先问你。")
                .font(.system(size: 14)).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    // MARK: 每一条

    @ViewBuilder private func row(_ it: ChatItem) -> some View {
        switch it.kind {
        case .user(let s): UserBubble(text: s)
        case .understood(let s, let src): UnderstoodChip(text: s, source: src)
        case .thinking(let s): ThinkingRow(text: s)
        case .tool(let t): ToolCardView(card: t)
        case .text(let s): AnswerText(text: s)
        case .changes(let p): ChangesCard(plan: p)
        case .entries(let title, let items): EntriesCard(title: title, items: items)
        case .card(let c): ActionCardView(card: c)
        case .error(let s): ErrorRow(text: s)
        case .work(let w): WorkLogView(log: w)
        case .attachment(let a): AttachmentCard(item: a, saveToCloud: { try await model.saveToCloud($0) })
        case .link(let s, let u):
            Link(destination: u) {
                Label(s, systemImage: "arrow.up.right.square").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Theme.blueText)
        }
    }

    // MARK: 底部

    private var chips: [(String, String)] {
        mapping != nil
            ? [("检查改动", "检查一下有什么改动"), ("推送", "推送"), ("推送记录", "推送记录"), ("所有任务", "所有任务")]
            : [("所有任务", "所有任务"), ("找文件", "找一下"), ("记住…", "记住")]
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.0) { c in
                        Button {
                            if c.1 == "找一下" || c.1 == "记住" {
                                input = c.1 + " "
                                focused = true
                            } else {
                                model.send(c.1)
                            }
                        } label: {
                            Text(c.0).font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .foregroundStyle(Theme.text)
                                .background(Theme.raised, in: Capsule())
                                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                        }
                        .buttonStyle(PressStyle())
                        .disabled(model.busy)
                    }
                }
                .padding(.horizontal, 14)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("说点什么…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(sendInput)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.border, lineWidth: 1))
                Button {
                    if model.busy { Haptics.medium(); model.stop() } else { sendInput() }
                } label: {
                    Image(systemName: model.busy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(model.busy ? Theme.text : Color.black)
                        .frame(width: 38, height: 38)
                        .background(model.busy ? Theme.raised : Theme.orange, in: Circle())
                        .overlay(Circle().stroke(model.busy ? Theme.border : .clear, lineWidth: 1))
                }
                .buttonStyle(PressStyle(scale: 0.9))
                .disabled(!model.busy && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(model.busy ? "停止" : "发送")
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 8).padding(.bottom, 6)
        .background(.bar)
    }

    private func sendInput() {
        let t = input
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.busy else { return }
        input = ""
        model.send(t)
    }
}

// MARK: 小部件

private struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 50)
            Text(text).font(.system(size: 15)).foregroundStyle(Theme.text)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.blueSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct UnderstoodChip: View {
    let text: String
    let source: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
            Text("听懂了：\(text)").font(.system(size: 12, weight: .semibold)).lineLimit(2)
            Text("· \(source)").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .foregroundStyle(Theme.orangeText)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.orangeSoft, in: Capsule())
    }
}

/// 「在想」：文字上一道光扫过
private struct ThinkingRow: View {
    let text: String
    @State private var phase: CGFloat = -1
    var body: some View {
        Text(text + "…").font(.system(size: 14)).foregroundStyle(Theme.muted)
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Theme.text.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.5)
                        .offset(x: phase * g.size.width)
                }
                .mask(Text(text + "…").font(.system(size: 14)))
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.5 }
            }
            .padding(.vertical, 2)
    }
}

private struct ToolCardView: View {
    let card: ToolCard
    private var accent: Color { card.cloud ? Color(dark: 0xbc8cff, light: 0x8250df) : Theme.blueText }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: card.icon).font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(accent)
                    .background(card.cloud ? Color(dark: 0x271f3a, light: 0xfbefff) : Theme.raised,
                                in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(card.sub).font(.system(size: 12, design: card.cloud ? .monospaced : .default)).foregroundStyle(Theme.muted).lineLimit(2)
                }
                Spacer(minLength: 4)
                stateIcon
            }
            if let d = card.detail, !d.isEmpty {
                Text(d).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if let p = card.progress, card.state == .busy {
                ProgressView(value: min(max(p, 0), 1)).tint(card.cloud ? accent : Theme.orange)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .animation(.spring(response: 0.3), value: card)
    }

    @ViewBuilder private var stateIcon: some View {
        switch card.state {
        case .busy: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).transition(.scale)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red).transition(.scale)
        }
    }
}

private struct AnswerText: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 15)).foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }
}

private struct ErrorRow: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.redText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.redSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 要推的文件，点一个看代码对比
private struct ChangesCard: View {
    let plan: Plan
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(plan.changes.prefix(8).enumerated()), id: \.element.id) { i, c in
                NavigationLink { DiffPager(changes: plan.changes, index: i) } label: {
                    HStack(spacing: 10) {
                        KindTag(isNew: c.isNew)
                        Text(c.repoPath).font(Theme.mono).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if c.diff.note == nil {
                            Text("+\(c.diff.added)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.green)
                            Text("−\(c.diff.removed)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.red)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .rowDivider(i < min(plan.changes.count, 8) - 1)
                }
                .buttonStyle(PressStyle())
            }
            if plan.changes.count > 8 {
                NavigationLink { DiffPager(changes: plan.changes, index: 8) } label: {
                    Text("还有 \(plan.changes.count - 8) 个文件…").font(.system(size: 13)).foregroundStyle(Theme.blueText)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

private struct EntriesCard: View {
    let title: String
    let items: [CloudEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 4)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                HStack(spacing: 10) {
                    Image(systemName: e.isFolder ? "folder.fill" : "doc.text")
                        .foregroundStyle(e.isFolder ? Theme.blueText : Theme.muted)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.name).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(e.fullPath).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if let s = e.size, !e.isFolder {
                        Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                            .font(.system(size: 11)).foregroundStyle(Theme.faint)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .rowDivider(i < items.count - 1)
                .contextMenu {
                    Button { UIPasteboard.general.string = e.fullPath } label: { Label("复制路径", systemImage: "doc.on.doc") }
                }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

private struct ActionCardView: View {
    let card: ActionCard

    private var accent: Color {
        switch card.tone {
        case .push: return Theme.green
        case .primary: return Theme.orange
        case .cloud: return Color(dark: 0xbc8cff, light: 0x8250df)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            ForEach(Array(card.lines.enumerated()), id: \.offset) { _, l in
                Text(l).font(.system(size: 13)).foregroundStyle(l.hasPrefix("⚠︎") ? Theme.yellow : Theme.muted)
            }
            if let n = card.note {
                Text(n).font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            if let s = card.status {
                Text(s).font(.system(size: 13, weight: .semibold)).foregroundStyle(s.hasPrefix("✓") ? Theme.green : Theme.muted)
                    .transition(.opacity)
            } else if !card.buttons.isEmpty {
                buttons
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3).padding(.vertical, 10)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .animation(.spring(response: 0.3), value: card.status)
    }

    @ViewBuilder private var buttons: some View {
        // 选项多（「是哪一个？」）就竖着排
        if card.buttons.count > 3 || card.buttons.contains(where: { $0.label.count > 8 }) {
            VStack(spacing: 6) { ForEach(card.buttons) { button($0) } }
        } else {
            HStack(spacing: 8) { ForEach(card.buttons) { button($0) } }
        }
    }

    private func button(_ b: CardButton) -> some View {
        Button { Haptics.tap(); b.run() } label: {
            Text(b.label).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 36)
                .padding(.horizontal, 8)
                .foregroundStyle(fg(b.style))
                .background(bg(b.style), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(b.style == .plain ? Theme.border : .clear, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
    }

    private func bg(_ s: CardButton.Style) -> Color {
        switch s {
        case .push: return Theme.greenFill
        case .primary: return Theme.orange
        case .cloud: return Color(dark: 0x8957e5, light: 0x8250df)
        case .plain: return Theme.raised
        }
    }

    private func fg(_ s: CardButton.Style) -> Color {
        switch s {
        case .push, .cloud: return .white
        case .primary: return .black
        case .plain: return Theme.text
        }
    }
}
