import SwiftUI
import UIKit

@MainActor
final class LocalSession: ObservableObject, PlayerDelegate {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var paused = true
    @Published var ready = false
    @Published var error: String?
    @Published var speedBytes: Double = 0
    @Published var tracks: [MPVTrack] = []
    @Published var ended = false
    @Published var bufferPercent: Double = 0
    @Published var buffering = false
    @Published var format: String = ""

    weak var player: AetherPlayerViewController?
    var scrubbing = false

    func playbackReady(_ player: AetherPlayerViewController) {
        ready = true
        error = nil
    }

    func playback(_ player: AetherPlayerViewController, snapshot: PlaybackSnapshot) {
        if snapshot.duration.isFinite, snapshot.duration > 0 {
            duration = snapshot.duration
        }
        if !scrubbing, snapshot.position.isFinite {
            position = max(0, snapshot.position)
        }
        paused = snapshot.paused
        buffering = snapshot.pausedForCache
        bufferPercent = snapshot.bufferPercent.isFinite ? snapshot.bufferPercent : 0
        format = snapshot.format
        speedBytes = snapshot.speedBytes.isFinite ? max(0, snapshot.speedBytes) : 0
    }

    func playback(_ player: AetherPlayerViewController, tracks: [MPVTrack]) {
        self.tracks = tracks
    }

    func playbackEnded(_ player: AetherPlayerViewController) {
        ended = true
    }

    func playback(_ player: AetherPlayerViewController, failed message: String) {
        error = message
        ready = false
    }
}

struct PlayerSurfaceView: UIViewControllerRepresentable {
    @ObservedObject var session: LocalSession
    let url: URL
    let userAgent: String
    let caching: Int
    let hardware: Bool

    func makeUIViewController(context: Context) -> AetherPlayerViewController {
        let controller = AetherPlayerViewController()
        controller.delegate = session
        controller.userAgent = userAgent
        controller.networkCaching = caching
        controller.hardwareDecode = hardware
        controller.playUrl = url
        session.player = controller
        return controller
    }

    func updateUIViewController(_ controller: AetherPlayerViewController, context: Context) {
        session.player = controller
        controller.networkCaching = caching
        controller.hardwareDecode = hardware
        if controller.loadedURL != url {
            controller.userAgent = userAgent
            controller.load(url)
        }
    }
}

struct LocalPlayerView: View {
    let title: String
    let url: URL
    let pickcode: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = LocalSession()

    @State private var resumed = false

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var speed: Double = 1.0
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    @State private var hudText: String?
    @State private var hudTask: Task<Void, Never>?
    @State private var dragBase: Double?
    @State private var dragTarget: Double?
    @State private var tapTask: Task<Void, Never>?
    @State private var boosting = false

    @AppStorage("local.speed") private var savedSpeed: Double = 1.0
    @AppStorage("player.longPress") private var longPress = "speed2"
    @AppStorage("player.doubleTap") private var doubleTap = 10
    @AppStorage("player.dragSpan") private var dragSpan = 180
    @AppStorage("player.autoHide") private var autoHide = 4
    @AppStorage("player.resume") private var resumeEnabled = true
    @AppStorage("player.caching") private var caching = 2
    @AppStorage("player.hardware") private var hardware = true

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                PlayerSurfaceView(session: session,
                        url: url,
                        userAgent: API115.userAgent,
                        caching: caching,
                        hardware: hardware)
                    .ignoresSafeArea()

                gestures(size: geo.size)

                if let hudText {
                    Text(hudText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.6), in: Capsule())
                        .allowsHitTesting(false)
                }

            if !session.ready && session.error == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .allowsHitTesting(false)
            }

            if let message = session.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.yellow)
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.85))
                    Button("用其他方式重试") {
                        session.error = nil
                        session.ready = false
                        session.player?.load(url)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(22)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
                .padding(30)
            }

                if showControls {
                    controls
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            PlayerOrientation.allowAll()
            speed = savedSpeed
            scheduleHide()
        }
        .onChange(of: speed) { _, value in
            savedSpeed = value
        }
        .onChange(of: session.ready) { _, ready in
            if ready, !resumed {
                resumed = true
                session.player?.setSpeed(speed)
                resumeIfNeeded()
            }
        }
        .task { await saveLoop() }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            savePosition()
            PlayerOrientation.apply(.portrait, force: PlayerOrientation.isLandscape)
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { closePlayer() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if !session.format.isEmpty {
                        Text(session.format)
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.6)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.18), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 0.5))
                    }
                    if session.buffering {
                        Text("缓冲中…")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }

            Spacer(minLength: 0)

            Menu { trackMenu } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .background(
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.4), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    @ViewBuilder
    private var trackMenu: some View {
        if !audioTracks.isEmpty {
            Section("音轨") {
                ForEach(audioTracks) { track in
                    Button {
                        session.player?.selectTrack(track)
                    } label: {
                        Label(track.displayName, systemImage: track.selected ? "checkmark" : "waveform")
                    }
                }
            }
        }

        if !subTracks.isEmpty {
            Section("字幕") {
                Button {
                    session.player?.disableSubtitles()
                } label: {
                    Label("关闭字幕", systemImage: "captions.bubble")
                }
                ForEach(subTracks) { track in
                    Button {
                        session.player?.selectTrack(track)
                    } label: {
                        Label(track.displayName, systemImage: track.selected ? "checkmark" : "captions.bubble")
                    }
                }
            }
        }

        Section("画面") {
            Button {
                PlayerOrientation.toggle()
            } label: {
                Label(PlayerOrientation.isLandscape ? "竖屏" : "横屏", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            PlayerScrubBar(position: scrubDisplay,
                           duration: max(session.duration, 0.01),
                           buffered: session.bufferPercent,
                           onEditing: handleScrub)
                .padding(.horizontal, 2)

            HStack {
                Text(PlayerTime.text(scrubDisplay))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                Spacer()
                Text(PlayerTime.text(session.duration))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 6)

            HStack(spacing: 0) {
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                        Button {
                            speed = value
                            session.player?.setSpeed(value)
                        } label: {
                            Label(String(format: "%g×", value),
                                  systemImage: abs(speed - value) < 0.01 ? "checkmark" : "gauge")
                        }
                    }
                } label: {
                    Text(String(format: "%g×", speed))
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 58, height: 32)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Spacer(minLength: 0)

                Button { session.player?.seek(by: -15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 25, weight: .regular))
                        .frame(width: 48, height: 48)
                }

                Spacer(minLength: 0)

                Button { session.player?.togglePause() } label: {
                    Image(systemName: session.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .offset(x: session.paused ? 2 : 0)
                        .frame(width: 62, height: 62)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                }

                Spacer(minLength: 0)

                Button { session.player?.seek(by: 15) } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 25, weight: .regular))
                        .frame(width: 48, height: 48)
                }

                Spacer(minLength: 0)

                Button { PlayerOrientation.toggle() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 58, height: 32)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 24)
        .padding(.bottom, 26)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var scrubDisplay: Double {
        scrubbing ? scrubValue : session.position
    }

    private func handleScrub(_ editing: Bool, _ value: Double) {
        scrubValue = value
        if editing {
            scrubbing = true
            session.scrubbing = true
        } else {
            scrubbing = false
            session.scrubbing = false
            session.player?.seek(to: value)
        }
        scheduleHide()
    }

    private func closePlayer() {
        if PlayerOrientation.isLandscape {
            PlayerOrientation.apply(.portrait, force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { dismiss() }
        } else {
            dismiss()
        }
    }

    private func gestures(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { scheduleToggle() }
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                handleDoubleTap(value.location, size)
            })
            .simultaneousGesture(seekGesture(size))
            .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 30) {
            } onPressingChanged: { pressing in
                guard longPress != "none" else { return }
                let boost: Double = longPress == "speed3" ? 3.0 : 2.0
                boosting = pressing
                session.player?.setSpeed(pressing ? boost : speed)
                if pressing { showHUD(String(format: "%g× 倍速", boost)) }
            }
    }

    private func seekGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 22)
            .onChanged { value in
                guard session.duration > 1 else { return }
                if dragBase == nil {
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    dragBase = session.position
                    hideTask?.cancel()
                }
                guard let base = dragBase else { return }
                let delta = Double(value.translation.width / max(size.width, 1)) * Double(max(dragSpan, 30))
                let target = min(max(base + delta, 0), session.duration)
                dragTarget = target
                let deltaSeconds = Int(target - base)
                let sign = deltaSeconds >= 0 ? "+" : ""
                hudText = "\(sign)\(deltaSeconds)s  \(PlayerTime.text(target))"
            }
            .onEnded { _ in
                if let target = dragTarget {
                    session.player?.seek(to: target)
                }
                dragBase = nil
                dragTarget = nil
                hudText = nil
                scheduleHide()
            }
    }

    private func scheduleToggle() {
        tapTask?.cancel()
        tapTask = Task {
            try? await Task.sleep(nanoseconds: 260_000_000)
            if Task.isCancelled { return }
            await MainActor.run { toggleControls() }
        }
    }

    private func handleDoubleTap(_ point: CGPoint, _ size: CGSize) {
        tapTask?.cancel()
        if point.x < size.width * 0.3 {
            session.player?.seek(by: -Double(doubleTap))
            showHUD("⏪ \(doubleTap) 秒")
        } else if point.x > size.width * 0.7 {
            session.player?.seek(by: Double(doubleTap))
            showHUD("⏩ \(doubleTap) 秒")
        } else {
            session.paused.toggle()
            session.player?.togglePause()
            showHUD(session.paused ? "▶ 播放" : "⏸ 暂停")
        }
    }

    private func showHUD(_ text: String) {
        hudTask?.cancel()
        hudText = text
        hudTask = Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if Task.isCancelled { return }
            await MainActor.run { hudText = nil }
        }
    }

    private var audioTracks: [MPVTrack] {
        session.tracks.filter { $0.type == "audio" }
    }

    private var subTracks: [MPVTrack] {
        session.tracks.filter { $0.type == "sub" }
    }

    private func resumeIfNeeded() {
        guard resumeEnabled else { return }
        let saved = UserDefaults.standard.double(forKey: "local.pos.\(pickcode)")
        guard saved > 10, session.duration > saved + 20 else { return }
        session.player?.seek(to: saved)
    }

    private func savePosition() {
        guard !pickcode.isEmpty else { return }
        let position = session.position
        guard position > 15, session.duration > 60 else { return }
        if position > session.duration - 30 {
            UserDefaults.standard.removeObject(forKey: "local.pos.\(pickcode)")
        } else {
            UserDefaults.standard.set(position, forKey: "local.pos.\(pickcode)")
        }
    }

    private func saveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { break }
            savePosition()
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls.toggle()
        }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard autoHide > 0 else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(autoHide) * 1_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
            }
        }
    }
}

enum PlayerTime {
    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

enum NetSpeedText {
    static func text(_ bytes: Double) -> String {
        guard bytes > 0, bytes.isFinite else { return "--" }
        let kb = bytes / 1024
        if kb >= 1024 { return String(format: "%.1f MB/s", kb / 1024) }
        return String(format: "%.0f KB/s", kb)
    }
}


/// 带缓冲进度的自定义进度条（比系统 Slider 更贴近播放器习惯）
struct PlayerScrubBar: View {
    var position: Double
    var duration: Double
    var buffered: Double        // 0...100
    var onEditing: (Bool, Double) -> Void

    @State private var dragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let shown = dragging ? dragValue : position
            let fraction = CGFloat(duration > 0 ? min(max(shown / duration, 0), 1) : 0)
            let bufferFraction = CGFloat(min(max(buffered / 100, 0), 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: 4)

                Capsule()
                    .fill(.white.opacity(0.32))
                    .frame(width: width * bufferFraction, height: 4)

                Capsule()
                    .fill(.white)
                    .frame(width: width * fraction, height: 4)

                Circle()
                    .fill(.white)
                    .frame(width: dragging ? 16 : 11, height: dragging ? 16 : 11)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: width * fraction - (dragging ? 8 : 5.5))
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let target = valueAt(value.location.x, width)
                        if !dragging {
                            dragging = true
                            onEditing(true, target)
                        }
                        dragValue = target
                    }
                    .onEnded { value in
                        let target = valueAt(value.location.x, width)
                        dragValue = target
                        dragging = false
                        onEditing(false, target)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 30)
    }

    private func valueAt(_ x: CGFloat, _ width: CGFloat) -> Double {
        let ratio = min(max(x / width, 0), 1)
        return Double(ratio) * duration
    }
}
