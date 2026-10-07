import Observation
import SwiftUI

/// Açık sunumun içeriği ve diskteki paketi. Her değişiklik kısa bir gecikmeyle otomatik kaydedilir;
/// slayt ekleme, silme, sıralama ve düzenlemeler geri alınabilir.
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
    /// Kaydedilmemiş sunumun pencere başlığında görünen adı.
    let draftName: String
    /// Pencerenin geri alma yöneticisi; arayüz bağlar. nil iken değişiklikler geri alınamaz.
    @ObservationIgnored var undoManager: UndoManager?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isDirty = false
    /// Sunumdan çıkarılan slaytların dosyaları, geri alınabilsin diye paketin dışında burada bekler.
    @ObservationIgnored private var trash: DeckPackage?

    var slides: [Slide] { deck.slides }
    var isDraft: Bool { package == DeckPackage(url: draftURL) }
    var isImporting: Bool { importDone < importTotal }
    var displayName: String {
        isDraft ? draftName : package.url.deletingPathExtension().lastPathComponent
    }

    init(draftURL: URL, draftName: String = "Adsız Sunum") {
        self.draftURL = draftURL
        self.draftName = draftName
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
        var order = deck.slides.map(\.id)
        order.insert(slide.id, at: min(max(index ?? order.count, 0), order.count))
        arrange(order, pool: [slide], actionName: "Slayt Ekle")
    }

    func remove(_ id: Slide.ID) {
        remove([id])
    }

    /// Slaytları sunumdan çıkarır. Orijinal dosyalar etkilenmez; pakete kopyalananlar geri alınabilsin diye saklanır.
    func remove(_ ids: Set<Slide.ID>) {
        let remaining = deck.slides.map(\.id).filter { !ids.contains($0) }
        let removedCount = deck.slides.count - remaining.count
        arrange(remaining, actionName: removedCount > 1 ? "Slaytları Sil" : "Slaytı Sil")
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var order = deck.slides.map(\.id)
        order.move(fromOffsets: source, toOffset: destination)
        arrange(order, actionName: "Sırayı Değiştir")
    }

    func setTitle(_ title: String, for id: Slide.ID) {
        guard let index = deck.slides.firstIndex(where: { $0.id == id }),
              deck.slides[index].title != title
        else { return }
        let previous = deck.slides[index].title
        deck.slides[index].title = title
        registerUndo("Yeniden Adlandır") { $0.setTitle(previous, for: id) }
        scheduleSave()
    }

    func setScaling(_ scaling: SlideScaling, for ids: Set<Slide.ID>) {
        applyScaling(Dictionary(uniqueKeysWithValues: ids.map { ($0, scaling) }))
    }

    /// Notlar slayt düzeyinde geri alma adımı oluşturmaz; not alanı kendi geri almasını yapar.
    func setNotes(_ notes: String, for id: Slide.ID) {
        guard let index = deck.slides.firstIndex(where: { $0.id == id }),
              deck.slides[index].notes != notes
        else { return }
        deck.slides[index].notes = notes
        scheduleSave()
    }

    /// Slaytların kopyalarını asıllarının hemen arkasına ekler ve kopyaların kimliklerini döndürür.
    @discardableResult
    func duplicate(_ ids: Set<Slide.ID>) async -> [Slide.ID] {
        let target = package
        var copies: [Slide.ID: Slide] = [:]
        for slide in deck.slides where ids.contains(slide.id) {
            var copy = slide
            copy.id = UUID()
            copy.fileName = MediaImporter.mediaFileName(
                id: copy.id, extension: URL(fileURLWithPath: slide.fileName).pathExtension
            )
            copy.title = "\(slide.title) kopya"
            do {
                try await MediaImporter.copyFiles(of: slide, to: copy, in: target)
                copies[slide.id] = copy
            } catch {
                MediaImporter.removeFiles(for: copy, in: target)
            }
        }
        guard target == package, !copies.isEmpty else {
            copies.values.forEach { MediaImporter.removeFiles(for: $0, in: target) }
            return []
        }
        let order = deck.slides.flatMap { slide in [slide.id] + (copies[slide.id].map { [$0.id] } ?? []) }
        arrange(order, pool: Array(copies.values), actionName: copies.count > 1 ? "Slaytları Çoğalt" : "Slaytı Çoğalt")
        return order.filter { id in copies.values.contains { $0.id == id } }
    }

    /// Dosyaları pakete kopyalayıp slayt olarak ekler (PDF'lerin her sayfası ayrı slayt). `index` nil ise sona ekler.
    /// Bütün içe aktarma tek bir geri alma adımıdır.
    func importFiles(_ urls: [URL], at index: Int? = nil) async {
        let sources = MediaImporter.sources(for: urls)
        guard !sources.isEmpty else { return }
        let target = package
        var position = index
        var imported: Set<Slide.ID> = []
        importTotal += sources.count
        for source in sources {
            do {
                let slide = try await MediaImporter.importSource(source, into: target)
                if target == package {
                    let slot = min(max(position ?? deck.slides.count, 0), deck.slides.count)
                    deck.slides.insert(slide, at: slot)
                    scheduleSave()
                    imported.insert(slide.id)
                    position = position.map { $0 + 1 }
                } else {
                    // İçe aktarma sürerken başka bir sunuma geçildi.
                    MediaImporter.removeFiles(for: slide, in: target)
                }
            } catch {
                if !skippedFiles.contains(source.fileName) {
                    skippedFiles.append(source.fileName)
                }
            }
            importDone += 1
        }
        if importDone >= importTotal {
            importDone = 0
            importTotal = 0
        }
        guard target == package, !imported.isEmpty else { return }
        registerUndo("Slayt Ekle") { store in
            store.arrange(store.deck.slides.map(\.id).filter { !imported.contains($0) }, actionName: "Slayt Ekle")
        }
    }

    // MARK: Paket

    func open(_ url: URL) throws {
        let target = DeckPackage(url: url)
        let loaded = try target.readDeck()
        flush()
        discardUndoHistory()
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
        discardUndoHistory()
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

    /// Uygulama kapanırken: son değişiklikleri yazar, silinmiş slaytların sakladığı dosyaları bırakır.
    func close() {
        flush()
        discardUndoHistory()
    }

    // MARK: Geri alma

    /// Slayt listesini verilen kimlik sırasına getirir; tek bir geri alma adımıdır. Listede olmayan kimlikler
    /// `pool`dan alınır (yeni eklenen ya da geri gelen slaytlar), sıradan çıkanların dosyaları saklanır.
    /// Kalan slaytların o anki içeriği (not, ad) korunur.
    private func arrange(_ ids: [Slide.ID], pool: [Slide] = [], actionName: String) {
        let current = Dictionary(uniqueKeysWithValues: deck.slides.map { ($0.id, $0) })
        let incoming = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let arranged = ids.compactMap { current[$0] ?? incoming[$0] }
        let previousOrder = deck.slides.map(\.id)
        guard arranged.map(\.id) != previousOrder else { return }

        let remainingIDs = Set(arranged.map(\.id))
        let leaving = deck.slides.filter { !remainingIDs.contains($0.id) }
        let entering = arranged.filter { current[$0.id] == nil }
        leaving.forEach(moveToTrash)
        entering.forEach(restoreFromTrash)
        deck.slides = arranged
        registerUndo(actionName) { $0.arrange(previousOrder, pool: leaving, actionName: actionName) }
        scheduleSave()
    }

    private func applyScaling(_ values: [Slide.ID: SlideScaling]) {
        var previous: [Slide.ID: SlideScaling] = [:]
        for index in deck.slides.indices {
            guard let scaling = values[deck.slides[index].id], deck.slides[index].scaling != scaling else { continue }
            previous[deck.slides[index].id] = deck.slides[index].scaling
            deck.slides[index].scaling = scaling
        }
        guard !previous.isEmpty else { return }
        registerUndo("Sığdır / Doldur") { $0.applyScaling(previous) }
        scheduleSave()
    }

    private func registerUndo(_ actionName: String, _ handler: @escaping @MainActor (DeckStore) -> Void) {
        guard let undoManager else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self, handler: handler)
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    private func discardUndoHistory() {
        undoManager?.removeAllActions(withTarget: self)
        if let trash {
            try? FileManager.default.removeItem(at: trash.url)
        }
        trash = nil
    }

    private func moveToTrash(_ slide: Slide) {
        guard let trash = trashPackage() else { return }
        moveFiles(of: slide, from: package, to: trash)
    }

    private func restoreFromTrash(_ slide: Slide) {
        guard let trash else { return }
        moveFiles(of: slide, from: trash, to: package)
    }

    private func moveFiles(of slide: Slide, from source: DeckPackage, to destination: DeckPackage) {
        let fileManager = FileManager.default
        for (from, to) in zip(source.fileURLs(for: slide), destination.fileURLs(for: slide))
        where fileManager.fileExists(atPath: from.path) {
            try? fileManager.moveItem(at: from, to: to)
        }
    }

    /// Paketle aynı diskte geçici bir klasör; taşımalar anlık olur.
    private func trashPackage() -> DeckPackage? {
        if let trash { return trash }
        guard let directory = try? FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: package.url, create: true
        ) else { return nil }
        let created = DeckPackage(url: directory)
        try? created.createDirectories()
        trash = created
        return created
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
