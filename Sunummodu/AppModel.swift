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
    /// Yeniden adlandırma penceresi açık olan slayt.
    var renamingID: Slide.ID?

    @ObservationIgnored private let keyboard = KeyboardHandler()
    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        // Birim testleri uygulamanın içinde çalışır; kullanıcının sunumuna ve klavyesine dokunulmaz.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let draftURL = isRunningTests
            ? FileManager.default.temporaryDirectory.appendingPathComponent("SunummoduTestHost-\(UUID().uuidString).sunum")
            : Self.defaultDraftURL

        // Testler kullanıcının ses ve geçiş ayarlarını okumasın, değiştirmesin.
        let settings: SettingsStore = isRunningTests ? InMemorySettings() : UserDefaults.standard

        store = DeckStore(draftURL: draftURL)
        playback = PlaybackController(settings: settings)
        screens = ScreenManager()
        images = ImageStore()
        presentation = PresentationController(
            store: store, playback: playback, screens: screens, images: images, settings: settings
        )

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
        panel.allowedContentTypes = [.image, .movie, .audio, .pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Sunuma eklenecek resim, video, ses ya da PDF dosyalarını seç"
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

    // MARK: Seçili slaytlar

    func deleteSelection() {
        presentation.delete(presentation.selection)
    }

    func duplicateSelection() {
        let ids = presentation.selection
        Task {
            let copies = await store.duplicate(ids)
            if !copies.isEmpty {
                presentation.select(Set(copies))
            }
        }
    }

    /// Seçili slaytların hepsi ekranı dolduruyorsa sığdırmaya, değilse doldurmaya çevirir.
    func toggleFillForSelection() {
        setFill(!isFilled(presentation.selection), for: presentation.selection)
    }

    func isFilled(_ ids: Set<Slide.ID>) -> Bool {
        let slides = store.slides.filter { ids.contains($0.id) }
        return !slides.isEmpty && slides.allSatisfy { $0.scaling == .fill }
    }

    func setFill(_ fill: Bool, for ids: Set<Slide.ID>) {
        store.setScaling(fill ? .fill : .fit, for: ids)
    }

    func beginRenamingSelection() {
        guard presentation.selection.count == 1 else { return }
        renamingID = presentation.selection.first
    }

    /// Ses slaytında sahnede gösterilecek görseli seçtirir.
    func chooseArtwork(for id: Slide.ID) {
        guard let slide = store.slides.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "“\(slide.title)” çalarken ekranda gösterilecek görseli seç"
        panel.prompt = "Seç"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let package = store.package
        Task {
            do {
                try await MediaImporter.setArtwork(from: url, for: slide, in: package)
            } catch {
                errorMessage = "“\(url.lastPathComponent)” görsel olarak kullanılamadı."
            }
            images.removeAll()
        }
    }

    func removeArtwork(for id: Slide.ID) {
        guard let slide = store.slides.first(where: { $0.id == id }) else { return }
        MediaImporter.removeArtwork(for: slide, in: store.package)
        images.removeAll()
    }

    func shutdown() {
        presentation.stop()
        store.close()
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
