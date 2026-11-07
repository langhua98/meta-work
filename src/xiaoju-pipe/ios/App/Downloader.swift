import Foundation

/// 分块下载（HTTP Range）。主机下载整个文件；从机只下载自己那几层，写成和原文件一样大的稀疏文件，
/// 没下载的地方是空洞，不占空间（iPhone 7 Plus 上 9B 只要下约 1 GB，不是 5.7 GB）。
/// 下好的块记在 <文件>.parts.json 里，断了可以接着下。
final class Downloader: ObservableObject {
    @Published var progress: Double?          // nil = 没在下载
    @Published var status = ""
    @Published var error = ""
    private var cancelled = false

    private struct Parts: Codable { var total: UInt64; var done: [[UInt64]] }

    static let chunk: UInt64 = 16 << 20

    func cancel() { cancelled = true }

    /// 已经下好的区间
    static func doneRanges(_ m: ModelSpec) -> [[UInt64]] {
        guard let d = try? Data(contentsOf: Paths.parts(for: m)), let p = try? JSONDecoder().decode(Parts.self, from: d) else { return [] }
        return p.done
    }

    /// [lo, hi) 是不是都下好了。用户从「文件」App 拷进来的完整文件算全有
    static func covered(_ m: ModelSpec, _ lo: UInt64, _ hi: UInt64) -> Bool {
        let f = Paths.file(for: m)
        if f.deletingLastPathComponent().standardizedFileURL == Paths.documents.standardizedFileURL { return true }
        var pos = lo
        for r in doneRanges(m).sorted(by: { $0[0] < $1[0] }) where r[0] <= pos && r[1] > pos {
            pos = max(pos, r[1])
            if pos >= hi { return true }
        }
        return pos >= hi
    }

    /// 从机这几层是不是都在本地了
    static func haveLayers(_ m: ModelSpec, _ l0: Int, _ l1: Int) -> Bool {
        guard let head = try? readHead(Paths.file(for: m)) else { return false }
        guard let plan = try? Downloader.plan(head, l0, l1) else { return false }
        return covered(m, 0, plan.dataOff) && plan.ranges.allSatisfy { covered(m, $0.0, $0.1) }
    }

    private static func readHead(_ url: URL) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        return h.readData(ofLength: 32 << 20)
    }

    struct Plan { var ranges: [(UInt64, UInt64)]; var dataOff: UInt64; var layout: ModelLayout }

    /// 用文件头算出 [l0, l1) 层的字节范围；头不够长时抛 need 错误
    static func plan(_ head: Data, _ l0: Int, _ l1: Int) throws -> Plan {
        var ranges = [(UInt64, UInt64)](repeating: (0, 0), count: 512)
        var need: UInt64 = 0, dataOff: UInt64 = 0
        var info = xjg_model_info()
        var err = [CChar](repeating: 0, count: 256)
        let n: Int32 = head.withUnsafeBytes { raw in
            ranges.withUnsafeMutableBufferPointer { rp in
                xjg_plan(raw.bindMemory(to: UInt8.self).baseAddress, UInt64(head.count), Int32(l0), Int32(l1),
                         rp.baseAddress, 512, &need, &dataOff, &info, &err, Int32(err.count))
            }
        }
        if n == 0 && need > 0 { throw NeedMore(bytes: need) }
        if n < 0 { throw XJError(cString(err)) }
        return Plan(ranges: Array(ranges[0..<Int(n)]), dataOff: dataOff, layout: ModelLayout(info))
    }

    struct NeedMore: Error { let bytes: UInt64 }

    /// 只拿文件头（几 MB），看模型结构
    func fetchLayout(_ m: ModelSpec) async throws -> ModelLayout {
        var want: UInt64 = 16 << 20
        while true {
            let (data, _) = try await get(m.url, 0, want)
            do { return try Downloader.plan(data, 0, 1).layout }
            catch let e as NeedMore { want = max(e.bytes, want * 2) }
        }
    }

    /// 主机：layers = nil 下整个文件；从机：只下 [l0, l1)
    func download(_ m: ModelSpec, layers: (Int, Int)?) async {
        cancelled = false
        await ui { self.progress = 0; self.error = ""; self.status = "读取模型结构……" }
        do {
            // 1. 文件头 + 总大小
            var want: UInt64 = 16 << 20
            var head = Data(), total: UInt64 = 0, plan: Plan
            while true {
                (head, total) = try await get(m.url, 0, want)
                do { plan = try Downloader.plan(head, layers?.0 ?? 0, layers?.1 ?? 1); break }
                catch let e as NeedMore { want = max(e.bytes, want * 2) }
            }
            let zero: UInt64 = 0
            var todo: [(UInt64, UInt64)] = layers == nil ? [(zero, total)] : [(zero, plan.dataOff)] + plan.ranges

            // 2. 建（或复用）同样大小的文件
            let url = Paths.models.appendingPathComponent(m.file)
            var parts = Parts(total: total, done: [])
            if let d = try? Data(contentsOf: Paths.parts(for: m)), let p = try? JSONDecoder().decode(Parts.self, from: d), p.total == total,
               FileManager.default.fileExists(atPath: url.path) {
                parts = p
            } else {
                try? FileManager.default.removeItem(at: url)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let h = try FileHandle(forWritingTo: url)
                try h.truncate(atOffset: total)
                try h.close()
                var u = url
                var v = URLResourceValues()
                v.isExcludedFromBackup = true
                try? u.setResourceValues(v)
            }
            // 已经下好的不再下
            todo = todo.flatMap { r -> [(UInt64, UInt64)] in
                var out: [(UInt64, UInt64)] = []
                var lo = r.0
                while lo < r.1 {
                    let hi = min(r.1, (lo / Downloader.chunk + 1) * Downloader.chunk)
                    if !Downloader.covered(m, lo, hi) { out.append((lo, hi)) }
                    lo = hi
                }
                return out
            }
            let bytes = todo.reduce(0) { $0 + ($1.1 - $1.0) }
            var got: UInt64 = 0
            let started = Date()
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            for (lo, hi) in todo {
                if cancelled { throw XJError("已取消") }
                let (data, _) = try await get(m.url, lo, hi - lo)
                guard UInt64(data.count) == hi - lo else { throw XJError("服务器回的字节数不对（\(data.count)）") }
                try h.seek(toOffset: lo)
                try h.write(contentsOf: data)
                parts.done.append([lo, hi])
                if parts.done.count % 8 == 0 || hi == todo.last?.1 {
                    try? h.synchronize()
                    try JSONEncoder().encode(parts).write(to: Paths.parts(for: m))
                }
                got += hi - lo
                let speed = Double(got) / max(Date().timeIntervalSince(started), 0.1) / 1048576
                let msg = String(format: "%@ / %@，%.1f MB/s", (Double(got) / 1048576).mb, (Double(bytes) / 1048576).mb, speed)
                await ui { self.progress = Double(got) / Double(max(bytes, 1)); self.status = msg }
            }
            try JSONEncoder().encode(parts).write(to: Paths.parts(for: m))
            await ui { self.progress = nil; self.status = bytes == 0 ? "已经都下好了" : "下载完成" }
        } catch {
            let msg = error.localizedDescription
            await ui { self.progress = nil; self.error = msg }
        }
    }

    /// GET 一段字节，返回数据和文件总大小
    private func get(_ url: URL, _ lo: UInt64, _ len: UInt64) async throws -> (Data, UInt64) {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(lo)-\(lo + len - 1)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 60
        var lastError: Error = XJError("下载失败")
        for attempt in 0..<4 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let r = resp as? HTTPURLResponse else { throw XJError("没有 HTTP 响应") }
                guard r.statusCode == 206 else { throw XJError("服务器不支持分段下载（\(r.statusCode)）") }
                var total: UInt64 = 0
                if let cr = r.value(forHTTPHeaderField: "Content-Range"), let slash = cr.lastIndex(of: "/") {
                    total = UInt64(cr[cr.index(after: slash)...]) ?? 0
                }
                return (data, total)
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000)
            }
        }
        throw lastError
    }

    private func ui(_ f: @escaping () -> Void) async {
        await MainActor.run { f() }
    }
}
