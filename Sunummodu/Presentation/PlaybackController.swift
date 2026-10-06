import AVFoundation
import Observation

/// Tek bir `AVPlayer` yönetir; çıkış penceresi ve sunucu önizlemesi aynı oynatıcıyı gösterir.
@Observable
final class PlaybackController {
    static let volumeStep: Float = 0.1
    private static let volumeKey = "volume"

    @ObservationIgnored let player = AVPlayer()
    private(set) var hasVideo = false
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var volume: Float
    private(set) var isMuted = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        volume = defaults.object(forKey: Self.volumeKey) == nil ? 1 : defaults.float(forKey: Self.volumeKey)
        player.volume = volume
        // Video bitince son karede kalır.
        player.actionAtItemEnd = .pause
        player.allowsExternalPlayback = false

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTimeChanged(time.seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.syncPlayingState() }
        }
    }

    /// `url` nil ise oynatıcıyı boşaltır (resim slaytı).
    func load(_ url: URL?, duration knownDuration: Double? = nil, autoplay: Bool = false) {
        player.pause()
        isScrubbing = false
        currentTime = 0
        guard let url else {
            player.replaceCurrentItem(with: nil)
            hasVideo = false
            duration = 0
            return
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        hasVideo = true
        duration = knownDuration ?? 0
        Task { [weak self] in
            guard let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite else { return }
            guard let self, self.player.currentItem === item else { return }
            self.duration = seconds
        }
        if autoplay {
            player.play()
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard hasVideo else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            // Sondayken Başlat'a basılırsa baştan oynatılır.
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
        }
        player.play()
    }

    func pause() {
        player.pause()
    }

    // MARK: İlerleme çubuğu

    func beginScrubbing() {
        guard hasVideo, !isScrubbing else { return }
        isScrubbing = true
        resumeAfterScrub = isPlaying
        player.pause()
    }

    func scrub(to seconds: Double) {
        guard hasVideo else { return }
        currentTime = min(max(seconds, 0), duration)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: cmTime(currentTime), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        player.seek(to: cmTime(currentTime), toleranceBefore: .zero, toleranceAfter: .zero)
        if resumeAfterScrub {
            player.play()
        }
    }

    // MARK: Ses

    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        player.volume = volume
        defaults.set(volume, forKey: Self.volumeKey)
        if volume > 0, isMuted {
            toggleMute()
        }
    }

    func adjustVolume(by delta: Float) {
        setVolume(((volume + delta) * 10).rounded() / 10)
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    private func playerTimeChanged(_ seconds: Double) {
        guard !isScrubbing, seconds.isFinite else { return }
        currentTime = seconds
    }

    private func syncPlayingState() {
        isPlaying = player.timeControlStatus != .paused
    }

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
