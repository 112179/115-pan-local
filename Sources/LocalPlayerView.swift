import SwiftUI
import UIKit

final class LocalSession: ObservableObject, PlayerDelegate {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var paused = true
    @Published var ready = false
    @Published var error: String?
    @Published var speedBytes: Double = 0
    @Published var tracks: [MPVTrack] = []
    @Published var ended = false

    weak var player: VLCPlayerViewController?
    var scrubbing = false

    func playbackReady(_ player: VLCPlayerViewController) {
        DispatchQueue.main.async {
            self.ready = true
            self.error = nil
        }
    }

    func playback(_ player: VLCPlayerViewController, snapshot: PlaybackSnapshot) {
        DispatchQueue.main.async {
            if snapshot.duration.isFinite, snapshot.duration > 0 {
                self.duration = snapshot.duration
            }
            if !self.scrubbing, snapshot.position.isFinite {
                self.position = max(0, snapshot.position)
            }
            self.paused = snapshot.paused
            self.speedBytes = snapshot.speedBytes.isFinite ? max(0, snapshot.speedBytes) : 0
        }
    }

    func playback(_ player: VLCPlayerViewController, tracks: [MPVTrack]) {
        DispatchQueue.main.async { self.tracks = tracks }
    }

    func playbackEnded(_ player: VLCPlayerViewController) {
        DispatchQueue.main.async { self.ended = true }
    }

    func playback(_ player: VLCPlayerViewController, failed message: String) {
        DispatchQueue.main.async {
            self.error = message
            self.ready = false
        }
    }
}

struct VLCView: UIViewControllerRepresentable {
    @ObservedObject var session: LocalSession
    let url: URL
    let userAgent: String
    let caching: Int
    let hardware: Bool

    func makeUIViewController(context: Context) -> VLCPlayerViewController {
        let controller = VLCPlayerViewController()
        controller.delegate = session
        controller.userAgent = userAgent
        controller.networkCaching = caching
        controller.hardwareDecode = hardware
        controller.playUrl = url
        session.player = controller
        return controller
    }

    func updateUIViewController(_ controller: VLCPlayerViewController, context: Context) {
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

                VLCView(session: session,
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
            HStack(spacing: 10) {
                Button {
                    if PlayerOrientation.isLandscape {
                        PlayerOrientation.apply(.portrait, force: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { dismiss() }
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .padding(9)
                }

                Text(title)
                    .font(.footnote)
                    .lineLimit(1)

                Spacer()

                if session.speedBytes > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .bold))
                        Text(NetSpeedText.text(session.speedBytes))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: Capsule())
                }

                Menu {
                    if !audioTracks.isEmpty {
                        Section("音轨") {
                            ForEach(audioTracks) { track in
                                Button {
                                    session.player?.selectTrack(track)
                                } label: {
                                    HStack {
                                        Text(track.displayName)
                                        if track.selected { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                    }

                    if !subTracks.isEmpty {
                        Section("字幕") {
                            Button("关闭字幕") { session.player?.disableSubtitles() }
                            ForEach(subTracks) { track in
                                Button {
                                    session.player?.selectTrack(track)
                                } label: {
                                    HStack {
                                        Text(track.displayName)
                                        if track.selected { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                    }

                    Section("播放速度") {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                            Button {
                                speed = value
                                session.player?.setSpeed(value)
                            } label: {
                                HStack {
                                    Text(String(format: "%gx", value))
                                    if abs(speed - value) < 0.01 { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 19))
                        .padding(8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 4)
            .background(Color.black.opacity(0.32))

            Spacer()

            VStack(spacing: 8) {
                Slider(value: sliderBinding,
                       in: 0...max(session.duration, 1),
                       onEditingChanged: { editing in
                           if editing {
                               scrubValue = session.position
                               scrubbing = true
                               session.scrubbing = true
                           } else {
                               scrubbing = false
                               session.scrubbing = false
                               session.player?.seek(to: scrubValue)
                           }
                       })
                .tint(.white)

                HStack(spacing: 18) {
                    Text(PlayerTime.text(session.position))
                        .font(.caption2)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .leading)

                    Spacer()

                    Button { session.player?.seek(by: -15) } label: {
                        Image(systemName: "gobackward.15").font(.title3)
                    }

                    Button { session.player?.togglePause() } label: {
                        Image(systemName: session.paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 27))
                            .frame(width: 46)
                    }

                    Button { session.player?.seek(by: 15) } label: {
                        Image(systemName: "goforward.15").font(.title3)
                    }

                    Spacer()

                    Text(PlayerTime.text(session.duration))
                        .font(.caption2)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }

                HStack {
                    Button {
                        PlayerOrientation.toggle()
                    } label: {
                        Label("横屏/竖屏", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 22)
            .background(Color.black.opacity(0.42))
        }
        .foregroundStyle(.white)
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

    private var sliderBinding: Binding<Double> {
        Binding(get: { scrubbing ? scrubValue : session.position },
                set: { scrubValue = $0 })
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
