import SwiftUI
import CoreImage

struct QRLoginView: View {
    @EnvironmentObject private var auth: AuthStore

    @State private var token: QRToken?
    @State private var status = 0
    @State private var message = ""
    @State private var loading = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text("115 云下载 Local")
                        .font(.title2.bold())
                    Text("App 内扫码，直连 115，不需要服务器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                qrView

                if UserDefaults.standard.bool(forKey: "needsReloginHint") {
                    Text("检测到旧版登录态，已自动退出，请重新扫码")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Text(statusText)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(status == 2 ? Color.green : Color.secondary)

                if !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await start() }
                } label: {
                    Label("刷新二维码", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(loading)

                Spacer()

                Text("登录态保存在本机 Keychain，退出后即清除。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
            .navigationBarHidden(true)
        }
        .task { await start() }
        .onDisappear { pollTask?.cancel() }
    }

    @ViewBuilder
    private var qrView: some View {
        if let token, let image = Self.makeQR(token.qrcode) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 220)
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        } else {
            ProgressView()
                .frame(width: 220, height: 220)
        }
    }

    private var statusText: String {
        switch status {
        case 0: return "打开 115 App → 扫一扫"
        case 1: return "已扫码，请在手机上确认"
        case 2: return "登录成功，正在保存…"
        case 3: return "二维码已过期，请刷新"
        case 4: return "已取消登录"
        case 5: return "登录失败，请刷新重试"
        default: return "等待扫码…"
        }
    }

    private func start() async {
        loading = true
        message = ""
        status = 0
        pollTask?.cancel()

        do {
            UserDefaults.standard.set(false, forKey: "needsReloginHint")
            token = try await API115.qrToken()
            status = 0
            pollTask = Task { await poll() }
        } catch {
            message = error.localizedDescription
        }
        loading = false
    }

    private func poll() async {
        guard let token else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }

            do {
                let value = try await API115.qrStatus(token)
                status = value

                if value == 2 {
                    let cookie = try await API115.qrLogin(uid: token.uid)
                    await MainActor.run {
                        auth.save(cookie: cookie)
                    }
                    return
                }
                if value >= 3 { return }
            } catch {
                message = error.localizedDescription
                return
            }
        }
    }

    static func makeQR(_ text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
