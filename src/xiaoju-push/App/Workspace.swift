import Foundation

// 工作区：每个任务在手机里的一份代码副本（App 的「文稿/工作区/仓库名」，「文件」App 里能看到）。
// 粘贴进来的代码整理到这里，推送时和 GitHub 对比，只推改了的。

struct Workspace {
    let mapping: Mapping

    static var base: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("工作区", isDirectory: true)
    }

    /// 仓库名做文件夹名，同名的加上任务 id 前 4 位
    var root: URL {
        let name = mapping.repo.split(separator: "/").last.map(String.init) ?? "任务"
        let safe = name.isEmpty ? "任务" : name
        let plain = Self.base.appendingPathComponent(safe, isDirectory: true)
        let marker = plain.appendingPathComponent(".xiaoju-task")
        if let id = try? String(contentsOf: marker, encoding: .utf8), id != mapping.id.uuidString {
            return Self.base.appendingPathComponent(safe + "-" + String(mapping.id.uuidString.prefix(4)), isDirectory: true)
        }
        return plain
    }

    func ensure() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent(".xiaoju-task")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try mapping.id.uuidString.write(to: marker, atomically: true, encoding: .utf8)
        }
    }

    /// 所有文件的相对路径（跳过 .git、node_modules、隐藏的标记文件和不推的文件夹）
    func files() -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [String] = []
        let rootPath = root.standardizedFileURL.path
        let excluded = mapping.excludedPaths
        for case let u as URL in e {
            let name = u.lastPathComponent
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if PushEngine.skipNames.contains(name) || name == ".xiaoju-task" {
                if isDir { e.skipDescendants() }
                continue
            }
            var rel = u.standardizedFileURL.path
            guard rel.hasPrefix(rootPath) else { continue }
            rel.removeFirst(rootPath.count)
            while rel.hasPrefix("/") { rel.removeFirst() }
            if PushEngine.isExcluded(rel, by: excluded) {
                if isDir { e.skipDescendants() }
                continue
            }
            if !isDir { out.append(rel) }
        }
        return out.sorted()
    }

    func url(_ rel: String) -> URL {
        root.appendingPathComponent(PushEngine.clean(rel).joined(separator: "/"))
    }

    func read(_ rel: String) -> Data? { try? Data(contentsOf: url(rel)) }

    func write(_ rel: String, _ data: Data) throws {
        let segs = PushEngine.clean(rel)
        guard !segs.isEmpty else { throw PushError("文件路径是空的") }
        let u = url(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u, options: .atomic)
    }

    func size(_ rel: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url(rel).path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
