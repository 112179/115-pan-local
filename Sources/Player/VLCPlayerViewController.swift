import UIKit
import AVFoundation
import MobileVLCKit

struct PlaybackSnapshot {
    var position: Double = 0
    var duration: Double = 0
    var paused: Bool = true
    var speedBytes: Double = 0
    var bufferPercent: Double = 0
    var cacheSeconds: Double = 0
    var pausedForCache: Bool = false
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

protocol PlayerDelegate: AnyObject {
    func playbackReady(_ player: VLCPlayerViewController)
    func playback(_ player: VLCPlayerViewController, snapshot: PlaybackSnapshot)
    func playback(_ player: VLCPlayerViewController, tracks: [MPVTrack])
    func playbackEnded(_ player: VLCPlayerViewController)
    func playback(_ player: VLCPlayerViewController, failed message: String)
}

/// VLC（MobileVLCKit）播放内核。
/// 视频渲染由 VLC 自己的 vout 负责，旋转时随 drawable 视图尺寸变化，不需要重建输出。
final class VLCPlayerViewController: UIViewController, VLCMediaPlayerDelegate {
    weak var delegate: PlayerDelegate?

    var playUrl: URL?
    var userAgent: String?
    var networkCaching: Int = 2
    var hardwareDecode: Bool = true
    private(set) var loadedURL: URL?

    private let player = VLCMediaPlayer()
    private let canvas = UIView()
    private var timer: Timer?

    private var lastBytes: Int64 = 0
    private var lastStamp = Date()
    private var measuredSpeed: Double = 0
    private var readySent = false
    private var endedSent = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        canvas.backgroundColor = .black
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.frame = view.bounds
        view.addSubview(canvas)

        player.drawable = canvas
        player.delegate = self

        activateAudioSession()
        startTimer()

        if let url = playUrl {
            load(url)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        canvas.frame = view.bounds
    }

    deinit {
        timer?.invalidate()
        player.stop()
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
        try? session.setActive(true)
    }

    // MARK: - 载入

    func load(_ url: URL) {
        loadedURL = url
        readySent = false
        endedSent = false
        lastBytes = 0
        lastStamp = Date()
        measuredSpeed = 0

        let media = VLCMedia(url: url)
        if let ua = userAgent, !ua.isEmpty {
            // 115 直链要求 UA 与解析时一致
            media.addOption(":http-user-agent=\(ua)")
        }
        let caching = max(1, min(networkCaching, 30)) * 1000
        media.addOption(":network-caching=\(caching)")
        media.addOption(":file-caching=\(min(caching, 3000))")
        media.addOption(":http-reconnect=true")
        // 性能相关：硬解优先、减少时钟抖动导致的卡顿
        media.addOption(hardwareDecode ? ":avcodec-hw=any" : ":avcodec-hw=none")
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")

        player.media = media
        player.play()
        refreshTracksSoon()
    }

    // MARK: - 控制

    func togglePause() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func setPaused(_ paused: Bool) {
        if paused {
            player.pause()
        } else {
            player.play()
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let clamped = max(0, seconds)
        let ms = Int32(min(clamped, 86_400) * 1000)
        player.time = VLCTime(int: ms)
    }

    func seek(by delta: Double) {
        let target = max(0, currentSeconds + delta)
        seek(to: target)
    }

    func setSpeed(_ speed: Double) {
        player.rate = Float(speed)
    }

    func selectTrack(_ track: MPVTrack) {
        if track.type == "audio" {
            player.currentAudioTrackIndex = Int32(track.id)
        } else {
            player.currentVideoSubTitleIndex = Int32(track.id)
        }
        refreshTracksSoon()
    }

    func disableSubtitles() {
        player.currentVideoSubTitleIndex = -1
        refreshTracksSoon()
    }

    func refreshTracksSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.delegate?.playback(self, tracks: self.loadTracks())
        }
    }

    // MARK: - 数据

    private var currentSeconds: Double {
        (player.time.value?.doubleValue ?? 0) / 1000
    }

    private var durationSeconds: Double {
        (player.media?.length.value?.doubleValue ?? 0) / 1000
    }

    private func loadTracks() -> [MPVTrack] {
        var result: [MPVTrack] = []

        let audioNames = (player.audioTrackNames as? [String]) ?? []
        let audioIDs = (player.audioTrackIndexes as? [NSNumber]) ?? []
        for (index, value) in audioIDs.enumerated() where value.intValue >= 0 {
            let name = index < audioNames.count ? audioNames[index] : ""
            result.append(MPVTrack(id: value.intValue,
                                   type: "audio",
                                   title: name,
                                   lang: "",
                                   selected: player.currentAudioTrackIndex == value.int32Value))
        }

        let subNames = (player.videoSubTitlesNames as? [String]) ?? []
        let subIDs = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        for (index, value) in subIDs.enumerated() where value.intValue >= 0 {
            let name = index < subNames.count ? subNames[index] : ""
            result.append(MPVTrack(id: value.intValue,
                                   type: "sub",
                                   title: name,
                                   lang: "",
                                   selected: player.currentVideoSubTitleIndex == value.int32Value))
        }

        return result
    }

    private func updateSpeed() {
        guard let media = player.media else { return }
        let stats = media.statistics
        let total = Int64(stats.readBytes)
        let now = Date()
        let delta = now.timeIntervalSince(lastStamp)
        guard delta > 0.25 else { return }

        if lastBytes > 0, total >= lastBytes {
            measuredSpeed = Double(total - lastBytes) / delta
        } else if total < lastBytes {
            measuredSpeed = 0
        }
        lastBytes = total
        lastStamp = now
    }

    private func report() {
        updateSpeed()

        let state = player.state
        let buffering = state == .buffering || state == .opening
        let paused = state == .paused || state == .stopped

        let snapshot = PlaybackSnapshot(
            position: currentSeconds,
            duration: durationSeconds,
            paused: paused,
            speedBytes: measuredSpeed,
            bufferPercent: buffering ? 0 : 100,
            cacheSeconds: 0,
            pausedForCache: buffering
        )
        delegate?.playback(self, snapshot: snapshot)
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.report()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let state = self.player.state

            switch state {
            case .playing:
                if !self.readySent {
                    self.readySent = true
                    self.delegate?.playbackReady(self)
                    self.refreshTracksSoon()
                }
            case .ended:
                if !self.endedSent {
                    self.endedSent = true
                    self.delegate?.playbackEnded(self)
                }
            case .error:
                self.delegate?.playback(self, failed: "VLC 播放失败：格式不支持或网络异常")
            default:
                break
            }

            self.report()
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        report()
    }
}
