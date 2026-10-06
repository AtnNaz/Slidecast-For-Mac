import AppKit
import Observation

/// Küçük resimler ve sahnede gösterilen tam boy görüntüler için bellek önbelleği.
@Observable
final class ImageStore {
    @ObservationIgnored private let thumbnails = NSCache<NSURL, NSImage>()
    @ObservationIgnored private let stageImages = NSCache<NSURL, NSImage>()
    /// Küçük resimler yeniden üretildiğinde görünümlerin tazelenmesi için artırılır.
    private var thumbnailRevision = 0

    init() {
        thumbnails.countLimit = 500
        stageImages.countLimit = 6
    }

    func thumbnail(for slide: Slide, in package: DeckPackage) -> NSImage? {
        _ = thumbnailRevision
        let url = package.thumbnailURL(for: slide)
        if let cached = thumbnails.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        thumbnails.setObject(image, forKey: url as NSURL)
        return image
    }

    func cachedStageImage(at url: URL) -> NSImage? {
        stageImages.object(forKey: url as NSURL)
    }

    func stageImage(at url: URL) async -> NSImage? {
        if let cached = cachedStageImage(at: url) { return cached }
        guard let decoded = await MediaImporter.decodeImage(at: url) else { return nil }
        let cgImage = decoded.cgImage
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        stageImages.setObject(image, forKey: url as NSURL)
        return image
    }

    /// Komşu slaytların görüntülerini önceden çözer; geçiş anında gecikme olmaz.
    func preload(_ urls: [URL]) {
        for url in urls where cachedStageImage(at: url) == nil {
            Task { _ = await stageImage(at: url) }
        }
    }

    func invalidateThumbnails() {
        thumbnails.removeAllObjects()
        thumbnailRevision += 1
    }

    func removeAll() {
        stageImages.removeAllObjects()
        invalidateThumbnails()
    }
}
