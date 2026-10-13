import AppKit
import Observation

/// Hangi slaytın gösterildiğini, sunumun sürüp sürmediğini ve çıkış penceresini yönetir.
@Observable
final class PresentationController {
    let store: DeckStore
    let playback: PlaybackController
    let screens: ScreenManager
    let images: ImageStore

    /// İzleyiciye gösterilen slayt.
    private(set) var currentID: Slide.ID?
    /// Listede vurgulanan slaytlar; silme, çoğaltma gibi düzenleme komutları bunlara uygulanır.
    private(set) var selection: Set<Slide.ID> = []
    private(set) var isPresenting = false
    private(set) var startedAt: Date?
    private(set) var isBlackedOut = false
    /// Çıkışın verildiği ekranın adı; pencere modunda nil.
    private(set) var outputScreenName: String?
    /// Çıkış ekranının en-boy oranı; önizleme izleyicinin gördüğüyle aynı kırpılsın diye.
    private(set) var outputAspect: CGFloat = 16 / 9
    /// Her slayt değişiminde artar; sahne, geçişi bu sayaca göre canlandırır.
    private(set) var transitionGeneration = 0
    /// Slaytlar arası yumuşak geçişin süresi (saniye); 0 ise kesmeyle değişir.
    var transitionDuration: Double {
        didSet { settings.setNumber(transitionDuration, forKey: Self.transitionKey) }
    }

    private static let transitionKey = "transitionDuration"
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let output = OutputWindowController()
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    /// Gösterilen slayt listeden çıkarsa (silme, geri alma) aynı sıradaki slayta geçmek için.
    @ObservationIgnored private var lastIndex = 0
    @ObservationIgnored private var autoAdvanceTask: Task<Void, Never>?
    /// Karartma sırasında biten video için: karartma kalkınca ilerlenir.
    @ObservationIgnored private var advanceWhenUnblanked = false

    init(
        store: DeckStore, playback: PlaybackController, screens: ScreenManager, images: ImageStore,
        settings: SettingsStore = UserDefaults.standard
    ) {
        self.store = store
        self.playback = playback
        self.screens = screens
        self.images = images
        self.settings = settings
        transitionDuration = settings.number(forKey: Self.transitionKey) ?? 0.5
        output.onUserClose = { [weak self] in self?.stop() }
        playback.onMediaEnded = { [weak self] in self?.mediaDidEnd() }
        screens.onChange = { [weak self] in self?.relocateOutput() }
    }

    var currentIndex: Int? {
        store.slides.firstIndex { $0.id == currentID }
    }

    var currentSlide: Slide? {
        currentIndex.map { store.slides[$0] }
    }

    var nextSlide: Slide? {
        guard let index = currentIndex else { return nil }
        if index + 1 < store.slides.count { return store.slides[index + 1] }
        return isLooping ? store.slides.first : nil
    }

    var canGoNext: Bool { nextSlide != nil }
    var canGoPrevious: Bool {
        guard let index = currentIndex else { return false }
        return index > 0 || (isLooping && store.slides.count > 1)
    }

    /// "Sunumu Tekrarla" yalnızca sunum sırasında geçerlidir; düzenlerken liste başa sarmaz.
    private var isLooping: Bool { isPresenting && store.deck.settings.loops }

    /// Yumuşak geçiş yalnızca sunum sırasında uygulanır; düzenlerken slaytlar anında değişir.
    var activeTransitionDuration: Double { isPresenting ? transitionDuration : 0 }

    // MARK: Gezinme ve seçim

    func go(to id: Slide.ID?) {
        guard id != currentID else { return }
        currentID = id
        selection = id.map { [$0] } ?? []
        transitionGeneration += 1
        loadCurrent()
    }

    func go(toIndex index: Int) {
        guard store.slides.indices.contains(index) else { return }
        go(to: store.slides[index].id)
    }

    func next() {
        let index = (currentIndex ?? -1) + 1
        if index >= store.slides.count, isLooping {
            wrap(toIndex: 0)
        } else {
            go(toIndex: index)
        }
    }

    func previous() {
        guard let index = currentIndex else { return }
        if index == 0, isLooping {
            wrap(toIndex: store.slides.count - 1)
        } else {
            go(toIndex: index - 1)
        }
    }

    /// Sunum tekrar ederken öbür uca geçer. Tek slaytlık sunumda aynı slaytı baştan oynatır.
    private func wrap(toIndex index: Int) {
        guard store.slides.indices.contains(index) else { return }
        if store.slides[index].id == currentID {
            transitionGeneration += 1
            loadCurrent()
        } else {
            go(toIndex: index)
        }
    }

    func goToFirst() {
        go(toIndex: 0)
    }

    func goToLast() {
        go(toIndex: store.slides.count - 1)
    }

    /// Listedeki seçimi değiştirir. Tek slayt seçilince o slayta geçilir; çoklu seçim gösterilen slaytı değiştirmez.
    func select(_ ids: Set<Slide.ID>) {
        // Boş alana tıklamak seçimi kaldırmasın; sunum sırasında ekran boş kalırdı.
        guard !ids.isEmpty else { return }
        selection = ids
        if ids.count == 1 {
            go(to: ids.first)
        }
    }

    func delete(_ id: Slide.ID) {
        delete([id])
    }

    /// Slaytları siler; gösterilen slayt da siliniyorsa önce kalan en yakın slayta geçer.
    func delete(_ ids: Set<Slide.ID>) {
        if let currentID, ids.contains(currentID), let index = currentIndex {
            let slides = store.slides
            let neighbor = slides[(index + 1)...].first { !ids.contains($0.id) }
                ?? slides[..<index].last { !ids.contains($0.id) }
            go(to: neighbor?.id)
        }
        store.remove(ids)
        selection = currentID.map { [$0] } ?? []
    }

    /// Slayt listesi değiştiğinde (içe aktarma, silme, geri alma) seçimi ve gösterilen slaytı geçerli tutar.
    func slidesDidChange() {
        let slides = store.slides
        selection.formIntersection(slides.map(\.id))
        if currentSlide == nil {
            let index = min(lastIndex, slides.count - 1)
            go(to: index >= 0 ? slides[index].id : nil)
        } else if selection.isEmpty, let currentID {
            selection = [currentID]
        }
        lastIndex = currentIndex ?? lastIndex
    }

    /// Başka bir sunum açıldığında ya da paketin konumu değiştiğinde çağrılır.
    func deckDidChange() {
        stop()
        images.removeAll()
        // Aynı sunum yeni konuma kaydedildiyse seçili slayt korunur.
        if currentSlide == nil {
            currentID = store.slides.first?.id
        }
        selection = currentID.map { [$0] } ?? []
        loadCurrent()
    }

    // MARK: Sunum

    func start() {
        guard !isPresenting, !store.slides.isEmpty else { return }
        if currentSlide == nil {
            currentID = store.slides.first?.id
        }
        isPresenting = true
        startedAt = Date()
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Sunum yapılıyor"
        )
        showOutput()
        // Gösterilen slayt video ya da sesse baştan ve otomatik başlasın.
        loadCurrent()
    }

    func stop() {
        guard isPresenting else { return }
        isPresenting = false
        isBlackedOut = false
        startedAt = nil
        outputScreenName = nil
        outputAspect = 16 / 9
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
        playback.stopAll()
        output.close()
        if let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity)
        }
        sleepActivity = nil
    }

    /// Gösterilen slaytın arka plan müziği değiştiğinde (atama, kaldırma, geri alma) çalanı ona uydurur.
    func backgroundAudioDidChange() {
        guard let slide = currentSlide, !slide.isPlayable else { return }
        playback.setMusic(store.package.backgroundAudioURL(for: slide), autoplay: isPresenting)
    }

    func togglePresenting() {
        if isPresenting {
            stop()
        } else {
            start()
        }
    }

    func toggleBlackout() {
        guard isPresenting else { return }
        isBlackedOut.toggle()
        // Ekran karartılmışken otomatik ilerleme bekler.
        if isBlackedOut {
            autoAdvanceTask?.cancel()
            autoAdvanceTask = nil
        } else if advanceWhenUnblanked {
            autoAdvance()
        } else {
            scheduleAutoAdvance()
        }
    }

    /// Tekrar ya da otomatik ilerleme ayarı değiştiğinde çağrılır.
    func showSettingsDidChange() {
        scheduleAutoAdvance()
    }

    // MARK: Otomatik ilerleme

    /// Resim slaytı için geri sayımı başlatır. Video ve ses slaytları bitince `mediaDidEnd` ile ilerler.
    private func scheduleAutoAdvance() {
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
        let seconds = store.deck.settings.autoAdvanceSeconds
        guard isPresenting, !isBlackedOut, seconds > 0, let slide = currentSlide, !slide.isPlayable else { return }
        autoAdvanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.autoAdvance()
        }
    }

    private func mediaDidEnd() {
        guard isPresenting, store.deck.settings.autoAdvanceSeconds > 0 else { return }
        if isBlackedOut {
            advanceWhenUnblanked = true
        } else {
            autoAdvance()
        }
    }

    /// Sonraki slayta geçer; sona gelindiyse ve sunum tekrar etmiyorsa son slaytta kalır.
    private func autoAdvance() {
        advanceWhenUnblanked = false
        guard isPresenting, store.deck.settings.autoAdvanceSeconds > 0, canGoNext else { return }
        next()
    }

    func resetTimer() {
        guard isPresenting else { return }
        startedAt = Date()
    }

    private func loadCurrent() {
        isBlackedOut = false
        advanceWhenUnblanked = false
        defer { scheduleAutoAdvance() }
        guard let slide = currentSlide, let index = currentIndex else {
            playback.load(nil)
            return
        }
        lastIndex = index
        let package = store.package
        if slide.isPlayable {
            playback.load(
                package.mediaURL(for: slide), duration: slide.duration, autoplay: isPresenting,
                fadeOut: activeTransitionDuration
            )
        } else {
            playback.load(
                nil, music: package.backgroundAudioURL(for: slide), autoplay: isPresenting,
                fadeOut: activeTransitionDuration
            )
        }
        let slides = store.slides
        let neighbors = [index + 1, index - 1]
            .filter(slides.indices.contains)
            .map { package.stageImageURL(for: slides[$0]) }
        images.preload(neighbors)
    }

    private func showOutput() {
        let presenterScreen = NSApp.mainWindow?.screen ?? NSScreen.main
        let screen = screens.resolveOutputScreen(avoiding: presenterScreen)
        output.show(on: screen, rootView: OutputView(presentation: self))
        outputScreenName = screen?.localizedName
        if let size = screen?.frame.size, size.height > 0 {
            outputAspect = size.width / size.height
        } else {
            outputAspect = 16 / 9
        }
    }

    private func relocateOutput() {
        guard isPresenting else { return }
        showOutput()
    }
}
