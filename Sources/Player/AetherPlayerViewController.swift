import AVFoundation
import Combine
import SwiftUI
import UIKit
import AetherEngine

struct PlaybackSnapshot {
    var position: Double = 0
    var duration: Double = 0
    var paused: Bool = true
    var speedBytes: Double = 0
    var bufferPercent: Double = 0
    var cacheSeconds: Double = 0
    var pausedForCache: Bool = false
    var format: String = ""
    var startupFraction: Double = 0
    var stageText: String = ""
}

struct MPVTrack: Identifiable, Hashable {
    let id: Int
    let type: String      // audio / sub
    let title: String
    let lang: String
    let selected: Bool

    var displayName: String {
        if !title.isEmpty { return title }
        if !lang.isEmpty { return lang.uppercased() }
        return type == "audio" ? "音轨 \(id)" : "字幕 \(id)"
    }
}

@MainActor
protocol PlayerDelegate: AnyObject {
    func playbackReady(_ player: AetherPlayerViewController)
    func playback(_ player: AetherPlayerViewController, snapshot: PlaybackSnapshot)
    func playback(_ player: AetherPlayerViewController, tracks: [MPVTrack])
    func playbackEnded(_ player: AetherPlayerViewController)
    func playback(_ player: AetherPlayerViewController, failed message: String)
}

/// 全局唯一的播放引擎（AetherEngine 设计上就是长生命周期实例）
@MainActor
enum PlaybackEngine {
    static let shared: AetherEngine? = {
        do {
            return try AetherEngine()
        } catch {
            print("AetherEngine init failed: \(error)")
            return nil
        }
    }()
}

/// AetherEngine 播放内核。
/// 原生路径由 AVPlayer 出画、软件路径由 dav1d/ffmpeg 解码，引擎自己切换图层；
/// 字幕（文本/ASS/PGS）由引擎解码成 cue，这里画在自己的 overlay 上。
final class AetherPlayerViewController: UIViewController {
    weak var delegate: PlayerDelegate?

    var playUrl: URL?
    var userAgent: String?
    var networkCaching: Int = 2
    var hardwareDecode: Bool = true
    private(set) var loadedURL: URL?

    private var engine: AetherEngine? { PlaybackEngine.shared }
    private let surface = AetherPlayerView()
    private let subtitleOverlay = SubtitleOverlayView()
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var readySent = false
    private var endedSent = false
    private var selectedSubID: Int?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        surface.frame = view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.backgroundColor = .black
        view.addSubview(surface)

        subtitleOverlay.frame = view.bounds
        subtitleOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        subtitleOverlay.isUserInteractionEnabled = false
        subtitleOverlay.backgroundColor = .clear
        view.addSubview(subtitleOverlay)

        if let engine {
            engine.bind(view: surface)
            observe(engine)
        } else {
            delegate?.playback(self, failed: "播放内核初始化失败，请重启 App")
        }

        activateAudioSession()
        startTimer()

        if let url = playUrl {
            load(url)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        surface.frame = view.bounds
        subtitleOverlay.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
    }

    // MARK: - 观察引擎

    private func observe(_ engine: AetherEngine) {
        engine.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .playing, .paused:
                    if !self.readySent {
                        self.readySent = true
                        self.delegate?.playbackReady(self)
                        self.pushTracks()
                    }
                case .ended:
                    if !self.endedSent {
                        self.endedSent = true
                        self.delegate?.playbackEnded(self)
                    }
                case .error(let message):
                    self.delegate?.playback(self, failed: message)
                default:
                    break
                }
                self.report()
            }
            .store(in: &bag)

        engine.$audioTracks
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushTracks() }
            .store(in: &bag)

        engine.$subtitleTracks
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pushTracks() }
            .store(in: &bag)

        engine.$subtitleCues
            .receive(on: RunLoop.main)
            .sink { [weak self] cues in
                self?.subtitleOverlay.cues = cues
            }
            .store(in: &bag)

        engine.clock.$sourceTime
            .receive(on: RunLoop.main)
            .sink { [weak self] time in
                self?.subtitleOverlay.time = time
            }
            .store(in: &bag)
    }

    // MARK: - 载入

    func load(_ url: URL) {
        guard let engine else { return }
        loadedURL = url
        readySent = false
        endedSent = false

        var headers: [String: String] = [:]
        if let ua = userAgent, !ua.isEmpty {
            // 115 直链要求 UA 与解析时一致
            headers["User-Agent"] = ua
        }
        let options = LoadOptions(httpHeaders: headers)

        Task { @MainActor in
            do {
                try await engine.load(url: url, options: options)
            } catch is CancellationError {
                // 被新的 load 顶掉，不是错误
            } catch {
                self.delegate?.playback(self, failed: "播放失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 控制

    func togglePause() {
        engine?.togglePlayPause()
    }

    func setPaused(_ paused: Bool) {
        if paused { engine?.pause() } else { engine?.play() }
    }

    func seek(to seconds: Double) {
        guard let engine, seconds.isFinite else { return }
        let clamped = max(0, seconds)
        Task { await engine.seek(to: clamped) }
    }

    func seek(by delta: Double) {
        seek(to: currentSeconds + delta)
    }

    func setSpeed(_ speed: Double) {
        engine?.setRate(Float(speed))
    }

    func selectTrack(_ track: MPVTrack) {
        guard let engine else { return }
        if track.type == "audio" {
            engine.selectAudioTrack(index: track.id)
        } else {
            engine.selectSubtitleTrack(index: track.id)
            selectedSubID = track.id
        }
        pushTracks()
    }

    func disableSubtitles() {
        engine?.clearSubtitle()
        selectedSubID = nil
        pushTracks()
    }

    // MARK: - 数据

    private var currentSeconds: Double {
        engine?.clock.currentTime ?? 0
    }

    private var durationSeconds: Double {
        guard let value = engine?.duration, value.isFinite else { return 0 }
        return max(0, value)
    }

    private func pushTracks() {
        guard let engine else { return }
        var list: [MPVTrack] = []
        for track in engine.audioTracks {
            list.append(MPVTrack(id: track.id,
                                 type: "audio",
                                 title: track.name,
                                 lang: track.language ?? "",
                                 selected: engine.activeAudioTrackIndex == track.id))
        }
        for track in engine.subtitleTracks {
            list.append(MPVTrack(id: track.id,
                                 type: "sub",
                                 title: track.name,
                                 lang: track.language ?? "",
                                 selected: selectedSubID == track.id))
        }
        delegate?.playback(self, tracks: list)
    }

    private func report() {
        guard let engine else { return }
        let state = engine.state
        let paused: Bool
        switch state {
        case .playing: paused = false
        default: paused = true
        }
        let duration = durationSeconds
        let buffered = Double(engine.clock.bufferedPosition)
        let percent = duration > 0 ? min(100, max(0, buffered / duration * 100)) : 0

        let throughput = engine.liveTelemetry?.networkThroughputMbps ?? 0
        let progress = engine.startupProgress

        let snapshot = PlaybackSnapshot(
            position: currentSeconds,
            duration: duration,
            paused: paused,
            speedBytes: max(0, throughput) * 125_000,
            bufferPercent: percent,
            cacheSeconds: max(0, buffered - currentSeconds),
            pausedForCache: engine.isBuffering,
            format: formatLabel(engine.videoFormat),
            startupFraction: progress?.fraction ?? 0,
            stageText: stageLabel(progress?.stage)
        )
        delegate?.playback(self, snapshot: snapshot)
    }

    private func stageLabel(_ stage: StartupStage?) -> String {
        guard let stage else { return "准备中…" }
        switch stage {
        case .connecting: return "连接服务器"
        case .openingContainer: return "读取文件信息"
        case .analyzingStreams: return "分析音视频流"
        case .preparingDisplay: return "准备显示"
        case .selectingRoute: return "选择播放通路"
        case .buildingSession: return "建立播放会话"
        case .preparingPlayback: return "准备起播"
        case .awaitingFirstFrame: return "等待首帧"
        case .presenting: return "即将开始"
        default: return "加载中…"
        }
    }

    private func formatLabel(_ format: VideoFormat) -> String {
        switch format {
        case .dolbyVision: return "DOLBY VISION"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .hlg: return "HLG"
        default: return ""
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.report() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

// MARK: - 字幕绘制

/// 把引擎解出的字幕 cue（文本 / 富文本 / PGS 位图）画在视频上
final class SubtitleOverlayView: UIView {
    var cues: [SubtitleCue] = [] {
        didSet { setNeedsDisplay() }
    }
    var time: Double = 0 {
        didSet {
            if abs(time - oldValue) > 0.001 { setNeedsDisplay() }
        }
    }

    override func draw(_ rect: CGRect) {
        let active = cues.filter { time >= $0.startTime && time < $0.endTime }
        guard !active.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }

        for cue in active {
            switch cue.body {
            case .text(let text):
                draw(text: styled(text), placement: cue.placement)
            case .richText(let runs):
                draw(text: attributed(from: runs), placement: cue.placement)
            case .image(let image):
                draw(image: image, in: context)
            }
        }
    }

    private func styled(_ text: String) -> NSAttributedString {
        attributed(from: [SubtitleTextRun(text: text, color: nil)])
    }

    private func attributed(from runs: [SubtitleTextRun]) -> NSAttributedString {
        let base = UIFont.systemFont(ofSize: 19, weight: .semibold)
        let result = NSMutableAttributedString()
        for run in runs {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if run.isBold { traits.insert(.traitBold) }
            if run.isItalic { traits.insert(.traitItalic) }
            var font = base
            if !traits.isEmpty, let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: descriptor, size: base.pointSize)
            }
            var color = UIColor.white
            if let c = run.color {
                color = UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .strokeColor: UIColor.black,
                .strokeWidth: -4.0
            ]
            if run.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.isStruckThrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private func draw(text: NSAttributedString, placement: SubtitleTextPlacement?) {
        let maxWidth = bounds.width - 48
        let width = min(maxWidth, text.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   context: nil).width + 8)
        let size = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                     context: nil).size

        var rect: CGRect
        if let anchor = placement?.position {
            let alignment = placement?.alignment ?? 2
            let column = (alignment - 1) % 3   // 0 left, 1 center, 2 right
            let row = (alignment - 1) / 3      // 0 bottom, 1 middle, 2 top
            let x = anchor.x * bounds.width
            let y = anchor.y * bounds.height
            let originX = column == 0 ? x : (column == 2 ? x - size.width : x - size.width / 2)
            let originY = row == 0 ? y - size.height : (row == 2 ? y : y - size.height / 2)
            rect = CGRect(x: originX, y: originY, width: size.width, height: size.height)
        } else {
            let margin = max(24, bounds.height * 0.075)
            rect = CGRect(x: (bounds.width - size.width) / 2,
                          y: bounds.height - size.height - margin,
                          width: size.width,
                          height: size.height)
        }
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    private func draw(image: SubtitleImage, in context: CGContext) {
        let canvas = image.canvasSize == .zero ? bounds.size : image.canvasSize
        guard canvas.width > 0, canvas.height > 0 else { return }
        let scaleX = bounds.width / canvas.width
        let scaleY = bounds.height / canvas.height
        let rect = CGRect(x: image.position.minX * scaleX,
                          y: image.position.minY * scaleY,
                          width: image.position.width * scaleX,
                          height: image.position.height * scaleY)
        context.saveGState()
        context.translateBy(x: 0, y: rect.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -rect.midY)
        context.draw(image.cgImage, in: rect)
        context.restoreGState()
    }
}
