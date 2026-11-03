import SwiftUI

// 一个任务：检查改动 → 勾选要推的文件（可搜索、筛选）→ 看代码改动 → 风险提醒 → 写提交说明 → 推送。
// 推送时全屏显示三步进度，成功有对勾和彩纸，失败用大白话说原因。
struct PushView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let mapping: Mapping

    @State private var plan: Plan?
    @State private var status = ""
    @State private var error = ""
    @State private var checking = false
    @State private var message = ""
    @State private var selected: Set<String> = []
    @State private var job: Task<Void, Never>?
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var risks: [Risk] = []
    @State private var confirmRisk = false
    @State private var phase: PushPhase = .idle
    @State private var showPhase = false
    @AppStorage("templateIndex") private var templateIndex = 0

    enum Filter: String, CaseIterable { case all = "全部", new = "新增", modified = "修改" }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                info
                if checking { checkingCard }
                if !error.isEmpty { errorCard }
                if let plan { content(plan) }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .safeAreaInset(edge: .bottom) { if let plan, !plan.changes.isEmpty { bottomBar(plan) } }
        .navigationTitle(mapping.repo.split(separator: "/").last.map(String.init) ?? mapping.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜文件名")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let plan, !plan.changes.isEmpty {
                    Button(allSelected(plan) ? "全不选" : "全选") {
                        Haptics.medium()
                        selected = allSelected(plan) ? [] : Set(plan.changes.map(\.repoPath))
                    }
                } else {
                    Button { Haptics.tap(); check() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(checking).accessibilityLabel("重新检查")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.history(mapping)) { Image(systemName: "clock") }
                    .accessibilityLabel("推送记录")
            }
        }
        .refreshable { Haptics.tap(); check() }
        .task { if plan == nil && !checking { check() } }
        .onChange(of: selected) { if let plan { message = defaultMessage(plan) } }
        .onChange(of: templateIndex) { if let plan { message = defaultMessage(plan) } }
        .onDisappear { if !showPhase { job?.cancel() } }
        .alert("确定要推吗？", isPresented: $confirmRisk) {
            Button("仍然推送", role: .destructive) { if let plan { push(plan) } }
            Button("再看看", role: .cancel) {}
        } message: {
            Text(risks.filter { $0.level == .secret }.map(\.title).joined(separator: "\n") + "\n\n密码和令牌推到 GitHub 上别人可能看到。")
        }
        .fullScreenCover(isPresented: $showPhase) {
            PushPhaseView(phase: phase, repo: mapping.repo,
                          onCancel: { job?.cancel() },
                          onRetry: { if let plan { push(plan) } },
                          onBack: { showPhase = false; phase = .idle },
                          onHome: { showPhase = false; phase = .idle; dismiss() })
        }
    }

    // MARK: 各块

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(Theme.blue)
                Text(mapping.sourceLabel).foregroundStyle(Theme.text).lineLimit(1)
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(Theme.muted)
                Text(mapping.repo).foregroundStyle(Theme.text).lineLimit(1)
                Pill(text: plan?.branch ?? (mapping.branch.isEmpty ? "默认分支" : mapping.branch), mono: true)
                if !mapping.repoPath.isEmpty { Text("/\(mapping.repoPath)").foregroundStyle(Theme.muted).lineLimit(1) }
            }
            if !mapping.excludedPaths.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "nosign").foregroundStyle(Theme.redText)
                    Text("不推：" + mapping.excludedPaths.joined(separator: "、")).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
        .padding(.top, 12)
    }

    private var checkingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(status).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(2)
            Spacer()
            Button("取消") { Haptics.tap(); job?.cancel() }.foregroundStyle(Theme.redText)
        }
        .padding(14).card().padding(.top, 12)
    }

    private var errorCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(PushPhaseView.friendly(error).title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.redText)
            Text(PushPhaseView.friendly(error).advice).font(.system(size: 13)).foregroundStyle(Theme.muted)
            Text(error).font(Theme.mono).foregroundStyle(Theme.faint).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.redSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16).padding(.top, 12)
    }

    @ViewBuilder
    private func content(_ plan: Plan) -> some View {
        if plan.changes.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Theme.green)
                Text("没有改动").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                Text("和 GitHub 上一样（\(plan.unchanged) 个文件）").font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            let chosen = plan.changes.filter { selected.contains($0.repoPath) }
            HStack(spacing: 10) {
                Text("已选 \(chosen.count) / \(plan.changes.count) 个").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text).contentTransition(.numericText())
                Text("+\(chosen.reduce(0) { $0 + $1.diff.added })").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.green)
                Text("−\(chosen.reduce(0) { $0 + $1.diff.removed })").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.red)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
            .animation(.spring, value: chosen.count)

            Picker("筛选", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.bottom, 10)
            .onChange(of: filter) { Haptics.select() }

            if !risks.isEmpty { riskCard }

            let shown = visible(plan)
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
                    row(c, plan: plan).rowDivider(i < shown.count - 1)
                }
                if shown.isEmpty {
                    Text("没有符合的文件").font(.system(size: 14)).foregroundStyle(Theme.muted).padding(20)
                }
            }
            .card()

            HStack(spacing: 14) {
                legend("A", "新增", Theme.green)
                legend("M", "修改", Theme.yellow)
                Spacer()
                Text("另有 \(plan.unchanged) 个没变").foregroundStyle(Theme.muted)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16).padding(.top, 8)
        }
        if !plan.skipped.isEmpty {
            SectionTitle("跳过的文件")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(plan.skipped, id: \.self) { Text($0).font(.system(size: 13)).foregroundStyle(Theme.yellow) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14).card()
        }
    }

    private func legend(_ tag: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Text(tag).bold().foregroundStyle(color); Text(label).foregroundStyle(Theme.muted) }
    }

    private var riskCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("推送前看一下", systemImage: "exclamationmark.shield.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.yellow)
            ForEach(risks) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(r.level == .secret ? Theme.redText : Theme.text)
                    Text(r.detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.yellowSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.yellow.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func row(_ c: Change, plan: Plan) -> some View {
        let on = selected.contains(c.repoPath)
        let index = plan.changes.firstIndex { $0.repoPath == c.repoPath } ?? 0
        return HStack(spacing: 10) {
            Button {
                Haptics.select()
                if on { selected.remove(c.repoPath) } else { selected.insert(c.repoPath) }
            } label: {
                CheckCircle(on: on).frame(width: 44, height: 52)
            }
            .buttonStyle(PressStyle(scale: 0.85))
            .accessibilityLabel(on ? "不推 \(c.repoPath)" : "推 \(c.repoPath)")

            NavigationLink {
                DiffPager(changes: plan.changes, index: index)
            } label: {
                HStack(spacing: 10) {
                    KindTag(isNew: c.isNew)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((c.repoPath as NSString).lastPathComponent)
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        Text((c.repoPath as NSString).deletingLastPathComponent)
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    if c.diff.added + c.diff.removed > 0 {
                        Text("+\(c.diff.added)").foregroundStyle(Theme.green)
                        Text("−\(c.diff.removed)").foregroundStyle(Theme.red)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.faint)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.trailing, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
        }
        .opacity(on ? 1 : 0.6)
        .animation(.easeOut(duration: 0.15), value: on)
    }

    private func bottomBar(_ plan: Plan) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("提交说明").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Menu {
                    ForEach(Array(store.templates.enumerated()), id: \.offset) { i, t in
                        Button { Haptics.select(); templateIndex = i } label: {
                            if i == templateIndex { Label(t, systemImage: "checkmark") } else { Text(t) }
                        }
                    }
                } label: {
                    Label("模板", systemImage: "text.badge.star").font(.system(size: 13))
                }
            }
            TextField("写一句这次改了什么", text: $message, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 15))
                .padding(10)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            Button {
                Haptics.heavy()
                if risks.contains(where: { $0.level == .secret }) {
                    Haptics.warning()
                    confirmRisk = true
                } else {
                    push(plan)
                }
            } label: {
                Label(selected.isEmpty ? "先勾选要推的文件" : "推送 \(selected.count) 个文件", systemImage: "arrow.up")
                    .contentTransition(.numericText())
            }
            .buttonStyle(BigButtonStyle(kind: .push))
            .disabled(selected.isEmpty || checking || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
    }

    // MARK: 逻辑

    private func allSelected(_ plan: Plan) -> Bool { selected.count == plan.changes.count }

    private func visible(_ plan: Plan) -> [Change] {
        plan.changes.filter { c in
            (filter == .all || (filter == .new) == c.isNew)
                && (query.isEmpty || c.repoPath.localizedCaseInsensitiveContains(query))
        }
    }

    private func check() {
        guard store.ready else { error = "先在设置里填好两个令牌"; return }
        job?.cancel()
        checking = true
        error = ""
        status = "检查改动…"
        let engine = store.engine()
        let pushed = store.pushed
        job = Task {
            do {
                let p = try await engine.plan(mapping, pushed: pushed) { s in Task { @MainActor in status = s } }
                store.record(p.confirmed)
                store.setPending(mapping, p.changes.count)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    plan = p
                    selected = Set(p.changes.map(\.repoPath))
                    risks = Risk.scan(p.changes)
                }
                message = defaultMessage(p)
                if !risks.isEmpty { Haptics.warning() } else { Haptics.tap() }
            } catch {
                self.error = error.localizedDescription
                if !error.localizedDescription.contains("已取消") { Haptics.error() }
            }
            checking = false
        }
    }

    private func push(_ plan: Plan) {
        let engine = store.engine()
        let msg = message
        let chosen = Plan(repo: plan.repo, branch: plan.branch, head: plan.head,
                          changes: plan.changes.filter { selected.contains($0.repoPath) },
                          unchanged: plan.unchanged, skipped: plan.skipped, confirmed: [:])
        phase = .pushing(step: 0, detail: "准备上传 \(chosen.changes.count) 个文件")
        showPhase = true
        job = Task {
            do {
                let r = try await engine.commit(chosen, message: msg) { s in
                    Task { @MainActor in
                        let step = s.hasPrefix("上传") ? 0 : s.hasPrefix("提交") ? 1 : 2
                        if case .pushing(let old, _) = phase, step > old { Haptics.tap() }
                        phase = .pushing(step: step, detail: s)
                    }
                }
                var rec: [String: Pushed] = [:]
                for c in chosen.changes { rec[chosen.recordKey(c.repoPath)] = Pushed(sha256: c.sha256, blob: c.blob) }
                store.record(rec)
                let added = chosen.changes.reduce(0) { $0 + $1.diff.added }
                let removed = chosen.changes.reduce(0) { $0 + $1.diff.removed }
                let title = msg.split(separator: "\n").first.map(String.init) ?? msg
                store.addHistory(HistoryEntry(task: mapping.id, repo: chosen.repo, branch: chosen.branch, sha: r.sha,
                                              url: r.url, title: title, files: chosen.changes.map(\.repoPath),
                                              added: added, removed: removed))
                store.setPending(mapping, plan.changes.count - chosen.changes.count)
                phase = .done(sha: r.sha, url: r.url, title: title, count: chosen.changes.count,
                              added: added, removed: removed, branch: chosen.branch)
                Haptics.celebrate()
                // 推完后重新检查一下（剩下没推的文件还在列表里）
                self.plan = nil
                check()
            } catch {
                phase = .failed(error.localizedDescription)
                Haptics.error()
            }
        }
    }

    private func defaultMessage(_ plan: Plan) -> String {
        let t = store.templates.indices.contains(templateIndex) ? store.templates[templateIndex] : Store.defaultTemplates[0]
        return Self.defaultMessage(plan, only: selected, template: t)
    }

    /// 默认提交说明：第一行用模板（{文件} 换成文件名），下面列出每个文件和加减行数。
    static func defaultMessage(_ plan: Plan, only: Set<String>, template: String = Store.defaultTemplates[0]) -> String {
        let changes = plan.changes.filter { only.contains($0.repoPath) }
        guard !changes.isEmpty else { return "" }
        var names = changes.prefix(3).map { ($0.repoPath as NSString).lastPathComponent }.joined(separator: "、")
        if changes.count > 3 { names += " 等 \(changes.count) 个文件" }
        let title = template.contains("{文件}") ? template.replacingOccurrences(of: "{文件}", with: names) : template + " " + names
        let lines = changes.map { c -> String in
            let kind = c.isNew ? "新增" : "修改"
            let stat = c.diff.note == nil || c.diff.added + c.diff.removed > 0
                ? "（+\(c.diff.added) −\(c.diff.removed)）" : ""
            return "- \(kind) \(c.repoPath)\(stat)"
        }
        return title + "\n\n" + lines.joined(separator: "\n")
    }
}
