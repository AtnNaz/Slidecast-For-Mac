import AppKit
import Observation

/// Hangi slaytın gösterildiğini, sunumun sürüp sürmediğini ve çıkış penceresini yönetir.
@Observable
final class PresentationController {
    let store: DeckStore
    let playback: PlaybackController
    let screens: ScreenManager
    let images: ImageStore

    private(set) var currentID: Slide.ID?
    private(set) var isPresenting = false
    private(set) var startedAt: Date?
    private(set) var isBlackedOut = false
    /// Çıkışın verildiği ekranın adı; pencere modunda nil.
    private(set) var outputScreenName: String?

    @ObservationIgnored private let output = OutputWindowController()
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?

    init(store: DeckStore, playback: PlaybackController, screens: ScreenManager, images: ImageStore) {
        self.store = store
        self.playback = playback
        self.screens = screens
        self.images = images
        output.onUserClose = { [weak self] in self?.stop() }
        screens.onChange = { [weak self] in self?.relocateOutput() }
    }

    var currentIndex: Int? {
        store.slides.firstIndex { $0.id == currentID }
    }

    var currentSlide: Slide? {
        currentIndex.map { store.slides[$0] }
    }

    var nextSlide: Slide? {
        guard let index = currentIndex, index + 1 < store.slides.count else { return nil }
        return store.slides[index + 1]
    }

    var canGoNext: Bool { nextSlide != nil }
    var canGoPrevious: Bool { (currentIndex ?? 0) > 0 }

    // MARK: Gezinme

    func go(to id: Slide.ID?) {
        guard id != currentID else { return }
        currentID = id
        loadCurrent()
    }

    func go(toIndex index: Int) {
        guard store.slides.indices.contains(index) else { return }
        go(to: store.slides[index].id)
    }

    func next() {
        go(toIndex: (currentIndex ?? -1) + 1)
    }

    func previous() {
        guard let index = currentIndex else { return }
        go(toIndex: index - 1)
    }

    func goToFirst() {
        go(toIndex: 0)
    }

    func goToLast() {
        go(toIndex: store.slides.count - 1)
    }

    /// Slaytı siler; gösterilen slayt silinirse komşusuna geçer.
    func delete(_ id: Slide.ID) {
        guard id == currentID, let index = currentIndex else {
            store.remove(id)
            return
        }
        let slides = store.slides
        let neighbor = index + 1 < slides.count ? slides[index + 1].id : (index > 0 ? slides[index - 1].id : nil)
        store.remove(id)
        go(to: neighbor)
    }

    /// Seçili slayt yoksa (ilk içe aktarma gibi) ilk slaytı seçer.
    func ensureSelection() {
        if currentSlide == nil {
            go(to: store.slides.first?.id)
        }
    }

    /// Başka bir sunum açıldığında ya da paketin konumu değiştiğinde çağrılır.
    func deckDidChange() {
        stop()
        images.removeAll()
        // Aynı sunum yeni konuma kaydedildiyse seçili slayt korunur.
        if currentSlide == nil {
            currentID = store.slides.first?.id
        }
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
        // Gösterilen slayt videoysa baştan ve otomatik başlasın.
        loadCurrent()
    }

    func stop() {
        guard isPresenting else { return }
        isPresenting = false
        isBlackedOut = false
        startedAt = nil
        outputScreenName = nil
        playback.pause()
        output.close()
        if let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity)
        }
        sleepActivity = nil
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
    }

    func resetTimer() {
        guard isPresenting else { return }
        startedAt = Date()
    }

    private func loadCurrent() {
        isBlackedOut = false
        guard let slide = currentSlide, let index = currentIndex else {
            playback.load(nil)
            return
        }
        let package = store.package
        switch slide.kind {
        case .image:
            playback.load(nil)
        case .video:
            playback.load(package.mediaURL(for: slide), duration: slide.duration, autoplay: isPresenting)
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
    }

    private func relocateOutput() {
        guard isPresenting else { return }
        showOutput()
    }
}
