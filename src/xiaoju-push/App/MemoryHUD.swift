import SwiftUI
import UIKit
import os

// 内存浮标：固定在屏幕最下面（Home 横条左边），不管在哪个页面、弹窗都看得到。
// 显示：App 占用 · 还能用多少 · 本地模型有没有在内存里。点不到它，不挡任何按钮。

@MainActor
final class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()

    @Published private(set) var used: UInt64 = 0
    @Published private(set) var available: UInt64 = 0
    @Published private(set) var model: String?

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in MemoryMonitor.shared.tick() }
        }
    }

    private func tick() {
        used = Self.footprint()
        available = UInt64(os_proc_available_memory())
        Task {
            let f = await LocalModel.shared.loadedFile
            let name = f.map { file in ModelInfo.all.first { $0.file == file }.map { $0.id == "4b-xiaoju" ? "4B小橘" : $0.id.uppercased() } ?? "模型" }
            if name != self.model { self.model = name }
        }
    }

    /// 和「设置 → 内存」/ Xcode 里看到的一样：phys_footprint
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

struct MemoryHUDView: View {
    @ObservedObject private var mon = MemoryMonitor.shared
    @AppStorage("memoryHUD") private var show = true

    private func gb(_ b: UInt64) -> String { String(format: "%.2fG", Double(b) / 1_073_741_824) }

    /// 剩得少了变黄、变红
    private var color: Color {
        if mon.available < 400 * 1_048_576 { return Color(red: 1, green: 0.45, blue: 0.4) }
        if mon.available < 1_000 * 1_048_576 { return Color(red: 1, green: 0.8, blue: 0.35) }
        return .white
    }

    var body: some View {
        VStack {
            Spacer()
            if show {
                HStack(spacing: 4) {
                    Image(systemName: "memorychip").font(.system(size: 9, weight: .semibold))
                    Text("\(gb(mon.used)) · 余\(gb(mon.available))")
                    if let m = mon.model {
                        Text("· \(m)").foregroundStyle(Color(red: 0.91, green: 0.57, blue: 0.44))
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 7).frame(height: 18)
                .background(Color.black.opacity(0.55), in: Capsule())
                // 放在 Home 横条左边那块空地上，不压住输入栏
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
                .padding(.bottom, 8)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 单独一个透明窗口放在最上层，所以弹出的页面也盖不住它；整个窗口不接收点击
enum MemoryHUD {
    @MainActor private static var window: UIWindow?

    @MainActor static func install() {
        MemoryMonitor.shared.start()
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.isUserInteractionEnabled = false
        w.backgroundColor = .clear
        let host = UIHostingController(rootView: MemoryHUDView())
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
    }
}
