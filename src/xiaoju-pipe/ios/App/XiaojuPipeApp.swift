import SwiftUI

@main
struct XiaojuPipeApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// 进来先选这台手机当什么：主机（15 Pro Max）还是从机（7 Plus）
struct RootView: View {
    @AppStorage("role") private var role = ""

    var body: some View {
        NavigationView {
            Group {
                if role == "host" { HostView() }
                else if role == "worker" { WorkerView() }
                else { picker }
            }
            .toolbar {
                if !role.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("换角色") { role = "" }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var picker: some View {
        List {
            Section(footer: Text("两台手机装同一个 App，连同一个 Wi‑Fi。主机负责分词、前后几层和输出头；从机用 GPU 算中间几层。两台合起来能跑一台装不下的模型（比如 9B），但每个字要多走两次 Wi‑Fi，速度比单机跑同样大小的模型慢。")) {
                Button { role = "host" } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("主机").font(.headline)
                        Text("iPhone 15 Pro Max 这类内存大的手机：下载完整模型，在这里聊天").font(.footnote).foregroundColor(.secondary)
                    }
                }
                Button { role = "worker" } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("从机").font(.headline)
                        Text("iPhone 7 Plus（iOS 15 也行）：只下载自己那几层，保持亮屏待命").font(.footnote).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("小橘双机")
    }
}
