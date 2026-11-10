import SwiftUI

// 首页「工具」→ 云控（以前在设置里）：这台去调用别的设备（法莉娅安卓、iPhone 被控端 Vania）。
// 以前这里还有「被控端」（这台被别人调用），用的人少，2026-11 删掉了，被控端用 Vania / 法莉娅。
struct RemoteView: View {
    var body: some View {
        RemoteControlView()
            .navigationTitle("云控")
            .navigationBarTitleDisplayMode(.inline)
    }
}
