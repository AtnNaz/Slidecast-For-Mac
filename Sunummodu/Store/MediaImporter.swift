import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Arka planda çözülen görüntüyü ana aktöre taşımak için.
nonisolated struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Açık bir PDF belgesi; her sayfası bir resim slaytına çevrilir.
nonisolated final class PDFSource: @unchecked Sendable {
    let url: URL
    let document: CGPDFDocument

    /// Açılamayan, parolalı ya da boş belgelerde nil döner.
    init?(url: URL) {
        guard let document = CGPDFDocument(url as CFURL), document.isUnlocked, document.numberOfPages > 0 else {
            return nil
        }
        self.url = url
        self.document = document
    }
}

/// İçe aktarılacak tek bir slaytın kaynağı.
nonisolated enum ImportSource: Sendable {
    case file(URL)
    case pdfPage(PDFSource, number: Int)

    var fileName: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .pdfPage(let pdf, _): pdf.url.lastPathComponent
        }
    }
}

/// Dosyaları pakete kopyalar ve küçük resimlerini üretir. Ağır işler ana aktörün dışında çalışır.
nonisolated enum MediaImporter {
    enum ImportError: Error {
        case unsupported
    }

    static let thumbnailPixelSize = 480
    static let posterPixelSize = 2560
    static let stagePixelSize = 3840
    /// PDF sayfalarının uzun kenarı; metin net kalsın diye kayıpsız PNG yazılır.
    static let pdfPixelSize = 2880

    static func kind(of url: URL) -> MediaKind? {
        guard let type = contentType(of: url) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    static func isPDF(_ url: URL) -> Bool {
        contentType(of: url)?.conforms(to: .pdf) ?? false
    }

    /// Bırakılan dosya ve klasörleri tek tek slayt kaynaklarına açar: klasörler içlerindeki desteklenen
    /// dosyalara (ada göre sıralı), PDF'ler sayfalarına. Tanınmayan dosyalar olduğu gibi kalır ve içe
    /// aktarılırken reddedilir.
    static func sources(for urls: [URL]) -> [ImportSource] {
        expand(urls).flatMap { url -> [ImportSource] in
            guard isPDF(url), let pdf = PDFSource(url: url) else { return [.file(url)] }
            return (1...pdf.document.numberOfPages).map { .pdfPage(pdf, number: $0) }
        }
    }

    @concurrent
    static func importSource(_ source: ImportSource, into package: DeckPackage) async throws -> Slide {
        switch source {
        case .file(let url):
            try await importFile(at: url, into: package)
        case .pdfPage(let pdf, let number):
            try await importPDFPage(number, of: pdf, into: package)
        }
    }

    /// Dosyayı pakete kopyalar (orijinale dokunmaz) ve ona karşılık gelen slaytı döndürür.
    @concurrent
    static func importFile(at source: URL, into package: DeckPackage) async throws -> Slide {
        guard let kind = kind(of: source) else { throw ImportError.unsupported }

        var duration: Double?
        switch kind {
        case .image:
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  CGImageSourceGetCount(imageSource) > 0
            else { throw ImportError.unsupported }
        case .video, .audio:
            let asset = AVURLAsset(url: source)
            guard try await asset.load(.isPlayable) else { throw ImportError.unsupported }
            let seconds = try await asset.load(.duration).seconds
            duration = seconds.isFinite ? seconds : nil
        }

        let id = UUID()
        let slide = Slide(
            id: id,
            kind: kind,
            fileName: mediaFileName(id: id, extension: source.pathExtension),
            title: source.deletingPathExtension().lastPathComponent,
            duration: duration
        )

        try package.createDirectories()
        try FileManager.default.copyItem(at: source, to: package.mediaURL(for: slide))
        // Küçük resim üretilemese de slayt kullanılabilir; liste yer tutucu gösterir.
        try? await writeThumbnails(for: slide, in: package)
        return slide
    }

    @concurrent
    static func writeThumbnails(for slide: Slide, in package: DeckPackage) async throws {
        try package.createDirectories()
        let mediaURL = package.mediaURL(for: slide)
        switch slide.kind {
        case .image:
            guard let thumbnail = downsample(mediaURL, maxPixel: thumbnailPixelSize) else {
                throw ImportError.unsupported
            }
            try writeJPEG(thumbnail, to: package.thumbnailURL(for: slide))
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: posterPixelSize, height: posterPixelSize)
            try writePoster(try await generator.image(at: .zero).image, for: slide, in: package)
        case .audio:
            // Dosyaya gömülü kapak görseli varsa onu kullan.
            let metadata = try await AVURLAsset(url: mediaURL).load(.commonMetadata)
            let artwork = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
            guard let data = try await artwork.first?.load(.dataValue),
                  let image = downsample(data, maxPixel: posterPixelSize)
            else { throw ImportError.unsupported }
            try writePoster(image, for: slide, in: package)
        }
    }

    /// Ses slaytında sahnede gösterilecek görseli değiştirir.
    @concurrent
    static func setArtwork(from imageURL: URL, for slide: Slide, in package: DeckPackage) async throws {
        guard let image = downsample(imageURL, maxPixel: posterPixelSize) else { throw ImportError.unsupported }
        try package.createDirectories()
        try writePoster(image, for: slide, in: package)
    }

    static func removeArtwork(for slide: Slide, in package: DeckPackage) {
        for url in [package.posterURL(for: slide), package.thumbnailURL(for: slide)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// `slide`ın dosyalarını `copy` adına çoğaltır (APFS'te yer kaplamayan klon).
    @concurrent
    static func copyFiles(of slide: Slide, to copy: Slide, in package: DeckPackage) async throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: package.mediaURL(for: slide), to: package.mediaURL(for: copy))
        let optional = [
            (package.thumbnailURL(for: slide), package.thumbnailURL(for: copy)),
            (package.posterURL(for: slide), package.posterURL(for: copy)),
        ]
        for (source, destination) in optional where fileManager.fileExists(atPath: source.path) {
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    static func removeFiles(for slide: Slide, in package: DeckPackage) {
        for url in package.fileURLs(for: slide) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func mediaFileName(id: UUID, extension pathExtension: String) -> String {
        let pathExtension = pathExtension.lowercased()
        return pathExtension.isEmpty ? id.uuidString : "\(id.uuidString).\(pathExtension)"
    }

    @concurrent
    static func decodeImage(at url: URL, maxPixel: Int = stagePixelSize) async -> DecodedImage? {
        downsample(url, maxPixel: maxPixel).map(DecodedImage.init)
    }

    // MARK: PDF

    @concurrent
    private static func importPDFPage(_ number: Int, of pdf: PDFSource, into package: DeckPackage) async throws -> Slide {
        guard let image = render(pageNumber: number, of: pdf.document) else { throw ImportError.unsupported }
        let id = UUID()
        let slide = Slide(
            id: id,
            kind: .image,
            fileName: mediaFileName(id: id, extension: "png"),
            title: "\(pdf.url.deletingPathExtension().lastPathComponent) – \(number)"
        )
        try package.createDirectories()
        try write(image, as: .png, to: package.mediaURL(for: slide))
        try writeJPEG(scaled(image, maxPixel: thumbnailPixelSize), to: package.thumbnailURL(for: slide))
        return slide
    }

    private static func render(pageNumber: Int, of document: CGPDFDocument) -> CGImage? {
        guard let page = document.page(at: pageNumber) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let isSideways = page.rotationAngle % 180 != 0
        let pageSize = isSideways ? CGSize(width: box.height, height: box.width) : box.size
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }

        let scale = CGFloat(pdfPixelSize) / max(pageSize.width, pageSize.height)
        let width = max(1, Int((pageSize.width * scale).rounded()))
        let height = max(1, Int((pageSize.height * scale).rounded()))
        guard let context = bitmapContext(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // getDrawingTransform sayfayı yalnızca küçültür; büyütme ölçeği ayrıca uygulanır.
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(
            .cropBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true
        ))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    // MARK: Görüntü yardımcıları

    private static func contentType(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
    }

    /// Klasörleri içlerindeki desteklenen dosyalara (ada göre sıralı) açar; dosyaları olduğu gibi bırakır.
    private static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else { return [url] }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentTypeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents
                .filter { kind(of: $0) != nil || isPDF($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
    }

    /// Poster görselini ve ondan küçültülmüş küçük resmi yazar.
    private static func writePoster(_ image: CGImage, for slide: Slide, in package: DeckPackage) throws {
        try writeJPEG(image, to: package.posterURL(for: slide), quality: 0.9)
        try writeJPEG(scaled(image, maxPixel: thumbnailPixelSize), to: package.thumbnailURL(for: slide))
    }

    /// Görüntüyü EXIF yönünü uygulayarak en fazla `maxPixel` kenar uzunluğunda çözer (büyütmez).
    private static func downsample(_ url: URL, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return downsample(source, maxPixel: maxPixel)
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsample(source, maxPixel: maxPixel)
    }

    private static func downsample(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func scaled(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longestSide = max(image.width, image.height)
        guard longestSide > maxPixel else { return image }
        let scale = CGFloat(maxPixel) / CGFloat(longestSide)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = bitmapContext(width: width, height: height) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }

    private static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.8) throws {
        try write(image, as: .jpeg, to: url, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func write(
        _ image: CGImage, as type: UTType, to url: URL, properties: [CFString: Any] = [:]
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
