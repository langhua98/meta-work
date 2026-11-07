import SwiftUI

// 双机推理：两台手机合跑一个装不下的模型（Qwen3.5-9B）。
// 推理核心、Metal 内核、主机 / 从机界面都和 src/xiaoju-pipe/ 是同一份代码（project.yml 里直接引用），
// 这里只是入口。iPhone 7 Plus 只能到 iOS 15，装不了小橘推送（最低 iOS 17），它装单独的「小橘双机」当从机；
// 两边握手协议一样，可以混着用。
struct PipeHomeView: View {
    @AppStorage("pipe.role") private var role = ""

    var body: some View {
        Group {
            if role == "host" { HostView() }
            else if role == "worker" { WorkerView() }
            else { picker }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !role.isEmpty { Button("换角色") { role = "" } }
            }
        }
    }

    private var picker: some View {
        List {
            Section {
                Button { role = "host" } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("这台当主机").font(.headline)
                        Text("15 Pro Max 这类内存大的手机：下载完整模型，在这里聊天").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button { role = "worker" } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("这台当从机").font(.headline)
                        Text("另一台 iOS 17 以上的手机：只下载中间几层，保持亮屏待命").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("两台手机连同一个 Wi‑Fi（一台开热点、另一台连上也行）。主机算前后几层和输出头，从机用 GPU 算中间几层，模型只在两台手机上跑，不经过互联网。\n\niPhone 7 Plus 这类 iOS 15 的手机装不了小橘推送，请装「小橘双机」当从机（Release「xiaoju-pipe」或小橘云盘「软件包」里），两边可以互连。")
            }
        }
        .navigationTitle("双机推理")
    }
}
