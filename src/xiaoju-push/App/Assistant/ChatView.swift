import SwiftUI

// 对话框：所有功能都在这里。上面是对话（工具卡片、确认卡片、文件列表），下面是快捷按钮和输入栏。
// 样子照 Claude App：深暖灰底，自己的话在右边灰色气泡里，回答直接是正文，底部胶囊输入栏。

struct ChatView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var model = ChatModel.shared
    @StateObject private var speech = SpeechInput()
    @State private var input = ""
    @State private var showCopy = false
    @State private var showWorkspace = false
    @FocusState private var focused: Bool

    private var mapping: Mapping? { model.currentTask }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.items.isEmpty { welcome }
                    ForEach(model.items) { it in
                        row(it).id(it.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.items.count) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { taskSwitcher }
            if let m = mapping {
                ToolbarItem(placement: .topBarTrailing) {
                    if m.workspace {
                        Button { Haptics.tap(); showWorkspace = true } label: { Image(systemName: "folder") }
                            .accessibilityLabel("工作区")
                    } else {
                        NavigationLink { PushView(mapping: m) } label: { Image(systemName: "list.bullet.rectangle") }
                            .accessibilityLabel("推送页面")
                    }
                }
            }
        }
        .navigationDestination(item: $model.pickMapping) { m in PushView(mapping: m) }
        .sheet(isPresented: $showCopy) {
            if let m = mapping { CopyOutView(mapping: m) }
        }
        .sheet(isPresented: $showWorkspace) {
            if let m = mapping { WorkspaceView(mapping: m) }
        }
        .onAppear { model.start() }
        .onDisappear { model.leave() }
        .onChange(of: speech.text) { if speech.recording || speech.finishing { input = speech.text } }
    }

    /// 标题：编码助手 + 当前任务，点开换任务
    private var taskSwitcher: some View {
        Menu {
            ForEach(store.mappings) { m in
                Button {
                    Haptics.select()
                    model.focus(m)
                } label: {
                    if m.id == mapping?.id { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                }
            }
        } label: {
            VStack(spacing: 1) {
                Text("编码助手").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                HStack(spacing: 3) {
                    Text(mapping?.title ?? "选个任务").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("说一句话，或者粘贴代码").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Text("比如「推送」「这次改了什么」「找一下 PushEngine」「帮我看看有没有 bug」。从 DeepSeek 等 AI 复制来的代码直接粘贴进来，会自动整理成文件。点 + 可以把文件复制给 AI。会改东西的都会先问你。")
                .font(.system(size: 15)).foregroundStyle(Theme.muted).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: 每一条

    @ViewBuilder private func row(_ it: ChatItem) -> some View {
        switch it.kind {
        case .user(let s): UserBubble(text: s)
        case .pasted(let s): PastedBubble(text: s)
        case .paste(let p): PasteCard(draft: p, itemID: it.id, model: model)
        case .understood(let s, let src):
            UnderstoodChip(text: s, source: src, wrong: model.fixable[it.id] == nil ? nil : { model.wrong(it.id) })
        case .thinking(let s): ThinkingRow(text: s)
        case .tool(let t): ToolCardView(card: t)
        case .shell(let c):
            ShellCardView(card: c, approve: { model.shellApprove(it.id) }, reject: { model.shellReject(it.id) },
                          stop: { ShellRunner.shared.stop() })
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
            .foregroundStyle(Theme.orangeText)
        }
    }

    // MARK: 底部

    private var chips: [(String, String)] {
        mapping != nil
            ? [("检查改动", "检查一下有什么改动"), ("推送", "推送"), ("推送记录", "推送记录"), ("所有任务", "所有任务")]
            : [("所有任务", "所有任务"), ("找文件", "找一下"), ("记住…", "记住")]
    }

    private var hasText: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if !focused && !model.busy {
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
                                Text(c.0).font(.system(size: 13))
                                    .padding(.horizontal, 12).frame(height: 32)
                                    .foregroundStyle(Theme.muted)
                                    .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .transition(.opacity)
            }
            inputBar.padding(.horizontal, 12)
        }
        .padding(.top, 6).padding(.bottom, 8)
        .background(Theme.bg)
        .animation(.easeOut(duration: 0.2), value: focused)
    }

    /// 胶囊输入栏：+ 菜单 · 输入框 · 麦克风（按住说话）· 发送 / 停止
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button { pasteClipboard() } label: { Label("粘贴剪贴板里的代码", systemImage: "doc.on.clipboard") }
                Button { showCopy = true } label: { Label("复制文件给 AI…", systemImage: "doc.on.doc") }
                    .disabled(mapping == nil)
                if mapping?.workspace == true {
                    Button { showWorkspace = true } label: { Label("工作区", systemImage: "folder") }
                }
            } label: {
                circle(icon: "plus", fill: Theme.raised, fg: Theme.text)
            }
            .accessibilityLabel("更多")

            TextField(speech.recording ? "在听…" : "输入或点麦克风说话", text: $input, axis: .vertical)
                .font(.system(size: 17))
                .lineLimit(1...6)
                .focused($focused)
                .foregroundStyle(Theme.text)
                .padding(.vertical, 11)
                .frame(minHeight: 44)

            if !hasText || speech.recording {
                Button {
                    if speech.recording { Haptics.tap(); speech.stop() }
                    else { Haptics.medium(); input = ""; speech.start() }
                } label: {
                    circle(icon: speech.recording ? "waveform" : "mic", fill: speech.recording ? Theme.orange : Theme.raised,
                           fg: speech.recording ? Theme.onAccent : Theme.text)
                        .symbolEffect(.variableColor.iterative, isActive: speech.recording)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(speech.recording ? "停止录音" : "说话")
            }

            Button {
                if model.busy { Haptics.medium(); model.stop() } else { sendInput() }
            } label: {
                if model.busy {
                    circle(icon: "stop.fill", fill: Theme.text, fg: Theme.bg, size: 13)
                } else {
                    circle(icon: "arrow.up", fill: hasText ? Theme.orange : Theme.orangeDim,
                           fg: hasText ? Theme.onAccent : Theme.muted, weight: .bold)
                }
            }
            .buttonStyle(PressStyle())
            .disabled(!model.busy && !hasText)
            .accessibilityLabel(model.busy ? "停止" : "发送")
        }
        .padding(7)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 29, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 29, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .overlay(alignment: .top) {
            if !speech.error.isEmpty {
                Text(speech.error).font(.system(size: 12)).foregroundStyle(Theme.redText)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.card, in: Capsule())
                    .offset(y: -30)
            }
        }
    }

    private func circle(icon: String, fill: Color, fg: Color, size: CGFloat = 17, weight: Font.Weight = .regular) -> some View {
        Image(systemName: icon).font(.system(size: size, weight: weight))
            .foregroundStyle(fg)
            .frame(width: 44, height: 44)
            .background(fill, in: Circle())
    }

    private func pasteClipboard() {
        guard let s = UIPasteboard.general.string, !s.isEmpty else { return }
        model.send(s)
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
            Text(text).font(.system(size: 16)).foregroundStyle(Theme.text)
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// 粘贴进来的一大段代码：只显示前几行
private struct PastedBubble: View {
    let text: String
    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }
    private var blocks: Int { max(1, text.components(separatedBy: "```").count / 2) }
    var body: some View {
        HStack {
            Spacer(minLength: 50)
            VStack(alignment: .leading, spacing: 8) {
                Label("粘贴的内容 · \(lines.count) 行 · \(blocks) 段代码", systemImage: "doc.on.clipboard")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text(lines.prefix(4).joined(separator: "\n") + (lines.count > 4 ? "\n… 还有 \(lines.count - 4) 行" : ""))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text.opacity(0.8))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(12)
            .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// 粘贴的代码整理成的文件：每个文件一行（路径能改），下面「放进工作区」「放好并推送」
private struct PasteCard: View {
    let draft: PasteDraft
    let itemID: UUID
    @ObservedObject var model: ChatModel
    @State private var editing: FileDraft?
    @State private var newPath = ""

    private var ready: Bool { draft.files.contains { !$0.path.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.files.isEmpty ? "没有要放的文件。" : "认出 \(draft.files.count) 个文件，放进 \(draft.task.title)：")
                .font(.system(size: 16)).foregroundStyle(Theme.text)
            VStack(spacing: 0) {
                ForEach(Array(draft.files.enumerated()), id: \.element.id) { i, f in
                    Button {
                        guard draft.status == nil else { return }
                        newPath = f.path
                        editing = f
                    } label: {
                        HStack(spacing: 10) {
                            Text(f.path.isEmpty ? "?" : (f.isNew ? "新" : "改"))
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .foregroundStyle(f.path.isEmpty ? Theme.redText : (f.isNew ? Theme.greenText : Theme.yellow))
                                .background(f.path.isEmpty ? Theme.redSoft : (f.isNew ? Theme.greenSoft : Theme.yellowSoft),
                                            in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.path.isEmpty ? "点这里填路径" : (f.path as NSString).lastPathComponent)
                                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(f.path.isEmpty ? f.how : ((f.path as NSString).deletingLastPathComponent + " · " + f.how))
                                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 4)
                            if !f.path.isEmpty {
                                Text("+\(f.added)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.green)
                                if f.removed > 0 {
                                    Text("−\(f.removed)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.red)
                                }
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .rowDivider(i < draft.files.count - 1)
                    }
                    .buttonStyle(PressStyle())
                    .contextMenu {
                        Button(role: .destructive) { model.pasteDrop(itemID, file: f.id) } label: { Label("不要这个", systemImage: "trash") }
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.border, lineWidth: 1))

            if let s = draft.status {
                Text(s).font(.system(size: 13, weight: .semibold)).foregroundStyle(s.hasPrefix("✓") ? Theme.green : Theme.muted)
            } else {
                HStack(spacing: 8) {
                    Button { Haptics.medium(); model.pasteSave(itemID, andPush: false) } label: {
                        Text(draft.task.workspace ? "放进工作区" : "放进云盘")
                            .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(Theme.onAccent)
                            .background(Theme.orange, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Button { Haptics.medium(); model.pasteSave(itemID, andPush: true) } label: {
                        Text("放好并推送")
                            .font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(Theme.text)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    }
                }
                .buttonStyle(PressStyle())
                .disabled(!ready)
                HStack {
                    Text("点文件改路径，长按不要它。").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    Spacer()
                    Button("算了") { model.pasteCancel(itemID) }.font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
        }
        .alert("放到哪", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("比如 App/Theme.swift", text: $newPath)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("好") {
                if let f = editing { model.pasteEdit(itemID, file: f.id, path: newPath) }
                editing = nil
            }
            Button("取消", role: .cancel) { editing = nil }
        } message: {
            Text("相对 \(draft.task.title) 的路径")
        }
    }
}

private struct UnderstoodChip: View {
    let text: String
    let source: String
    /// 本地模型理解的才有：点了纠正，记进纠错本
    var wrong: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.orange)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(2)
            Text("· \(source)").font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
            if let wrong {
                Spacer(minLength: 4)
                Button(action: wrong) {
                    Text("不对").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.orangeText)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Theme.orangeSoft, in: Capsule())
                        .overlay(Capsule().stroke(Theme.orange.opacity(0.6), lineWidth: 1))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("理解得不对，纠正一下")
            }
        }
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
    private var accent: Color { card.cloud ? Theme.orangeText : Theme.muted }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: card.icon).font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(accent)
                    .background(Theme.raised,
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
                    .lineLimit(card.icon == "terminal" ? 14 : 6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if let p = card.progress, card.state == .busy {
                ProgressView(value: min(max(p, 0), 1)).tint(card.cloud ? accent : Theme.orange)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
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
        Text(Self.rich(text)).font(.system(size: 16)).foregroundStyle(Theme.text)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    /// **加粗**、`代码`、[链接]() 这些显示成样式，不露出星号；换行原样保留
    static func rich(_ s: String) -> AttributedString {
        var t = s
        // 「### 标题」去掉井号
        t = t.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line)
            while l.hasPrefix("#") { l.removeFirst() }
            return l == String(line) ? l : l.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
        let opt = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: t, options: opt)) ?? AttributedString(s)
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
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
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
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
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
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.border, lineWidth: 1))
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
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 8)
                .foregroundStyle(fg(b.style))
                .background(bg(b.style), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(b.style == .plain ? Theme.border : .clear, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
    }

    private func bg(_ s: CardButton.Style) -> Color {
        switch s {
        case .push, .primary, .cloud: return Theme.orange
        case .plain: return Theme.raised
        }
    }

    private func fg(_ s: CardButton.Style) -> Color {
        switch s {
        case .push, .primary, .cloud: return Theme.onAccent
        case .plain: return Theme.text
        }
    }
}
