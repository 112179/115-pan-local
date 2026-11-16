import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthStore

    @State private var tests: [(String, Bool)] = []

    @AppStorage("player.longPress") private var longPress = "speed2"
    @AppStorage("player.doubleTap") private var doubleTap = 10
    @AppStorage("player.dragSpan") private var dragSpan = 180
    @AppStorage("player.autoHide") private var autoHide = 4
    @AppStorage("player.resume") private var resumeEnabled = true
    @AppStorage("player.caching") private var caching = 2
    @AppStorage("player.hardware") private var hardware = true

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        Form {
            Section("账号") {
                LabeledContent("状态", value: auth.isLoggedIn ? auth.accountName : "未登录")
                Button(role: .destructive) {
                    auth.logout()
                } label: {
                    Text("退出登录")
                }
            }

            Section("登录诊断") {
                LabeledContent("Cookie", value: auth.cookieKeys.isEmpty ? "无" : auth.cookieKeys)
                LabeledContent("UID 后缀", value: auth.uidSuffix)
            }

            Section {
                Picker("长按画面", selection: $longPress) {
                    Text("2× 倍速").tag("speed2")
                    Text("3× 倍速").tag("speed3")
                    Text("关闭").tag("none")
                }
                Picker("双击快进 / 快退", selection: $doubleTap) {
                    Text("5 秒").tag(5)
                    Text("10 秒").tag(10)
                    Text("15 秒").tag(15)
                    Text("30 秒").tag(30)
                }
                Picker("全屏拖动进度", selection: $dragSpan) {
                    Text("90 秒").tag(90)
                    Text("180 秒").tag(180)
                    Text("300 秒").tag(300)
                }
                Picker("控制条自动隐藏", selection: $autoHide) {
                    Text("2 秒").tag(2)
                    Text("4 秒").tag(4)
                    Text("8 秒").tag(8)
                    Text("不隐藏").tag(0)
                }
            } header: {
                Text("播放器")
            } footer: {
                Text("长按画面按设置临时加速，松手恢复；双击左右两侧快进/快退。")
            }

            Section {
                Toggle("断点续播", isOn: $resumeEnabled)
                Picker("缓冲时长", selection: $caching) {
                    Text("1 秒").tag(1)
                    Text("2 秒").tag(2)
                    Text("4 秒").tag(4)
                    Text("8 秒").tag(8)
                }
                Toggle("硬件解码", isOn: $hardware)
            } header: {
                Text("播放性能")
            } footer: {
                Text("缓冲越长越稳但起播稍慢；遇到花屏可关闭硬件解码。")
            }

            Section {
                ForEach(tests.indices, id: \.self) { index in
                    HStack {
                        Text(tests[index].0)
                        Spacer()
                        Text(tests[index].1 ? "通过" : "失败")
                            .foregroundStyle(tests[index].1 ? Color.green : Color.red)
                    }
                }
                Button("重新自检") { tests = Cipher115.selfTest() }
            } header: {
                Text("协议自检")
            } footer: {
                Text("校验 RSA / AES / LZ4 实现与 115 协议测试向量是否一致。")
            }

            Section("关于") {
                LabeledContent("版本", value: version)
                LabeledContent("模式", value: "115 直连（无服务器）")
                Link("项目主页", destination: URL(string: "https://github.com/112179/115-pan-local")!)
            }
        }
        .navigationTitle("设置")
        .onAppear {
            if tests.isEmpty { tests = Cipher115.selfTest() }
        }
    }
}
