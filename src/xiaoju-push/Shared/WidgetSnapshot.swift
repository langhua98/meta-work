import Foundation

// App 和桌面小组件共用：每个任务待推几个文件。通过 App Group 共享。
struct WidgetSnapshot: Codable {
    struct Task: Codable, Hashable {
        var name: String
        var repo: String
        var pending: Int
    }

    var tasks: [Task]
    var updated: Date

    static let group = "group.com.langhua98.xiaoju.push"
    private static let key = "widgetSnapshot"

    var total: Int { tasks.reduce(0) { $0 + $1.pending } }

    func save() {
        guard let d = UserDefaults(suiteName: Self.group), let data = try? JSONEncoder().encode(self) else { return }
        d.set(data, forKey: Self.key)
    }

    static func load() -> WidgetSnapshot? {
        guard let d = UserDefaults(suiteName: group), let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static let sample = WidgetSnapshot(tasks: [.init(name: "meta work", repo: "langhua98/meta-work", pending: 3),
                                              .init(name: "pocketpal", repo: "langhua98/pocketpal-ai", pending: 12)],
                                       updated: Date())
}
