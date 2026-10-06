import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Arka planda çözülen görüntüyü ana aktöre taşımak için.
nonisolated struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Dosyaları pakete kopyalar ve küçük resimlerini üretir. Ağır işler ana aktörün dışında çalışır.
nonisolated enum MediaImporter {
    enum ImportError: Error {
        case unsupported
    }

    static let thumbnailPixelSize = 480
    static let posterPixelSize = 2560
    static let stagePixelSize = 3840

    static func kind(of url: URL) -> MediaKind? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        return nil
    }

    /// Klasörleri içlerindeki resim ve videolara (ada göre sıralı) açar; dosyaları olduğu gibi bırakır.
    static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else { return [url] }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentTypeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents
                .filter { kind(of: $0) != nil }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
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
        case .video:
            let asset = AVURLAsset(url: source)
            guard try await asset.load(.isPlayable) else { throw ImportError.unsupported }
            let seconds = try await asset.load(.duration).seconds
            duration = seconds.isFinite ? seconds : nil
        }

        let id = UUID()
        let fileExtension = source.pathExtension.lowercased()
        let slide = Slide(
            id: id,
            kind: kind,
            fileName: fileExtension.isEmpty ? id.uuidString : "\(id.uuidString).\(fileExtension)",
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
            let poster = try await generator.image(at: .zero).image
            try writeJPEG(poster, to: package.posterURL(for: slide), quality: 0.9)
            try writeJPEG(scaled(poster, maxPixel: thumbnailPixelSize), to: package.thumbnailURL(for: slide))
        }
    }

    static func removeFiles(for slide: Slide, in package: DeckPackage) {
        let urls = [package.mediaURL(for: slide), package.thumbnailURL(for: slide), package.posterURL(for: slide)]
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @concurrent
    static func decodeImage(at url: URL, maxPixel: Int = stagePixelSize) async -> DecodedImage? {
        downsample(url, maxPixel: maxPixel).map(DecodedImage.init)
    }

    /// Görüntüyü EXIF yönünü uygulayarak en fazla `maxPixel` kenar uzunluğunda çözer (büyütmez).
    private static func downsample(_ url: URL, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
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
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.8) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
