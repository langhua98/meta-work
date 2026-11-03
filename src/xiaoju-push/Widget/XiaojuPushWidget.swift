import SwiftUI
import WidgetKit

// 桌面小组件：每个推送任务还有几个文件待推。数据由 App 写进 App Group（Shared/WidgetSnapshot.swift）。
// 只用这一个文件 + Shared，不引用 App 里的代码，颜色也自己定义。

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

private enum WColor {
    static let bg = Color(hex: 0x0d1117)
    static let text = Color(hex: 0xe6edf3)
    static let muted = Color(hex: 0x8d96a0)
    static let blue = Color(hex: 0x79b8ff)
    static let blueSoft = Color(hex: 0x1f2a37)
    static let raised = Color(hex: 0x21262d)
    static let orange = Color(hex: 0xf0883e)
}

struct PendingEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let hasData: Bool
}

struct PendingProvider: TimelineProvider {
    func placeholder(in context: Context) -> PendingEntry {
        PendingEntry(date: Date(), snapshot: .sample, hasData: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (PendingEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(current())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PendingEntry>) -> Void) {
        let entry = current()
        let next = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func current() -> PendingEntry {
        if let s = WidgetSnapshot.load() {
            return PendingEntry(date: Date(), snapshot: s, hasData: true)
        }
        return PendingEntry(date: Date(), snapshot: WidgetSnapshot(tasks: [], updated: Date()), hasData: false)
    }
}

struct PendingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PendingEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var total: Int { entry.snapshot.total }

    // MARK: 小号

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(WColor.orange)
                Spacer()
            }
            Spacer(minLength: 0)
            Text("\(total)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(WColor.text)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("个文件待推")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(WColor.text)
            Text(entry.hasData ? "\(entry.snapshot.tasks.count) 个任务" : "打开 App 刷新")
                .font(.caption)
                .foregroundStyle(WColor.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { WColor.bg }
    }

    // MARK: 中号

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(WColor.orange)
                Text("\(total) 个文件待推")
                    .font(.headline)
                    .foregroundStyle(WColor.text)
                Spacer()
                if entry.hasData {
                    (Text(entry.snapshot.updated, style: .relative) + Text("前"))
                        .font(.caption2)
                        .foregroundStyle(WColor.muted)
                        .lineLimit(1)
                }
            }
            if entry.snapshot.tasks.isEmpty {
                Spacer(minLength: 0)
                Text(entry.hasData ? "还没有推送任务" : "打开小橘推送刷新一次")
                    .font(.subheadline)
                    .foregroundStyle(WColor.muted)
                Spacer(minLength: 0)
            } else {
                ForEach(Array(entry.snapshot.tasks.prefix(3).enumerated()), id: \.offset) { _, task in
                    row(task)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { WColor.bg }
    }

    private func row(_ task: WidgetSnapshot.Task) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(task.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(WColor.text)
                    .lineLimit(1)
                Text(task.repo)
                    .font(.caption2)
                    .foregroundStyle(WColor.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if task.pending > 0 {
                Text("\(task.pending)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WColor.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(WColor.blueSoft))
            } else {
                Text("已同步")
                    .font(.caption)
                    .foregroundStyle(WColor.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(WColor.raised))
            }
        }
    }

    // MARK: 锁屏

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "arrow.up")
                    .font(.caption.weight(.bold))
                Text("\(total)")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var rectangular: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(total)")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .lineLimit(1)
                Text("个文件待推")
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct PendingWidget: Widget {
    let kind = "XiaojuPushPending"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PendingProvider()) { entry in
            PendingWidgetView(entry: entry)
        }
        .configurationDisplayName("待推文件")
        .description("每个推送任务还有几个文件没推到 GitHub。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

@main
struct XiaojuPushWidgets: WidgetBundle {
    var body: some Widget {
        PendingWidget()
    }
}
