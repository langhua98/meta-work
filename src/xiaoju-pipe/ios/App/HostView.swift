import Combine
import SwiftUI
import UIKit

/// 在局域网里找从机（Bonjour：_xjpipe._tcp）
final class WorkerFinder: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Found: Identifiable, Hashable { let id: String; let name: String; let host: String; let port: Int; let layers: String; let model: String }
    @Published var found: [Found] = []
    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        browser.searchForServices(ofType: "_xjpipe._tcp.", inDomain: "local.")
    }

    func netServiceBrowser(_ b: NetServiceBrowser, didFind s: NetService, moreComing: Bool) {
        pending.append(s)
        s.delegate = self
        s.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ b: NetServiceBrowser, didRemove s: NetService, moreComing: Bool) {
        found.removeAll { $0.id == s.name }
    }

    func netServiceDidResolveAddress(_ s: NetService) {
        guard let host = s.hostName else { return }
        var layers = "", model = ""
        if let d = s.txtRecordData() {
            let t = NetService.dictionary(fromTXTRecord: d)
            layers = t["layers"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
            model = t["model"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        let f = Found(id: s.name, name: s.name, host: host, port: s.port, layers: layers, model: model)
        found.removeAll { $0.id == f.id }
        found.append(f)
        pending.removeAll { $0 === s }
    }
}

struct ChatLine: Identifiable { let id = UUID(); let user: Bool; var text: String }

final class HostController: ObservableObject {
    @Published var modelID: String { didSet { UserDefaults.standard.set(modelID, forKey: "h.model"); refresh() } }
    @Published var workerIP: String { didSet { UserDefaults.standard.set(workerIP, forKey: "h.ip") } }
    @Published var pin: String { didSet { UserDefaults.standard.set(pin, forKey: "h.pin") } }
    @Published var solo = false
    @Published var ctx = 4096
    @Published var temperature = 0.7

    @Published var connecting = false
    @Published var connected = false
    @Published var info = ""
    @Published var error = ""
    @Published var busy = false
    @Published var chat: [ChatLine] = []
    @Published var stats = ""
    @Published var status = ""          // 从机断线重连时的提示
    @Published var haveModel = false

    let downloader = Downloader()
    let finder = WorkerFinder()
    private var handle: UnsafeMutableRawPointer?
    private var stopFlag = false
    private let queue = DispatchQueue(label: "xiaoju.pipe.host")
    private var bags: [AnyCancellable] = []

    init() {
        let d = UserDefaults.standard
        modelID = d.string(forKey: "h.model") ?? ModelSpec.q9b.id
        workerIP = d.string(forKey: "h.ip") ?? ""
        pin = d.string(forKey: "h.pin") ?? ""
        bags.append(downloader.objectWillChange.sink { [weak self] in self?.objectWillChange.send() })
        bags.append(finder.objectWillChange.sink { [weak self] in self?.objectWillChange.send() })
        refresh()
    }

    var model: ModelSpec { ModelSpec.by(modelID) }

    /// 连接前估一下本机要扛多少权重：全部层减去从机那几层（从 Bonjour 里读，读不到按默认 12–21），
    /// 加输出头。embedding 只按需读用到的行，不算。
    var memoryNote: String? {
        guard let l = ModelLayout.read(Paths.file(for: model)) else { return nil }
        let avail = Double(xjg_free_memory()) / 1048576
        var need = l.mb(0, l.nLayer) + l.outMB
        var how = "单机"
        if !solo {
            var a = 12, b = min(22, l.nLayer)
            if let f = finder.found.first(where: { $0.host == workerIP }) {
                let p = f.layers.split(separator: "-").compactMap { Int($0) }
                if p.count == 2 { a = p[0]; b = p[1] + 1 }
            }
            need -= l.mb(a, b)
            how = "从机算第 \(a)–\(b - 1) 层时"
        }
        var s = "\(how)本机大约要 \(need.mb) 权重"
        if avail > 0 { s += "，现在可用 \(avail.mb)" }
        if avail > 0 && need > avail * 0.9 { s += "。可能不够，让从机多分几层" }
        return s
    }

    func refresh() {
        let f = Paths.file(for: model)
        guard let l = ModelLayout.read(f) else { haveModel = false; return }
        haveModel = Downloader.haveLayers(model, 0, l.nLayer)
    }

    func download() {
        Task {
            await downloader.download(model, layers: nil)
            await MainActor.run { self.refresh() }
        }
    }

    func connect() {
        guard !connecting else { return }
        connecting = true
        error = ""
        let path = Paths.file(for: model).path
        let ip = solo ? "" : workerIP.trimmingCharacters(in: .whitespaces)
        let pin = UInt32(self.pin) ?? 0
        let ctx = Int32(self.ctx)
        queue.async {
            var info = [CChar](repeating: 0, count: 512), err = [CChar](repeating: 0, count: 256)
            let h = xjg_host_new(path, ip, 47321, pin, 0, 0, ctx, &info, Int32(info.count), &err, Int32(err.count))
            let i = cString(info), e = cString(err)
            DispatchQueue.main.async {
                self.connecting = false
                if let h {
                    self.handle = h
                    self.attachStatus(h)
                    self.connected = true
                    self.info = i
                    self.chat = []
                } else {
                    self.error = e
                }
            }
        }
    }

    /// 从机断了核心会自己重连、重放之前的对话，这里只把进度显示出来
    private func attachStatus(_ h: UnsafeMutableRawPointer) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        let fn: xjg_log_fn = { ctx, msg in
            guard let ctx, let msg else { return }
            let c = Unmanaged<HostController>.fromOpaque(ctx).takeUnretainedValue()
            let s = String(cString: msg)
            DispatchQueue.main.async { c.status = s }
        }
        xjg_host_set_status(h, fn, me)
    }

    func disconnect() {
        let h = handle
        handle = nil
        connected = false
        info = ""
        queue.async { if let h { xjg_host_free(h) } }
    }

    func newChat() {
        guard let h = handle, !busy else { return }
        chat = []
        stats = ""
        queue.async {
            var err = [CChar](repeating: 0, count: 256)
            _ = xjg_host_reset(h, &err, Int32(err.count))
        }
    }

    func stop() { stopFlag = true }

    func send(_ text: String) {
        guard let h = handle, !busy, !text.isEmpty else { return }
        busy = true
        stopFlag = false
        status = ""
        error = ""
        chat.append(ChatLine(user: true, text: text))
        chat.append(ChatLine(user: false, text: ""))
        let temp = Float(temperature)
        let me = Unmanaged.passUnretained(self).toOpaque()
        queue.async {
            let cb: xjg_piece_fn = { ctx, s, n in
                guard let ctx, let s else { return 0 }
                let c = Unmanaged<HostController>.fromOpaque(ctx).takeUnretainedValue()
                let piece = String(decoding: UnsafeRawBufferPointer(start: s, count: Int(n)), as: UTF8.self)
                DispatchQueue.main.async {
                    if let last = c.chat.indices.last { c.chat[last].text += piece }
                }
                return c.stopFlag ? 1 : 0
            }
            var st = xjg_stats()
            var err = [CChar](repeating: 0, count: 256)
            let rc = xjg_host_chat(h, text, temp, 1024, cb, me, &st, &err, Int32(err.count))
            let e = cString(err)
            DispatchQueue.main.async {
                self.busy = false
                self.status = ""
                if rc != 0 {
                    self.error = e
                    return
                }
                let speed = st.gen_s > 0 ? Double(st.gen_tokens) / st.gen_s : 0
                var s = String(format: "%.1f 字/秒 · 预填充 %d 个 %.1f 秒", speed, st.prompt_tokens, st.prefill_s)
                if st.remote_ms > 0 {
                    s += String(format: "\n每个字：本机 %.0f ms，从机 %.0f ms，等从机（含 Wi‑Fi）%.0f ms", st.local_ms, st.remote_ms, st.wait_ms)
                }
                s += "\n上下文 \(st.n_past)/\(st.n_ctx)"
                if st.reconnects > 0 { s += " · 从机断线后自动恢复过 \(st.reconnects) 次" }
                self.stats = s
            }
        }
    }
}

struct HostView: View {
    @StateObject private var c = HostController()
    @State private var input = ""

    var body: some View {
        Group {
            if c.connected { chatView } else { setupView }
        }
        .navigationTitle("主机")
        .onAppear { c.finder.start(); c.refresh() }
    }

    private var setupView: some View {
        Form {
            Section(header: Text("模型（和从机选同一个）")) {
                Picker("模型", selection: $c.modelID) {
                    ForEach(ModelSpec.all) { Text($0.name).tag($0.id) }
                }
                if let p = c.downloader.progress {
                    ProgressView(value: p)
                    Text(c.downloader.status).font(.footnote)
                    Button("取消", role: .destructive) { c.downloader.cancel() }
                } else if c.haveModel {
                    Label("模型已在本机", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                } else {
                    Button("下载整个模型") { c.download() }
                    Text("\(c.model.note)。也可以用电脑把 .gguf 拷进「文件」App → 小橘双机。").font(.footnote).foregroundColor(.secondary)
                }
                if !c.downloader.error.isEmpty { Text(c.downloader.error).foregroundColor(.red).font(.footnote) }
            }

            Section(header: Text("从机")) {
                Toggle("不用从机，单机跑（对照速度用）", isOn: $c.solo)
                if !c.solo {
                    ForEach(c.finder.found) { f in
                        Button {
                            c.workerIP = f.host
                        } label: {
                            VStack(alignment: .leading) {
                                Text(f.name)
                                Text("第 \(f.layers) 层 · \(ModelSpec.by(f.model).name)").font(.footnote).foregroundColor(.secondary)
                            }
                        }
                    }
                    TextField("从机地址（IP 或 xxx.local）", text: $c.workerIP)
                        .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                    TextField("配对码（从机屏幕上）", text: $c.pin).keyboardType(.numberPad)
                }
                if let m = c.memoryNote { Text(m).font(.footnote).foregroundColor(.secondary) }
            }

            Section(header: Text("设置")) {
                Stepper("上下文 \(c.ctx)", value: $c.ctx, in: 1024...16384, step: 1024)
                HStack {
                    Text("温度 \(String(format: "%.1f", c.temperature))")
                    Slider(value: $c.temperature, in: 0...1.2, step: 0.1)
                }
            }

            Section {
                Button(c.connecting ? "连接中…（从机第一次要读几秒权重）" : "连接") { c.connect() }
                    .disabled(c.connecting || !c.haveModel || (!c.solo && c.workerIP.isEmpty))
                if !c.error.isEmpty { Text(c.error).foregroundColor(.red) }
            }
        }
    }

    private var chatView: some View {
        VStack(spacing: 0) {
            Text(c.info).font(.footnote).foregroundColor(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(c.chat) { line in
                            Text(line.text.isEmpty ? "…" : line.text)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(line.user ? Color.orange.opacity(0.18) : Color.gray.opacity(0.12))
                                .cornerRadius(10)
                                .frame(maxWidth: .infinity, alignment: line.user ? .trailing : .leading)
                                .id(line.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: c.chat.last?.text) { _ in
                    if let id = c.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            if !c.stats.isEmpty {
                Text(c.stats).font(.caption2).foregroundColor(.secondary).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !c.status.isEmpty { Text(c.status).font(.footnote).foregroundColor(.orange).padding(.horizontal, 8) }
            if !c.error.isEmpty { Text(c.error).font(.footnote).foregroundColor(.red).padding(.horizontal, 8) }
            HStack {
                TextField("说点什么", text: $input).textFieldStyle(.roundedBorder).disabled(c.busy)
                if c.busy {
                    Button("停") { c.stop() }
                } else {
                    Button("发送") { let t = input; input = ""; c.send(t) }.disabled(input.isEmpty)
                }
            }
            .padding(8)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("新对话") { c.newChat() }.disabled(c.busy)
                Button("断开") { c.disconnect() }.disabled(c.busy)
            }
        }
    }
}
