import BackgroundTasks
import UserNotifications
import WidgetKit
import UIKit

enum WidgetReloader {
    static func reload() { WidgetCenter.shared.reloadAllTimelines() }
}

// 后台定时检查云盘：iOS 决定什么时候运行（一般几十分钟到几小时一次）。
// 发现某个任务的改动比上次多，就发一条通知；点通知直接打开那个任务。
enum BackgroundCheck {
    static let id = "com.langhua98.xiaoju.push.refresh"

    static func schedule() {
        guard UserDefaults.standard.bool(forKey: "autoCheck") else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
            return
        }
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    @MainActor
    static func run() async {
        schedule()
        let store = Store.shared
        guard store.autoCheck else { return }
        let grew = await store.refreshPending()
        for (m, n) in grew { await notify(m, n) }
    }

    static func notify(_ m: Mapping, _ n: Int) async {
        let c = UNMutableNotificationContent()
        c.title = "\(m.title) 有 \(n) 个改动"
        c.body = "点开检查并推送到 \(m.repo)"
        c.sound = .default
        c.userInfo = ["task": m.id.uuidString]
        let req = UNNotificationRequest(identifier: "pending-\(m.id.uuidString)", content: c, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    /// 打开「自动检查」时请求通知权限
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["task"] as? String
        Task { @MainActor in
            if let raw, let id = UUID(uuidString: raw) { Store.shared.openTask = id }
            completionHandler()
        }
    }
}
