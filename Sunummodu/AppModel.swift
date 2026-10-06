import AppKit
import Observation
import UniformTypeIdentifiers

/// Uygulamanın bütün durumunu bir arada tutar ve dosya işlemlerini (yeni / aç / kaydet / ekle) yürütür.
@Observable
final class AppModel {
    private static let lastDeckKey = "lastDeckPath"

    let store: DeckStore
    let playback: PlaybackController
    let screens: ScreenManager
    let images: ImageStore
    let presentation: PresentationController
    var errorMessage: String?

    @ObservationIgnored private let keyboard = KeyboardHandler()
    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        // Birim testleri uygulamanın içinde çalışır; kullanıcının sunumuna ve klavyesine dokunulmaz.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let draftURL = isRunningTests
            ? FileManager.default.temporaryDirectory.appendingPathComponent("SunummoduTestHost-\(UUID().uuidString).sunum")
            : Self.defaultDraftURL

        store = DeckStore(draftURL: draftURL)
        playback = PlaybackController()
        screens = ScreenManager()
        images = ImageStore()
        presentation = PresentationController(store: store, playback: playback, screens: screens, images: images)

        if !isRunningTests {
            if let path = defaults.string(forKey: Self.lastDeckKey) {
                try? store.open(URL(fileURLWithPath: path))
            }
            keyboard.install(for: presentation)
        }
        deckChanged()
    }

    private static var defaultDraftURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Sunummodu/Taslak.\(DeckPackage.fileExtension)")
    }

    // MARK: Dosya

    func requestNew() {
        guard confirmLeavingDraft() else { return }
        do {
            try store.resetDraft()
        } catch {
            errorMessage = "Yeni sunum oluşturulamadı: \(error.localizedDescription)"
            return
        }
        deckChanged()
    }

    /// `url` nil ise dosya seçici açar.
    func requestOpen(_ url: URL? = nil) {
        guard let url = url ?? chooseDeck() else { return }
        guard DeckPackage(url: url) != store.package else { return }
        guard confirmLeavingDraft() else { return }
        do {
            try store.open(url)
        } catch {
            errorMessage = "“\(url.lastPathComponent)” açılamadı: \(error.localizedDescription)"
            return
        }
        store.removeInactiveDraft()
        deckChanged()
    }

    func save() {
        if store.isDraft {
            saveAs()
        } else {
            store.flush()
        }
    }

    /// Kaydedildiyse true döner.
    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.sunumDeck]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = store.isDraft ? "Sunum" : store.displayName
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try store.saveAs(to: url)
        } catch {
            errorMessage = "Sunum kaydedilemedi: \(error.localizedDescription)"
            return false
        }
        deckChanged()
        return true
    }

    func addMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Sunuma eklenecek resim ve videoları seç"
        panel.prompt = "Ekle"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    func importFiles(_ urls: [URL], at index: Int? = nil) {
        Task {
            await store.importFiles(urls, at: index)
        }
    }

    /// Finder'dan bırakılan dosyaları ekler. `index` nil ise sona ekler.
    func importDropped(_ providers: [NSItemProvider], at index: Int? = nil) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.fileURL() {
                    urls.append(url)
                }
            }
            await store.importFiles(urls, at: index)
        }
    }

    /// Silme geri alınamadığı için önce sorar.
    func requestDelete(_ id: Slide.ID) {
        guard let slide = store.slides.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "“\(slide.title)” slaytı silinsin mi?"
        alert.informativeText = "Bu işlem geri alınamaz. Eklediğin dosyanın aslı etkilenmez."
        alert.addButton(withTitle: "Sil").hasDestructiveAction = true
        alert.addButton(withTitle: "Vazgeç")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        presentation.delete(id)
    }

    func shutdown() {
        presentation.stop()
        store.flush()
    }

    private func deckChanged() {
        if store.isDraft {
            defaults.removeObject(forKey: Self.lastDeckKey)
        } else {
            defaults.set(store.package.url.path, forKey: Self.lastDeckKey)
        }
        presentation.deckDidChange()
        regenerateMissingThumbnails()
    }

    private func chooseDeck() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.sunumDeck]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Kaydedilmemiş taslakta slayt varsa ne yapılacağını sorar. Devam edilebilirse true döner.
    private func confirmLeavingDraft() -> Bool {
        guard store.isDraft, !store.slides.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "“\(store.displayName)” kaydedilsin mi?"
        alert.informativeText = "Kaydetmezsen bu sunumdaki slaytlar silinir. Eklediğin dosyaların asılları etkilenmez."
        alert.addButton(withTitle: "Kaydet…")
        alert.addButton(withTitle: "Vazgeç")
        alert.addButton(withTitle: "Kaydetme").hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveAs()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func regenerateMissingThumbnails() {
        let package = store.package
        let missing = store.slides.filter {
            !FileManager.default.fileExists(atPath: package.thumbnailURL(for: $0).path)
        }
        guard !missing.isEmpty else { return }
        Task {
            for slide in missing {
                try? await MediaImporter.writeThumbnails(for: slide, in: package)
            }
            images.invalidateThumbnails()
        }
    }
}

extension NSItemProvider {
    func fileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
