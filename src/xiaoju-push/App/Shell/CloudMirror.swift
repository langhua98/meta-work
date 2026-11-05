import Foundation

// 云盘任务的代码不在手机上。跑命令前先把云盘文件夹同步一份到手机（资源库/Caches/云盘副本/任务 id/），
// 只下载新的和改过的（按云盘给的 sha256 比），云盘上删掉的这边也删。
// 这是只读副本：在这里改了不会传回云盘。

struct CloudMirror {
    let mapping: Mapping
    let engine: PushEngine

    /// 太大的文件不下（多半是图片、压缩包，搜代码用不上）
    static let maxFileSize: Int64 = 5 * 1024 * 1024

    var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("云盘副本", isDirectory: true)
            .appendingPathComponent(mapping.id.uuidString, isDirectory: true)
    }

    private var manifestURL: URL { root.appendingPathComponent(".xiaoju-mirror.json") }

    struct Result { var downloaded: Int; var removed: Int; var skipped: Int; var total: Int }

    /// progress(已处理, 要下载的总数)
    func sync(progress: @escaping @MainActor (Int, Int) -> Void) async throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var manifest = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))) ?? [:]
        let listing = try await engine.walk(mapping.cloudPath, excluding: mapping.excludedPaths)

        var todo: [(String, CloudItem)] = []
        var skipped = 0
        for (rel, item) in listing {
            if (item.size ?? 0) > Self.maxFileSize { skipped += 1; continue }
            let have = fm.fileExists(atPath: url(rel).path)
            if have, let s = item.sha256, manifest[rel] == s { continue }
            todo.append((rel, item))
        }

        // 云盘上已经没有的，这边也删掉
        let keep = Set(listing.map(\.0))
        var removed = 0
        for rel in manifest.keys where !keep.contains(rel) {
            try? fm.removeItem(at: url(rel))
            manifest[rel] = nil
            removed += 1
        }

        // 同时下 6 个
        var done = 0
        await progress(0, todo.count)
        try await withThrowingTaskGroup(of: (String, String?).self) { group in
            var next = 0
            func addOne() {
                guard next < todo.count else { return }
                let (rel, item) = todo[next]
                next += 1
                group.addTask {
                    let data = try await engine.download(item)
                    let u = url(rel)
                    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: u, options: .atomic)
                    return (rel, item.sha256)
                }
            }
            for _ in 0..<6 { addOne() }
            while let (rel, sha) = try await group.next() {
                manifest[rel] = sha ?? ""
                done += 1
                await progress(done, todo.count)
                if Task.isCancelled { group.cancelAll(); break }
                addOne()
            }
        }
        if let d = try? JSONEncoder().encode(manifest) { try? d.write(to: manifestURL, options: .atomic) }
        return Result(downloaded: done, removed: removed, skipped: skipped, total: listing.count)
    }

    private func url(_ rel: String) -> URL {
        root.appendingPathComponent(PushEngine.clean(rel).joined(separator: "/"))
    }
}
