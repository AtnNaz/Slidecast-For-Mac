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
        lastIndex = index
        let package = store.package
        if slide.isPlayable {
            playback.load(
                package.mediaURL(for: slide), duration: slide.duration, autoplay: isPresenting,
                fadeOut: activeTransitionDuration
            )
        } else {
            playback.load(nil, fadeOut: activeTransitionDuration)
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
