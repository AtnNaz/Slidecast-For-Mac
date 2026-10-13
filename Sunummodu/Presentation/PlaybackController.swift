import AVFoundation
import Observation

/// Video ve ses oynatımını yönetir. Çıkış penceresi ve sunucu önizlemesi aynı oynatıcıyı gösterir.
///
/// Slayt medyası için iki oynatıcı sırayla kullanılır: slayt değişince yeni slayt öbür oynatıcıya yüklenir,
/// eskisi kendi oynatıcısında kalır. Böylece yumuşak geçiş sürerken giden videonun görüntüsü kaybolmaz.
///
/// Resim slaytlarının arka plan müziği ayrı bir oynatıcıda çalar ve aynı müziği paylaşan slaytlar arasında
/// kesilmeden sürer. Müzikli bir resim gösterilirken başlat / durdur ve ilerleme çubuğu müziği yönetir.
@Observable
final class PlaybackController {
    static let volumeStep: Float = 0.1
    private static let volumeKey = "volume"

    @ObservationIgnored private let players = [AVPlayer(), AVPlayer()]
    private var activeIndex = 0
    /// Gösterilen slaytın (video ya da ses) oynatıcısı.
    var player: AVPlayer { players[activeIndex] }

    /// Gösterilen slayt arka plan müziği kullanıyor; oynatma kontrolleri müziği yönetir.
    private(set) var isMusicActive = false
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var volume: Float
    private(set) var isMuted = false
    private var slideHasMedia = false
    private var slideDuration: Double = 0
    private var musicDuration: Double = 0

    /// Oynatılabilecek bir şey var mı: slaytın kendi medyası ya da arka plan müziği.
    var hasMedia: Bool { isMusicActive || slideHasMedia }
    var duration: Double { isMusicActive ? musicDuration : slideDuration }

    /// Slaytın kendi medyası (video ya da ses) sonuna kadar oynadığında çağrılır.
    @ObservationIgnored var onMediaEnded: (() -> Void)?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var slideEndObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var timeObservers: [Any] = []
    @ObservationIgnored private var statusObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false
    /// Sesi kısılarak kapanmakta olan (giden) oynatıcı.
    @ObservationIgnored private var fadingPlayer: AVPlayer?
    @ObservationIgnored private var fadeTask: Task<Void, Never>?

    @ObservationIgnored private let musicPlayer = AVPlayer()
    @ObservationIgnored private var musicURL: URL?
    @ObservationIgnored private var musicFadeTask: Task<Void, Never>?
    @ObservationIgnored private var musicEndObserver: NSObjectProtocol?
    /// Kullanıcı müziği elle durdurduysa aynı müzikli sonraki slayta geçince kendiliğinden başlamaz.
    @ObservationIgnored private var musicPausedByUser = false

    init(settings: SettingsStore = UserDefaults.standard) {
        self.settings = settings
        volume = Float(settings.number(forKey: Self.volumeKey) ?? 1)

        for (index, player) in players.enumerated() {
            player.volume = volume
            // Video bitince son karede kalır.
            player.actionAtItemEnd = .pause
            player.allowsExternalPlayback = false
            observe(player) { [weak self] seconds in
                guard let self, index == self.activeIndex, !self.isMusicActive else { return }
                self.playerTimeChanged(seconds)
            }
        }

        musicPlayer.volume = volume
        // Müzik bitince başa sarılır (bkz. `loadMusic`); oynatıcı kendiliğinden durmasın.
        musicPlayer.actionAtItemEnd = .none
        musicPlayer.allowsExternalPlayback = false
        observe(musicPlayer) { [weak self] seconds in
            guard let self, self.isMusicActive else { return }
            self.playerTimeChanged(seconds)
        }
    }

    /// Yeni slaytı yükler. `url` slaytın kendi medyasıdır (video ya da ses); nil ise resim slaytıdır ve
    /// varsa `music` arka planda çalar. `fadeOut` sıfırdan büyükse giden slaytın medyası (ve artık
    /// kullanılmayan müzik) bu süre boyunca sesi kısılarak kapanır.
    func load(
        _ url: URL?, duration knownDuration: Double? = nil, music: URL? = nil,
        autoplay: Bool = false, fadeOut: Double = 0
    ) {
        finishFade()
        retire(player, over: fadeOut)
        activeIndex = 1 - activeIndex

        let incoming = player
        incoming.pause()
        incoming.volume = volume
        incoming.isMuted = isMuted
        isScrubbing = false
        if let url {
            let item = AVPlayerItem(url: url)
            incoming.replaceCurrentItem(with: item)
            observeEnd(of: item)
            slideHasMedia = true
            slideDuration = knownDuration ?? 0
            Task { [weak self] in
                guard let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite else { return }
                guard let self, self.player.currentItem === item else { return }
                self.slideDuration = seconds
            }
            if autoplay {
                incoming.play()
            }
        } else {
            incoming.replaceCurrentItem(with: nil)
            observeEnd(of: nil)
            slideHasMedia = false
            slideDuration = 0
        }
        // Kendi sesi olan slaytta arka plan müziği çalmaz.
        setMusic(url == nil ? music : nil, autoplay: autoplay, fadeOut: fadeOut)
    }

    /// Gösterilen slaytın arka plan müziğini değiştirir. Aynı müzikse çalmayı kesmeden sürdürür; nil ise
    /// müziği (`fadeOut` süresince kısarak) duraklatır, aynı müziğe dönülürse kaldığı yerden devam eder.
    func setMusic(_ url: URL?, autoplay: Bool, fadeOut: Double = 0) {
        if let url {
            cancelMusicFade()
            if url != musicURL {
                loadMusic(url)
            }
            isMusicActive = true
            musicPlayer.volume = volume
            musicPlayer.isMuted = isMuted
            if autoplay, !musicPausedByUser {
                musicPlayer.play()
            }
        } else {
            fadeOutMusic(over: fadeOut)
            isMusicActive = false
            musicPausedByUser = false
        }
        isScrubbing = false
        let seconds = isMusicActive ? musicPlayer.currentTime().seconds : 0
        currentTime = seconds.isFinite ? seconds : 0
        syncPlayingState()
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
        if isMusicActive {
            musicPausedByUser = false
            cancelMusicFade()
            musicPlayer.play()
            return
        }
        if slideDuration > 0, currentTime >= slideDuration - 0.05 {
            // Sondayken Başlat'a basılırsa baştan oynatılır.
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
        }
        player.play()
    }

    /// Gösterileni (slayt medyası ya da arka plan müziği) duraklatır; kapanmakta olan önceki slayt varsa
    /// onu da hemen susturur.
    func pause() {
        finishFade()
        if isMusicActive {
            musicPausedByUser = true
        }
        controlled.pause()
    }

    /// Sunum bitince: çalan her şeyi durdurur.
    func stopAll() {
        finishFade()
        cancelMusicFade()
        player.pause()
        musicPlayer.pause()
        musicPausedByUser = false
    }

    // MARK: İlerleme çubuğu

    func beginScrubbing() {
        guard hasMedia, !isScrubbing else { return }
        isScrubbing = true
        resumeAfterScrub = isPlaying
        controlled.pause()
    }

    func scrub(to seconds: Double) {
        guard hasMedia else { return }
        currentTime = min(max(seconds, 0), duration)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        controlled.seek(to: cmTime(currentTime), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        controlled.seek(to: cmTime(currentTime), toleranceBefore: .zero, toleranceAfter: .zero)
        if resumeAfterScrub {
            controlled.play()
        }
    }

    // MARK: Ses

    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        player.volume = volume
        if musicFadeTask == nil {
            musicPlayer.volume = volume
        }
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
        musicPlayer.isMuted = isMuted
    }

    // MARK: Giden slayt

    /// Giden oynatıcıyı hemen ya da `seconds` içinde sesini kısarak duraklatır. Öğesi, geçiş boyunca
    /// son karesi görünsün diye oynatıcıda kalır; oynatıcı yeniden kullanılınca değişir.
    private func retire(_ outgoing: AVPlayer, over seconds: Double) {
        guard seconds > 0, outgoing.timeControlStatus != .paused else {
            outgoing.pause()
            return
        }
        fadingPlayer = outgoing
        fadeTask = Task { [weak self] in
            guard await Self.rampDown(outgoing, over: seconds) else { return }
            self?.finishFade()
        }
    }

    private func observeEnd(of item: AVPlayerItem?) {
        slideEndObservers.forEach(NotificationCenter.default.removeObserver)
        slideEndObservers = []
        guard let item else { return }
        // Oynatılamayan dosya da "bitti" sayılır; otomatik ilerleyen sunum orada takılmasın.
        let names = [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification]
        slideEndObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.player.currentItem === item else { return }
                    self.onMediaEnded?()
                }
            }
        }
    }

    private func finishFade() {
        fadeTask?.cancel()
        fadeTask = nil
        fadingPlayer?.pause()
        fadingPlayer?.volume = volume
        fadingPlayer = nil
    }

    // MARK: Arka plan müziği

    private func loadMusic(_ url: URL) {
        if let musicEndObserver {
            NotificationCenter.default.removeObserver(musicEndObserver)
        }
        let item = AVPlayerItem(url: url)
        musicPlayer.replaceCurrentItem(with: item)
        musicURL = url
        musicDuration = 0
        musicPausedByUser = false
        // Müzik slaytlardan kısa kalırsa baştan çalmayı sürdürür.
        musicEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.musicPlayer.seek(to: .zero) }
        }
        Task { [weak self] in
            guard let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite else { return }
            guard let self, self.musicPlayer.currentItem === item else { return }
            self.musicDuration = seconds
        }
    }

    /// Müziği duraklatır ama yerinde bırakır; aynı müziğe dönülürse kaldığı yerden sürer.
    private func fadeOutMusic(over seconds: Double) {
        cancelMusicFade()
        guard seconds > 0, musicPlayer.timeControlStatus != .paused else {
            musicPlayer.pause()
            return
        }
        let music = musicPlayer
        musicFadeTask = Task { [weak self] in
            guard await Self.rampDown(music, over: seconds) else { return }
            music.pause()
            self?.cancelMusicFade()
        }
    }

    private func cancelMusicFade() {
        musicFadeTask?.cancel()
        musicFadeTask = nil
        musicPlayer.volume = volume
    }

    /// Sesi adım adım sıfıra indirir. İptal edilirse false döner ve oynatıcıya dokunmayı bırakır
    /// (oynatıcı o sırada yeniden kullanılıyordur).
    private static func rampDown(_ player: AVPlayer, over seconds: Double) async -> Bool {
        let startVolume = player.volume
        let steps = 12
        for step in 1...steps {
            try? await Task.sleep(for: .seconds(seconds / Double(steps)))
            guard !Task.isCancelled else { return false }
            player.volume = startVolume * Float(steps - step) / Float(steps)
        }
        return true
    }

    // MARK: Durum

    /// Oynatma kontrollerinin yönettiği oynatıcı.
    private var controlled: AVPlayer { isMusicActive ? musicPlayer : player }

    private func observe(_ player: AVPlayer, time: @escaping @MainActor (Double) -> Void) {
        timeObservers.append(player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { seconds in
            MainActor.assumeIsolated { time(seconds.seconds) }
        })
        statusObservations.append(player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.syncPlayingState() }
        })
    }

    private func playerTimeChanged(_ seconds: Double) {
        guard !isScrubbing, seconds.isFinite else { return }
        currentTime = seconds
    }

    private func syncPlayingState() {
        isPlaying = controlled.timeControlStatus != .paused
    }

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
