import SwiftUI

// 第一次打开：三步引导。1 介绍 → 2 填两个令牌并测试 → 3 建第一个推送任务。
struct OnboardingView: View {
    @EnvironmentObject var store: Store
    @State private var page = 0
    @State private var testing = false
    @State private var cloudOK: String?
    @State private var githubOK: String?
    @State private var newTask: Mapping?

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                tokens.tag(1)
                firstTask.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: page)
            .onChange(of: page) { Haptics.select() }

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(i == page ? Theme.orange : Theme.border)
                        .frame(width: i == page ? 22 : 8, height: 8)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: page)
                }
            }
            .padding(.vertical, 16)

            Group {
                switch page {
                case 0:
                    Button("开始") { Haptics.tap(); page = 1 }.buttonStyle(BigButtonStyle(kind: .blue))
                case 1:
                    Button("下一步") { Haptics.tap(); page = 2 }.buttonStyle(BigButtonStyle(kind: .blue))
                        .disabled(!store.ready)
                default:
                    Button("建第一个推送任务") { Haptics.tap(); newTask = Mapping() }
                        .buttonStyle(BigButtonStyle(kind: .push))
                        .disabled(!store.ready)
                }
            }
            .padding(.horizontal, 16)
            Button(page == 2 ? "以后再建，先进去看看" : "跳过") { Haptics.tap(); store.onboarded = true }
                .font(.system(size: 15)).foregroundStyle(Theme.muted)
                .frame(minHeight: 44)
                .padding(.bottom, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(item: $newTask, onDismiss: {
            if !store.mappings.isEmpty { Haptics.success(); store.onboarded = true }
        }) { m in MappingEditView(mapping: m) }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.up")
                .font(.system(size: 44, weight: .bold)).foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(LinearGradient(colors: [Theme.orange, Color(red: 0.93, green: 0.42, blue: 0.13)],
                                           startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text("小橘推送").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 14) {
                feature("folder", "选一个小橘云盘文件夹，对应一个 GitHub 仓库")
                feature("doc.text.magnifyingglass", "自动找出改过的文件，逐行看改了什么")
                feature("arrow.up.circle", "勾选要推的文件，写好说明，一下推上去")
                feature("bell", "可以在后台检查，有改动就提醒你")
            }
            .padding(.horizontal, 28)
            Spacer()
        }
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.orangeText).frame(width: 28)
            Text(text).font(.system(size: 15)).foregroundStyle(Theme.text)
        }
    }

    private var tokens: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("填两个令牌").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 16).padding(.top, 40)
                Text("令牌只存在这台手机的钥匙串里。").font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 16)

                SectionTitle("小橘云盘（xa_ 开头，在网盘网页「Agent 令牌」里新建，只读就够）")
                SecureField("xa_…", text: $store.cloudToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).card()
                if let cloudOK { Text(cloudOK).font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.horizontal, 16) }

                SectionTitle("GitHub（Settings → Developer settings → Personal access tokens，要能写仓库）")
                SecureField("ghp_… 或 github_pat_…", text: $store.githubToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).card()
                if let githubOK { Text(githubOK).font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.horizontal, 16) }

                Button(testing ? "测试中…" : "测试连接") { test() }
                    .buttonStyle(BigButtonStyle(kind: .plain))
                    .disabled(testing || !store.ready)
                    .padding(.horizontal, 16).padding(.top, 16)
            }
        }
    }

    private var firstTask: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder.badge.plus").font(.system(size: 54)).foregroundStyle(Theme.blue)
            Text("建第一个推送任务").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
            Text("选一个云盘文件夹，再选推到哪个仓库。\n像 cloude审阅 这种不想提交的文件夹，可以设成「不推」。")
                .font(.system(size: 15)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private func test() {
        testing = true
        let e = store.engine()
        Task {
            do { cloudOK = "✓ 云盘已连接：\(try await e.checkCloud())" } catch { cloudOK = "✗ 云盘：\(error.localizedDescription)" }
            do { githubOK = "✓ GitHub 账号：\(try await e.whoami())" } catch { githubOK = "✗ GitHub：\(error.localizedDescription)" }
            testing = false
            if cloudOK?.hasPrefix("✓") == true && githubOK?.hasPrefix("✓") == true { Haptics.success() } else { Haptics.error() }
        }
    }
}
