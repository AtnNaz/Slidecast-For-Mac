import Foundation
import UniformTypeIdentifiers

/// Diskteki `.sunum` paketinin klasör düzeni:
/// `deck.json`, `Media/` (kopyalanan resim ve videolar), `Thumbs/` (küçük resimler ve video poster kareleri).
nonisolated struct DeckPackage: Equatable, Sendable {
    static let fileExtension = "sunum"

    let url: URL

    init(url: URL) {
        // Klasör henüz yokken de varken de aynı URL çıksın; yoksa aynı paket kendisine eşit olmaz.
        self.url = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    var manifestURL: URL { url.appendingPathComponent("deck.json") }
    var mediaDirectory: URL { url.appendingPathComponent("Media", isDirectory: true) }
    var thumbsDirectory: URL { url.appendingPathComponent("Thumbs", isDirectory: true) }

    func mediaURL(for slide: Slide) -> URL {
        mediaDirectory.appendingPathComponent(slide.fileName)
    }

    func thumbnailURL(for slide: Slide) -> URL {
        thumbsDirectory.appendingPathComponent("\(slide.id.uuidString).jpg")
    }

    /// Videonun ilk karesi (oynatıcı hazır olana kadar sahnede bu gösterilir) ya da ses slaytının görseli.
    func posterURL(for slide: Slide) -> URL {
        thumbsDirectory.appendingPathComponent("\(slide.id.uuidString)-poster.jpg")
    }

    /// Sahnede gösterilecek durağan görüntü: resmin kendisi ya da video / sesin poster görseli.
    func stageImageURL(for slide: Slide) -> URL {
        switch slide.kind {
        case .image: mediaURL(for: slide)
        case .video, .audio: posterURL(for: slide)
        }
    }

    /// Slayta ait olabilecek bütün dosyalar.
    func fileURLs(for slide: Slide) -> [URL] {
        [mediaURL(for: slide), thumbnailURL(for: slide), posterURL(for: slide)]
    }

    func createDirectories() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbsDirectory, withIntermediateDirectories: true)
    }

    func readDeck() throws -> Deck {
        try JSONDecoder().decode(Deck.self, from: Data(contentsOf: manifestURL))
    }

    func write(_ deck: Deck) throws {
        try createDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(deck).write(to: manifestURL, options: .atomic)
    }
}

extension UTType {
    nonisolated static let sunumDeck = UTType(exportedAs: "com.sunummodu.deck")
}
