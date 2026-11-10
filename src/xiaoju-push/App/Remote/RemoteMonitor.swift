import AVKit
import SwiftUI
import UIKit

// 移动侦测（被控端是安卓 0.8+）：开关、灵敏度、只看哪块区域、录多久、Telegram 提醒、备份；看录好的事件、回放、存相册。
// 侦测在安卓手机上跑，录像先存在那台手机上，再慢慢备份到云盘；这边只是发指令（即时信箱）、看结果。

struct MonitorEvent: Identifiable {
    let name: String
    let at: Date
    let dur: Int        // 毫秒
    let motions: Int
    let video: Bool
    let uploaded: String
    let size: Int
    let labels: String  // 认出来在动的是什么（「人×2、猫」），安卓 0.12+，认不出来是空
    let thumb: UIImage?
    var id: String { name }
}

@MainActor
final class RemoteMonitor: ObservableObject {
    @Published var on = false
    @Published var sensitivity = 50.0
    @Published var regions: [CGRect] = []     // 转正后的画面上，0…1
    @Published var pre = 5
    @Published var post = 15
    @Published var notify = true
    @Published var people = false             // 只在认出人时提醒（安卓 0.12+）
    @Published var cooldown = 5
    @Published var audio = true
    @Published var upload = true
    @Published var lens = "back"
    @Published var width = 640
    @Published var eco = true                 // 省电侦测（安卓 0.14+）
    @Published var engine = "kotlin"          // 侦测引擎（安卓 0.29+）：kotlin 基准 / native C++ 超低功耗 / ab 两个对比

    @Published private(set) var loaded = false
    @Published private(set) var inflight = 0   // 几条指令在等回执（可以同时好几条）
    var busy: Bool { inflight > 0 }
    @Published private(set) var note = ""
    @Published private(set) var statusLine = ""
    @Published private(set) var telegram = ""
    @Published private(set) var backup = ""
    @Published private(set) var objects = ""   // 对方能认东西时是模型名（FastestDet），不能是空
    @Published private(set) var engineLine = "" // 侦测引擎的实测（安卓 0.29+）
    @Published private(set) var hasEngine = false // 对方认得 engine 字段（0.29 以上）
    @Published private(set) var events: [MonitorEvent] = []
    @Published private(set) var moreEvents = false

    private(set) var target = ""

    func use(_ t: String) { if t != target { target = t; loaded = false; events = [] } }

    /// 发一条指令，等回执（即时信箱）。
    func call(_ action: String, _ extra: [String: Any] = [:], wait: Int = 30) async -> [String: Any]? {
        let s = Store.shared
        let dev = target.trimmingCharacters(in: .whitespaces)
        guard !dev.isEmpty else { note = "先填要控制的设备名"; return nil }
        guard !s.cloudToken.isEmpty else { note = "先在设置里填小橘云盘令牌"; return nil }
        let cf = CloudFiles(base: s.cloudURL.isEmpty ? Store.defaultCloudURL : s.cloudURL,
                            readToken: s.cloudToken, writeToken: s.cloudToken)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-"
        let id = f.string(from: Date()) + String(UUID().uuidString.prefix(6))
        var cmd = extra
        cmd["id"] = id; cmd["do"] = action
        cmd["pair"] = s.remotePair.isEmpty ? "0" : s.remotePair  // 空着就发默认口令 0（法莉娅 0.20 默认口令是 0）
        do { try await cf.relaySend(RemoteBox.inbox(dev), cmd) } catch {
            note = "发送失败：\(error.localizedDescription)"; return nil
        }
        let deadline = Date().addingTimeInterval(TimeInterval(wait))
        while Date() < deadline {
            let left = max(1, min(25, Int(deadline.timeIntervalSinceNow)))
            if let r = (try? await cf.relayWait(RemoteBox.receipt(dev, id), seconds: left))?.first { return r }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        note = "等不到回执：确认对方开着待命、是安卓 0.8 以上"
        return nil
    }

    func refresh() async {
        inflight += 1; defer { inflight -= 1 }
        guard let r = await call("monitor_status") else { return }
        take(r)
        loaded = true
    }

    /// 打开 / 关闭 / 改设置：把这边的设置全发过去。
    func save(turnOn: Bool? = nil) async {
        inflight += 1; defer { inflight -= 1 }
        var cmd: [String: Any] = [
            "sensitivity": Int(sensitivity), "pre": pre, "post": post, "notify": notify, "people": people, "cooldown": cooldown,
            "audio": audio, "upload": upload, "lens": lens, "width": width, "eco": eco, "engine": engine,
            "regions": regions.map { [$0.minX, $0.minY, $0.width, $0.height] },
        ]
        cmd["on"] = turnOn ?? on
        guard let r = await call("monitor", cmd) else { return }
        take(r)
    }

    private func take(_ r: [String: Any]) {
        note = (r["text"] as? String) ?? ""
        if (r["ok"] as? Bool) == false { return }
        guard let st = r["status"] as? [String: Any] else { return }
        if let m = st["monitor"] as? [String: Any] {
            on = (m["on"] as? Bool) ?? false
            sensitivity = Double((m["sensitivity"] as? Int) ?? 50)
            pre = (m["pre"] as? Int) ?? 5
            post = (m["post"] as? Int) ?? 15
            notify = (m["notify"] as? Bool) ?? true
            people = (m["people"] as? Bool) ?? false
            cooldown = (m["cooldown"] as? Int) ?? 5
            audio = (m["audio"] as? Bool) ?? true
            upload = (m["upload"] as? Bool) ?? true
            lens = (m["lens"] as? String) ?? "back"
            width = (m["width"] as? Int) ?? 640
            eco = (m["eco"] as? Bool) ?? true
            hasEngine = m["engine"] != nil
            engine = (m["engine"] as? String) ?? "kotlin"
            regions = ((m["regions"] as? [[Double]]) ?? []).compactMap { a in
                a.count == 4 ? CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) : nil
            }
        }
        var parts: [String] = []
        switch (st["stage"] as? String) ?? "" {
        case "watch": parts.append("省电守望中")
        case "record": parts.append((st["recording"] as? Bool) == true ? "正在录" : "开着编码器（不省电）")
        default: if (st["recording"] as? Bool) == true { parts.append("正在录") }
        }
        if let ma = st["current_ma"] as? Int, ma > 0 { parts.append("电流约 \(ma) mA") }
        parts.append("今天 \((st["today"] as? Int) ?? 0) 段")
        parts.append("手机上共 \((st["events"] as? Int) ?? 0) 段（\((st["storage_mb"] as? Int) ?? 0) MB，还剩 \((st["free_mb"] as? Int) ?? 0) MB）")
        if let p = st["pending"] as? Int, p > 0 { parts.append("\(p) 段等着备份") }
        if on, let sc = st["score"] as? Double { parts.append(String(format: "画面变化 %.1f%%", sc * 100)) }
        statusLine = parts.joined(separator: " · ")
        telegram = (st["telegram"] as? String) ?? ""
        backup = (st["backup"] as? String) ?? ""
        objects = (st["objects"] as? String) ?? ""
        engineLine = Self.engineText(st["engine"] as? [String: Any])
        if let n = st["codec_note"] as? String, !n.isEmpty { note += "\n\(n)" }
    }

    /// 侦测引擎的实测写成一句话：报了几次、过滤掉几次、待命时相机实际帧率、App 的 CPU、掉电速度、对比结果。
    static func engineText(_ e: [String: Any]?) -> String {
        guard let e = e, let name = e["engine"] as? String else { return "" }
        var p: [String] = [name == "native" ? "C++ 引擎" : name == "ab" ? "C++ 和 Kotlin 对比" : "Kotlin 引擎"]
        if let m = e["since_min"] as? Int { p.append("开了 \(m) 分钟") }
        if let n = e["events"] as? Int { p.append("报了 \(n) 次") }
        if let f = e["filtered"] as? Int, f > 0 { p.append("过滤掉 \(f) 次") }
        if let s = e["standby_sensor_fps"] as? Double, let l = e["standby_looks_per_s"] as? Double {
            p.append(String(format: "待命时相机每秒出 %.1f 帧、看 %.1f 帧", s, l))
        }
        if let c = e["app_cpu_pct"] as? Double { p.append(String(format: "App CPU %.1f%%", c)) }
        if let b = e["battery_pct_per_h"] as? Double { p.append(String(format: "每小时掉电 %.1f%%", b)) }
        if let ab = e["ab"] as? [String: Any] {
            p.append("两个都发现 \((ab["both"] as? Int) ?? 0) 次、只有 C++ \((ab["native_only"] as? Int) ?? 0) 次、只有 Kotlin \((ab["kotlin_only"] as? Int) ?? 0) 次")
        }
        if let note = e["note"] as? String, !note.isEmpty { p.append(note) }
        return p.joined(separator: " · ")
    }

    func loadEvents(more: Bool = false) async {
        inflight += 1; defer { inflight -= 1 }
        var extra: [String: Any] = ["limit": 30]
        if more, let last = events.last { extra["before"] = last.name }
        guard let r = await call("events", extra), let list = r["events"] as? [[String: Any]] else { return }
        let got = list.map { o -> MonitorEvent in
            let thumb = (o["thumb"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) }
            let at = Date(timeIntervalSince1970: ((o["at"] as? NSNumber)?.doubleValue ?? 0) / 1000)
            return MonitorEvent(name: (o["name"] as? String) ?? "", at: at, dur: (o["dur"] as? Int) ?? 0,
                                motions: (o["motions"] as? Int) ?? 1, video: (o["video"] as? Bool) ?? false,
                                uploaded: (o["uploaded"] as? String) ?? "", size: (o["size"] as? Int) ?? 0,
                                labels: (o["labels"] as? String) ?? "", thumb: thumb)
        }
        events = more ? events + got : got
        moreEvents = got.count >= 30
        if !more { note = "" }
    }

    /// 取一段视频，存成本机的临时文件（取过的不再取）。没有视频时返回截图文件。
    func fetch(_ e: MonitorEvent) async -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("monitor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent("\(target)-\(e.name).\(e.video ? "mov" : "jpg")")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        inflight += 1; defer { inflight -= 1 }
        let s = Store.shared
        let cf = CloudFiles(base: s.cloudURL.isEmpty ? Store.defaultCloudURL : s.cloudURL,
                            readToken: s.cloudToken, writeToken: s.cloudToken)
        // 已经备份到云盘的：直接从云盘下，不用先问对方手机（对方离线、改了设备名、相机卡住时也能看）
        if e.video, !e.uploaded.isEmpty {
            note = "从云盘下载…"
            do {
                if let d = try await cf.readData(e.uploaded), (try? d.write(to: local)) != nil { note = ""; return local }
                note = "云盘上没找到这段，问对方手机要…"
            } catch {
                note = "云盘下载失败（\(error.localizedDescription)），问对方手机要…"
            }
        } else {
            note = e.size > (5 << 20) ? "视频比较大，对方先传到云盘再给你，要等一会儿…" : "取视频…"
        }
        guard let r = await call("event_get", ["name": e.name], wait: 180) else { return nil }
        guard (r["ok"] as? Bool) != false else { note = (r["text"] as? String) ?? "取不到"; return nil }
        var data: Data?
        for entry in (r["files"] as? [Any]) ?? [] where data == nil {
            if let o = entry as? [String: Any], let b64 = o["data"] as? String { data = Data(base64Encoded: b64) }
            else if let p = entry as? String {
                note = "从云盘下载…"
                do { data = try await cf.readData(p) } catch { note = "云盘下载失败：\(error.localizedDescription)"; return nil }
                if data == nil { note = "云盘上没找到 \(p)"; return nil }
            }
        }
        guard let data else { note = "对方回执里没有视频"; return nil }
        guard (try? data.write(to: local)) != nil else { note = "存不下（手机空间满了？）"; return nil }
        note = ""
        return local
    }

    func delete(_ e: MonitorEvent) async {
        guard let r = await call("event_delete", ["name": e.name]) else { return }
        note = (r["text"] as? String) ?? ""
        if (r["ok"] as? Bool) == true { events.removeAll { $0.name == e.name } }
    }

    /// 让对方拍一张（相机开着时从画面截），框选区域用。
    func snapshot() async -> UIImage? {
        inflight += 1; defer { inflight -= 1 }
        guard let r = await call("photo", ["lens": lens], wait: 40) else { return nil }
        for entry in (r["files"] as? [Any]) ?? [] {
            if let o = entry as? [String: Any], let b64 = o["data"] as? String, let d = Data(base64Encoded: b64) {
                return UIImage(data: d)
            }
        }
        note = (r["text"] as? String) ?? "没拿到画面"
        return nil
    }
}

struct RemoteMonitorView: View {
    let target: String
    @StateObject private var m = RemoteMonitor()
    @State private var playing: URL?
    @State private var editingRegions = false

    private let widths = [480, 640, 960]
    private func widthName(_ w: Int) -> String { [480: "标准", 640: "高清", 960: "超清"][w] ?? "\(w)" }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { m.on }, set: { v in Haptics.tap(); Task { await m.save(turnOn: v) } })) {
                    Label("移动侦测", systemImage: "figure.walk.motion").foregroundStyle(Theme.orangeText)
                }
                .disabled(!m.loaded)
                if !m.statusLine.isEmpty { Text(m.statusLine).font(.footnote).foregroundStyle(Theme.muted) }
                if !m.telegram.isEmpty { Text("Telegram：\(m.telegram)").font(.footnote).foregroundStyle(Theme.muted) }
                if !m.backup.isEmpty { Text("备份：\(m.backup)").font(.footnote).foregroundStyle(Theme.muted) }
                if !m.engineLine.isEmpty { Text("侦测：\(m.engineLine)").font(.footnote).foregroundStyle(Theme.muted) }
                if !m.note.isEmpty { Text(m.note).font(.footnote).foregroundStyle(Theme.orangeText) }
                if m.busy { ProgressView() }
            } footer: {
                Text("检测在那台安卓手机上跑：有动静就录（包括动静前几秒），先存在那台手机上，再慢慢备份到云盘，同时发 Telegram 提醒。安卓 0.12 以上还会认出动的是什么（人、猫、狗、车…），写在提醒和列表里，截图上框出来。那台手机要一直插着电。")
            }
            .listRowBackground(Theme.card)

            Section("设置") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("灵敏度 \(Int(m.sensitivity))（越大越灵敏，误报多就调小）").font(.footnote).foregroundStyle(Theme.muted)
                    Slider(value: $m.sensitivity, in: 1...100, step: 1)
                }
                Button { editingRegions = true } label: {
                    Label(m.regions.isEmpty ? "只看画面的一部分…（现在看整个画面）" : "只看 \(m.regions.count) 个区域…", systemImage: "viewfinder")
                }
                Toggle(isOn: $m.eco) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("省电侦测")
                        Text(m.eco
                             ? "没动静时相机每秒只看 4 帧、不录像，有动静才开始录（动静前只留几张画面，最多 3 秒）。安卓 0.14 以上。"
                             : "编码器一直开着，能录到动静前 \(m.pre) 秒，但费电得多，要一直插着电。")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                if m.eco && m.hasEngine {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("侦测引擎", selection: $m.engine) {
                            Text("Kotlin 基准").tag("kotlin")
                            Text("C++ 省电").tag("native")
                            Text("两个对比").tag("ab")
                        }.pickerStyle(.segmented)
                        Text(m.engine == "native"
                             ? "C++ 超低功耗版：没动静时每秒只看 2 帧，有变化升到 4 帧、连续 3 帧才算，误报少。安卓 0.29 以上。"
                             : m.engine == "ab"
                             ? "两个引擎看同一帧，按 C++ 的结果录像，状态里记下两个哪里不一样（用来比漏检和误报）。"
                             : "原来的版本：没动静时每秒看 4 帧、连续 2 帧算动。")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                Stepper(m.eco ? "动静前留 \(min(m.pre, 3)) 秒画面" : "动静前录 \(m.pre) 秒", value: $m.pre, in: 0...10)
                Stepper("动静停了再录 \(m.post) 秒", value: $m.post, in: 5...120, step: 5)
                Toggle("录声音", isOn: $m.audio)
                Toggle("Telegram 提醒（带截图）", isOn: $m.notify)
                if m.notify {
                    Toggle(isOn: $m.people) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("只在认出人时提醒")
                            Text(m.objects.isEmpty
                                 ? "那台手机的安装包不带识别模型（或版本低于 0.12），开了也照常提醒"
                                 : "猫、狗、车这些照样录，只是不发提醒")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                    Stepper("两次提醒至少隔 \(m.cooldown) 分钟", value: $m.cooldown, in: 0...60)
                }
                Toggle("慢慢备份到云盘", isOn: $m.upload)
                Picker("镜头", selection: $m.lens) {
                    Text("后置").tag("back")
                    Text("前置").tag("front")
                }.pickerStyle(.segmented)
                Picker("清晰度", selection: $m.width) {
                    ForEach(widths, id: \.self) { w in Text(widthName(w)).tag(w) }
                }.pickerStyle(.segmented)
                Button {
                    Haptics.tap()
                    Task { await m.save() }
                } label: { Label("保存设置", systemImage: "checkmark.circle").foregroundStyle(Theme.orangeText) }
                .disabled(!m.loaded)
            }
            .listRowBackground(Theme.card)

            Section("录好的") {
                if m.events.isEmpty {
                    Text(m.loaded ? "还没有" : "…").foregroundStyle(Theme.muted)
                }
                ForEach(m.events) { e in
                    Button {
                        Task { if let u = await m.fetch(e) { playing = u } }
                    } label: { row(e) }
                    .swipeActions {
                        Button(role: .destructive) { Task { await m.delete(e) } } label: { Label("删", systemImage: "trash") }
                    }
                }
                if m.moreEvents {
                    Button("更早的…") { Task { await m.loadEvents(more: true) } }
                }
            }
            .listRowBackground(Theme.card)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("移动侦测")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await m.refresh(); await m.loadEvents() }
        .task {
            m.use(target)
            await m.refresh()
            await m.loadEvents()
        }
        .sheet(item: Binding(get: { playing.map { PlayItem(url: $0) } }, set: { playing = $0?.url })) { item in
            MonitorPlayer(url: item.url)
        }
        .sheet(isPresented: $editingRegions) {
            RegionEditor(monitor: m)
        }
    }

    private func row(_ e: MonitorEvent) -> some View {
        HStack(spacing: 10) {
            if let t = e.thumb {
                Image(uiImage: t).resizable().scaledToFill().frame(width: 64, height: 48).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)).frame(width: 64, height: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.time.string(from: e.at)).foregroundStyle(Theme.text)
                if !e.labels.isEmpty {
                    Text(e.labels).font(.footnote.weight(.semibold)).foregroundStyle(Theme.orangeText)
                }
                Text(e.video ? "\(e.dur / 1000) 秒 · 动了 \(e.motions) 次" : "只有截图")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            Spacer()
            if !e.uploaded.isEmpty { Image(systemName: "icloud.fill").foregroundStyle(Theme.muted) }
        }
    }

    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm:ss"; return f }()
}

private struct PlayItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// 放一段录像（或看截图），可以存相册、分享。
private struct MonitorPlayer: View {
    let url: URL
    @State private var saved = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if url.pathExtension == "jpg", let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    VideoPlayer(player: AVPlayer(url: url))
                }
                if !saved.isEmpty { Text(saved).font(.footnote).foregroundStyle(Theme.muted) }
            }
            .padding()
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: url) }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        if url.pathExtension == "jpg", let img = UIImage(contentsOfFile: url.path) {
                            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil); saved = "已存到相册"
                        } else if UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) {
                            UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil); saved = "已存到相册"
                        } else {
                            saved = "这个视频存不进相册，用右上角分享"
                        }
                    } label: { Label("存到相册", systemImage: "square.and.arrow.down") }
                }
            }
        }
    }
}

/// 框选只看哪几块：先让对方拍一张，在图上拖出方框（最多 4 个）。
private struct RegionEditor: View {
    @ObservedObject var monitor: RemoteMonitor
    @State private var image: UIImage?
    @State private var rects: [CGRect] = []
    @State private var drag: CGRect?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { g in
                                ZStack(alignment: .topLeading) {
                                    ForEach(Array((rects + (drag.map { [$0] } ?? [])).enumerated()), id: \.offset) { _, r in
                                        Rectangle().strokeBorder(Theme.orangeText, lineWidth: 2)
                                            .background(Theme.orangeText.opacity(0.15))
                                            .frame(width: r.width * g.size.width, height: r.height * g.size.height)
                                            .offset(x: r.minX * g.size.width, y: r.minY * g.size.height)
                                    }
                                }
                                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 4).onChanged { v in
                                    drag = norm(v.startLocation, v.location, g.size)
                                }.onEnded { v in
                                    let r = norm(v.startLocation, v.location, g.size)
                                    if r.width > 0.03 && r.height > 0.03 && rects.count < 4 { rects.append(r) }
                                    drag = nil
                                })
                            }
                        }
                    Text("在图上拖出要看的地方（最多 4 块）。不框 = 看整个画面。").font(.footnote).foregroundStyle(Theme.muted)
                } else if monitor.busy {
                    ProgressView("让对方拍一张…")
                } else {
                    Text(monitor.note.isEmpty ? "拿不到画面" : monitor.note).foregroundStyle(Theme.muted)
                    Button("再拍一张") { Task { image = await monitor.snapshot() } }
                }
                Spacer()
            }
            .padding()
            .background(Theme.bg)
            .navigationTitle("只看这些地方")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        monitor.regions = rects
                        Task { await monitor.save() }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("全部清掉") { rects = [] }.disabled(rects.isEmpty)
                }
            }
            .task {
                rects = monitor.regions
                if image == nil { image = await monitor.snapshot() }
            }
        }
    }

    private func norm(_ a: CGPoint, _ b: CGPoint, _ s: CGSize) -> CGRect {
        func c(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        let x0 = c(min(a.x, b.x) / s.width), y0 = c(min(a.y, b.y) / s.height)
        let x1 = c(max(a.x, b.x) / s.width), y1 = c(max(a.y, b.y) / s.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
