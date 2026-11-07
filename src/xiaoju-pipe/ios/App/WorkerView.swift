import Combine
import SwiftUI
import UIKit

/// 从机（iPhone 7 Plus）：下载自己负责的几层，开着屏幕等主机连。
final class WorkerController: NSObject, ObservableObject, NetServiceDelegate {
    @Published var running = false
    @Published var lines: [String] = []
    @Published var layout: ModelLayout?
    @Published var have = false
    let downloader = Downloader()

    @Published var modelID: String { didSet { UserDefaults.standard.set(modelID, forKey: "w.model"); refresh() } }
    @Published var start: Int { didSet { UserDefaults.standard.set(start, forKey: "w.start"); refresh() } }
    @Published var count: Int { didSet { UserDefaults.standard.set(count, forKey: "w.count"); refresh() } }
    let pin: UInt32
    let port: Int32 = 47321

    private var handle: UnsafeMutableRawPointer?
    /// 用户点了「开始待命」还没点「停止」。App 被切到后台时 iOS 会收回监听端口，
    /// 回到前台后按这个自动重新待命，主机那边会自己重连。
    private var wantRunning = false
    private var service: NetService?
    private var bag: AnyCancellable?

    override init() {
        let d = UserDefaults.standard
        modelID = d.string(forKey: "w.model") ?? ModelSpec.q9b.id
        start = d.object(forKey: "w.start") as? Int ?? 12
        count = d.object(forKey: "w.count") as? Int ?? 8
        if d.object(forKey: "w.pin") == nil { d.set(Int.random(in: 1000...9999), forKey: "w.pin") }
        pin = UInt32(d.integer(forKey: "w.pin"))
        super.init()
        // 下载进度变了界面也要刷新
        bag = downloader.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        refresh()
    }

    var model: ModelSpec { ModelSpec.by(modelID) }
    var l1: Int { start + count }

    func refresh() {
        layout = ModelLayout.read(Paths.file(for: model))
        if let n = layout?.nLayer {
            if start + count > n { start = max(0, n - count) }
        }
        have = Downloader.haveLayers(model, start, l1)
    }

    func fetchLayout() {
        Task {
            if let l = try? await downloader.fetchLayout(model) { await MainActor.run { self.layout = l } }
        }
    }

    func download() {
        Task {
            await downloader.download(model, layers: (start, l1))
            await MainActor.run { self.refresh() }
        }
    }

    func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        lines.append("\(f.string(from: Date())) \(s)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }

    func startServing() {
        guard !running else { return }
        wantRunning = true
        var err = [CChar](repeating: 0, count: 256)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let logFn: xjg_log_fn = { ctx, msg in
            guard let ctx, let msg else { return }
            let c = Unmanaged<WorkerController>.fromOpaque(ctx).takeUnretainedValue()
            let s = String(cString: msg)
            DispatchQueue.main.async { c.log(s) }
        }
        guard let h = xjg_worker_new(Paths.file(for: model).path, Int32(start), Int32(l1), pin, logFn, me, &err, Int32(err.count)) else {
            log("打开模型失败：\(cString(err))")
            return
        }
        handle = h
        running = true
        UIApplication.shared.isIdleTimerDisabled = true   // 锁屏后 iOS 不让 App 用 GPU，保持亮屏
        publish()
        let port = self.port
        Thread {
            var e = [CChar](repeating: 0, count: 256)
            let rc = xjg_worker_run(h, port, &e, Int32(e.count))
            DispatchQueue.main.async {
                if rc != 0 { self.log("停止：\(cString(e))") }
                self.finish()
            }
        }.start()
    }

    func stopServing() {
        wantRunning = false
        if let h = handle { xjg_worker_stop(h) }
    }

    /// 回到前台：之前在待命、后来被系统停掉了，就重新开始
    func resumeIfNeeded() {
        guard wantRunning, !running, handle == nil, UIApplication.shared.applicationState == .active else { return }
        log("回到前台，重新开始待命")
        startServing()
    }

    private func finish() {
        if let h = handle { xjg_worker_free(h) }
        handle = nil
        running = false
        service?.stop()
        service = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if wantRunning {
            log("待命意外停止（App 可能被切到了后台），回到前台会自动恢复")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.resumeIfNeeded() }
        } else {
            log("已停止待命")
        }
    }

    /// 在局域网里用 Bonjour 广播自己，主机列表里能直接点到
    private func publish() {
        let s = NetService(domain: "local.", type: "_xjpipe._tcp.", name: UIDevice.current.name, port: port)
        let txt: [String: Data] = ["layers": "\(start)-\(l1 - 1)".data(using: .utf8)!, "model": model.id.data(using: .utf8)!]
        s.setTXTRecord(NetService.data(fromTXTRecord: txt))
        s.delegate = self
        s.publish()
        service = s
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        log("Bonjour 广播失败（主机那边手动填 IP 也行）")
    }

    var ips: String {
        var buf = [CChar](repeating: 0, count: 256)
        xjg_local_ips(&buf, Int32(buf.count))
        let s = cString(buf)
        return s.isEmpty ? "没连 Wi‑Fi" : s
    }
}

struct WorkerView: View {
    @StateObject private var c = WorkerController()
    @Environment(\.scenePhase) private var phase
    private var dl: Downloader { c.downloader }

    var body: some View {
        Form {
            Section(header: Text("模型（和主机选同一个）")) {
                Picker("模型", selection: $c.modelID) {
                    ForEach(ModelSpec.all) { Text($0.name).tag($0.id) }
                }
                .disabled(c.running)
                Text(c.model.note).font(.footnote).foregroundColor(.secondary)
            }

            Section(header: Text("这台手机负责哪几层"),
                    footer: Text("7 Plus 内存 3 GB，App 大约能用 1.5–2 GB。9B 建议 6–8 层（约 0.8–1 GB）；层数越多越省主机内存，但整体会慢一点。")) {
                if let l = c.layout {
                    Stepper("从第 \(c.start) 层开始", value: $c.start, in: 0...max(0, l.nLayer - c.count))
                    Stepper("一共 \(c.count) 层（到第 \(c.l1 - 1) 层）", value: $c.count, in: 1...max(1, l.nLayer - c.start))
                    row("权重", l.mb(c.start, c.l1).mb)
                    row("现在可用内存", (Double(xjg_free_memory()) / 1048576).mb)
                } else {
                    Button("读取模型结构（只下几 MB）") { c.fetchLayout() }
                }
            }
            .disabled(c.running)

            Section(header: Text("下载")) {
                if let p = dl.progress {
                    ProgressView(value: p)
                    Text(dl.status).font(.footnote)
                    Button("取消", role: .destructive) { dl.cancel() }
                } else if c.have {
                    Label("第 \(c.start)–\(c.l1 - 1) 层已在本机", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                } else {
                    Button("只下载这几层") { c.download() }
                    Text("只下载需要的字节，其余部分是空洞，不占空间。也可以用电脑把完整的 .gguf 拷进「文件」App → 小橘双机。")
                        .font(.footnote).foregroundColor(.secondary)
                }
                if !dl.error.isEmpty { Text(dl.error).foregroundColor(.red).font(.footnote) }
            }

            Section(header: Text("待命")) {
                row("配对码", String(c.pin))
                row("本机 IP", c.ips)
                row("端口", String(c.port))
                if c.running {
                    Button("停止待命", role: .destructive) { c.stopServing() }
                    Text("保持亮屏、App 在前台。iOS 不让后台的 App 用 GPU；不小心切走了，切回来会自动恢复待命，主机那边会自己重连接着聊。").font(.footnote).foregroundColor(.orange)
                } else {
                    Button("开始待命") { c.startServing() }.disabled(!c.have)
                }
            }

            if !c.lines.isEmpty {
                Section(header: Text("状态")) {
                    ForEach(Array(c.lines.suffix(30).enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(.footnote, design: .monospaced))
                    }
                }
            }
        }
        .navigationTitle("从机")
        .onAppear { c.refresh() }
        .onChange(of: phase) { p in if p == .active { c.resumeIfNeeded() } }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundColor(.secondary).multilineTextAlignment(.trailing) }
    }
}
