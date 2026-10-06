import Observation
import SwiftUI

/// Açık sunumun içeriği ve diskteki paketi. Her değişiklik kısa bir gecikmeyle otomatik kaydedilir.
@Observable
final class DeckStore {
    private(set) var deck = Deck()
    private(set) var package: DeckPackage
    private(set) var importTotal = 0
    private(set) var importDone = 0
    /// İçe aktarılamayan dosyaların adları; arayüz uyarı gösterip temizler.
    var skippedFiles: [String] = []
    var lastError: String?

    /// Kaydedilmemiş sunumun tutulduğu paket.
    let draftURL: URL

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isDirty = false

    var slides: [Slide] { deck.slides }
    var isDraft: Bool { package == DeckPackage(url: draftURL) }
    var isImporting: Bool { importDone < importTotal }
    var displayName: String {
        isDraft ? "Adsız Sunum" : package.url.deletingPathExtension().lastPathComponent
    }

    init(draftURL: URL) {
        self.draftURL = draftURL
        package = DeckPackage(url: draftURL)
        do {
            if FileManager.default.fileExists(atPath: package.manifestURL.path) {
                deck = try package.readDeck()
            } else {
                try package.write(deck)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Slaytlar

    func insert(_ slide: Slide, at index: Int? = nil) {
        let position = min(max(index ?? deck.slides.count, 0), deck.slides.count)
        deck.slides.insert(slide, at: position)
        scheduleSave()
    }

    /// Slaytı ve paketteki kopyasını siler; orijinal dosya etkilenmez.
    func remove(_ id: Slide.ID) {
        guard let index = deck.slides.firstIndex(where: { $0.id == id }) else { return }
        let slide = deck.slides.remove(at: index)
        MediaImporter.removeFiles(for: slide, in: package)
        scheduleSave()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        deck.slides.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    func setNotes(_ notes: String, for id: Slide.ID) {
        guard let index = deck.slides.firstIndex(where: { $0.id == id }),
              deck.slides[index].notes != notes
        else { return }
        deck.slides[index].notes = notes
        scheduleSave()
    }

    /// Dosyaları pakete kopyalayıp slayt olarak ekler. `index` nil ise sona ekler.
    func importFiles(_ urls: [URL], at index: Int? = nil) async {
        let files = MediaImporter.expand(urls)
        guard !files.isEmpty else { return }
        let target = package
        var position = index
        importTotal += files.count
        for file in files {
            do {
                let slide = try await MediaImporter.importFile(at: file, into: target)
                if target == package {
                    insert(slide, at: position)
                    position = position.map { $0 + 1 }
                } else {
                    // İçe aktarma sürerken başka bir sunuma geçildi.
                    MediaImporter.removeFiles(for: slide, in: target)
                }
            } catch {
                skippedFiles.append(file.lastPathComponent)
            }
            importDone += 1
        }
        if importDone >= importTotal {
            importDone = 0
            importTotal = 0
        }
    }

    // MARK: Paket

    func open(_ url: URL) throws {
        let target = DeckPackage(url: url)
        let loaded = try target.readDeck()
        flush()
        package = target
        deck = loaded
    }

    /// Paketi yeni konuma kopyalar ve oradan çalışmaya devam eder. Taslak kaydedildiyse taslak silinir.
    func saveAs(to destination: URL) throws {
        flush()
        let target = DeckPackage(url: destination)
        guard target != package else { return }
        let fileManager = FileManager.default
        let source = package.url
        if fileManager.fileExists(atPath: target.url.path) {
            // Kopyalama yarıda kalırsa var olan dosya bozulmasın diye önce geçici konuma kopyalanır.
            let staging = try fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target.url, create: true
            )
            defer { try? fileManager.removeItem(at: staging) }
            let copy = staging.appendingPathComponent(target.url.lastPathComponent)
            try fileManager.copyItem(at: source, to: copy)
            _ = try fileManager.replaceItemAt(target.url, withItemAt: copy)
        } else {
            try fileManager.copyItem(at: source, to: target.url)
        }
        let wasDraft = isDraft
        package = target
        if wasDraft {
            try? fileManager.removeItem(at: source)
        }
    }

    /// Taslağı boşaltıp ona geçer.
    func resetDraft() throws {
        flush()
        let draft = DeckPackage(url: draftURL)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: draft.url.path) {
            try fileManager.removeItem(at: draft.url)
        }
        package = draft
        deck = Deck()
        try package.write(deck)
    }

    /// Başka bir sunum açıkken geride kalan taslağı siler.
    func removeInactiveDraft() {
        guard !isDraft else { return }
        try? FileManager.default.removeItem(at: draftURL)
    }

    /// Bekleyen değişiklikleri hemen diske yazar.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty else { return }
        do {
            try package.write(deck)
            isDirty = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
