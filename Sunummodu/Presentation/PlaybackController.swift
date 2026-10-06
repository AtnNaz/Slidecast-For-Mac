import AVFoundation
import Observation

/// Video ve ses oynatımını yönetir. Çıkış penceresi ve sunucu önizlemesi aynı oynatıcıyı gösterir.
///
/// İki oynatıcı sırayla kullanılır: slayt değişince yeni slayt öbür oynatıcıya yüklenir, eskisi kendi
/// oynatıcısında kalır. Böylece yumuşak geçiş sürerken giden videonun görüntüsü kaybolmaz.
@Observable
final class PlaybackController {
    static let volumeStep: Float = 0.1
    private static let volumeKey = "volume"

    @ObservationIgnored private let players = [AVPlayer(), AVPlayer()]
    private var activeIndex = 0
    /// Gösterilen slaytın oynatıcısı.
    var player: AVPlayer { players[activeIndex] }

    private(set) var hasMedia = false
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var volume: Float
    private(set) var isMuted = false

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var timeObservers: [Any] = []
    @ObservationIgnored private var statusObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false
    /// Sesi kısılarak kapanmakta olan (giden) oynatıcı.
    @ObservationIgnored private var fadingPlayer: AVPlayer?
    @ObservationIgnored private var fadeTask: Task<Void, Never>?

    init(settings: SettingsStore = UserDefaults.standard) {
        self.settings = settings
        volume = Float(settings.number(forKey: Self.volumeKey) ?? 1)

        for (index, player) in players.enumerated() {
            player.volume = volume
            // Video bitince son karede kalır.
            player.actionAtItemEnd = .pause
            player.allowsExternalPlayback = false
            timeObservers.append(player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 10), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.playerTimeChanged(time.seconds, from: index) }
            })
            statusObservations.append(player.observe(\.timeControlStatus) { [weak self] _, _ in
                Task { @MainActor in self?.syncPlayingState() }
            })
        }
    }

    /// Yeni slaytın medyasını yükler; `url` nil ise oynatılacak bir şey yoktur (resim slaytı).
    /// `fadeOut` sıfırdan büyükse giden slayt bu süre boyunca oynamayı sürdürür ve sesi kısılarak kapanır.
    func load(_ url: URL?, duration knownDuration: Double? = nil, autoplay: Bool = false, fadeOut: Double = 0) {
        finishFade()
        retire(player, over: fadeOut)
        activeIndex = 1 - activeIndex

        let incoming = player
        incoming.pause()
        incoming.volume = volume
        incoming.isMuted = isMuted
        isScrubbing = false
        currentTime = 0
        defer { syncPlayingState() }
        guard let url else {
            incoming.replaceCurrentItem(with: nil)
            hasMedia = false
            duration = 0
            return
        }
        let item = AVPlayerItem(url: url)
        incoming.replaceCurrentItem(with: item)
        hasMedia = true
        duration = knownDuration ?? 0
        Task { [weak self] in
            guard let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite else { return }
            guard let self, self.player.currentItem === item else { return }
            self.duration = seconds
        }
        if autoplay {
            incoming.play()
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
        guard hasMedia else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            // Sondayken Başlat'a basılırsa baştan oynatılır.
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
        }
        player.play()
    }

    /// Gösterilen slaytı duraklatır; kapanmakta olan önceki slayt varsa onu da hemen susturur.
    func pause() {
        finishFade()
        player.pause()
    }

    // MARK: İlerleme çubuğu

    func beginScrubbing() {
        guard hasMedia, !isScrubbing else { return }
        isScrubbing = true
        resumeAfterScrub = isPlaying
        player.pause()
    }

    func scrub(to seconds: Double) {
        guard hasMedia else { return }
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
        settings.setNumber(Double(volume), forKey: Self.volumeKey)
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

    // MARK: Giden slayt

    /// Giden oynatıcıyı hemen ya da `seconds` içinde sesini kısarak duraklatır. Öğesi, geçiş boyunca
    /// son karesi görünsün diye oynatıcıda kalır; oynatıcı yeniden kullanılınca değişir.
    private func retire(_ outgoing: AVPlayer, over seconds: Double) {
        guard seconds > 0, outgoing.timeControlStatus != .paused else {
            outgoing.pause()
            return
        }
        let startVolume = outgoing.volume
        let steps = 12
        fadingPlayer = outgoing
        fadeTask = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                // İptal edildiyse oynatıcı yeniden kullanılıyordur; ona dokunma.
                guard !Task.isCancelled else { return }
                outgoing.volume = startVolume * Float(steps - step) / Float(steps)
            }
            self?.finishFade()
        }
    }

    private func finishFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fadingPlayer?.pause()
        fadingPlayer?.volume = volume
        fadingPlayer = nil
    }

    private func playerTimeChanged(_ seconds: Double, from index: Int) {
        guard index == activeIndex, !isScrubbing, seconds.isFinite else { return }
        currentTime = seconds
    }

    private func syncPlayingState() {
        isPlaying = player.timeControlStatus != .paused
    }

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
