import AppIntents
import UIKit

// 快捷指令，两个方向：
// 1. 快捷指令里能用「问小橘」：带一句话打开 App，像自己在对话框里打的一样（可以配合「自动化」定时跑，比如每天早上「所有任务有改动吗」）。
// 2. 小橘能运行你的快捷指令：{"do":"shortcut","name":"名字"}，先出确认卡片再跳到「快捷指令」App 去跑。

struct AskXiaojuIntent: AppIntent {
    static let title: LocalizedStringResource = "问小橘"
    static let description = IntentDescription("打开小橘推送，把这句话发进对话框（和自己打字一样）")
    static let openAppWhenRun = true

    @Parameter(title: "要说的话", requestValueDialog: "要小橘做什么？")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        Store.shared.askText = text
        return .result()
    }
}

struct XiaojuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskXiaojuIntent(), phrases: ["问\(.applicationName)", "让\(.applicationName)帮我"],
                    shortTitle: "问小橘", systemImageName: "bubble.left.and.text.bubble.right")
    }
}

enum ShortcutRunner {
    /// 跳到「快捷指令」App 运行这个快捷指令；input 会作为快捷指令的输入
    @MainActor
    static func run(_ name: String, input: String? = nil) async -> Bool {
        var c = URLComponents(string: "shortcuts://run-shortcut")!
        c.queryItems = [.init(name: "name", value: name)] + (input.map { [.init(name: "input", value: "text"), .init(name: "text", value: $0)] } ?? [])
        guard let u = c.url else { return false }
        return await UIApplication.shared.open(u)
    }
}
