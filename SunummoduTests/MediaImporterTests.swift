import Foundation
import Testing
@testable import Sunummodu

@Suite struct MediaImporterTests {
    @Test(arguments: ["foto.jpg", "foto.JPEG", "ekran.png", "resim.heic", "eski.tiff"])
    func recognizesImages(name: String) {
        #expect(MediaImporter.kind(of: URL(fileURLWithPath: "/tmp/\(name)")) == .image)
    }

    @Test(arguments: ["klip.mp4", "klip.mov", "klip.M4V"])
    func recognizesVideos(name: String) {
        #expect(MediaImporter.kind(of: URL(fileURLWithPath: "/tmp/\(name)")) == .video)
    }

    @Test(arguments: ["ses.mp3", "ses.m4a", "ses.WAV"])
    func recognizesAudio(name: String) {
        #expect(MediaImporter.kind(of: URL(fileURLWithPath: "/tmp/\(name)")) == .audio)
    }

    @Test(arguments: ["notlar.txt", "belge.pdf", "sunum.pptx", "uzantisiz"])
    func rejectsOtherFiles(name: String) {
        #expect(MediaImporter.kind(of: URL(fileURLWithPath: "/tmp/\(name)")) == nil)
    }

    @Test func pdfPagesBecomeImageSlides() async throws {
        let temp = try TemporaryDirectory()
        let pdf = temp.file("Sunum.pdf")
        try TestMedia.writePDF(to: pdf, pageSizes: [
            CGSize(width: 960, height: 540), CGSize(width: 960, height: 540), CGSize(width: 595, height: 842),
        ])
        let store = DeckStore(draftURL: temp.file("Taslak.sunum"))

        #expect(MediaImporter.isPDF(pdf))
        #expect(MediaImporter.sources(for: [pdf]).count == 3)
        await store.importFiles([pdf])

        #expect(store.slides.map(\.title) == ["Sunum – 1", "Sunum – 2", "Sunum – 3"])
        #expect(store.slides.allSatisfy { $0.kind == .image })
        #expect(store.slides.allSatisfy { fileExists(store.package.thumbnailURL(for: $0)) })
        #expect(store.skippedFiles.isEmpty)

        let wide = try #require(await MediaImporter.decodeImage(at: store.package.mediaURL(for: store.slides[0])))
        #expect(wide.cgImage.width == MediaImporter.pdfPixelSize)
        #expect(wide.cgImage.height == MediaImporter.pdfPixelSize * 540 / 960)
        let tall = try #require(await MediaImporter.decodeImage(at: store.package.mediaURL(for: store.slides[2])))
        #expect(tall.cgImage.height == MediaImporter.pdfPixelSize)
        #expect(tall.cgImage.width < tall.cgImage.height)
    }

    @Test func unreadablePDFIsReportedOnce() async throws {
        let temp = try TemporaryDirectory()
        let broken = temp.file("bozuk.pdf")
        try Data("pdf değil".utf8).write(to: broken)
        let store = DeckStore(draftURL: temp.file("Taslak.sunum"))

        await store.importFiles([broken])

        #expect(store.slides.isEmpty)
        #expect(store.skippedFiles == ["bozuk.pdf"])
    }

    @Test func audioImportReadsDurationAndTakesChosenArtwork() async throws {
        let temp = try TemporaryDirectory()
        let source = temp.file("Müzik.wav")
        try TestMedia.writeAudio(to: source, seconds: 2)
        let package = DeckPackage(url: temp.file("Deste.sunum"))

        let slide = try await MediaImporter.importFile(at: source, into: package)

        #expect(slide.kind == .audio)
        #expect(slide.title == "Müzik")
        #expect(abs(try #require(slide.duration) - 2) < 0.1)
        #expect(fileExists(package.mediaURL(for: slide)))
        // Gömülü kapak yok: sahne siyah kalır.
        #expect(!fileExists(package.stageImageURL(for: slide)))

        let cover = temp.file("kapak.png")
        try TestMedia.writePNG(to: cover, width: 800, height: 600)
        try await MediaImporter.setArtwork(from: cover, for: slide, in: package)
        #expect(fileExists(package.stageImageURL(for: slide)))
        #expect(fileExists(package.thumbnailURL(for: slide)))

        MediaImporter.removeArtwork(for: slide, in: package)
        #expect(!fileExists(package.stageImageURL(for: slide)))
        #expect(fileExists(package.mediaURL(for: slide)))
    }

    @Test func videoImportReadsDurationAndWritesPoster() async throws {
        let temp = try TemporaryDirectory()
        let source = temp.file("Tanıtım.mov")
        try await TestMedia.writeVideo(to: source, seconds: 2)
        let package = DeckPackage(url: temp.file("Deste.sunum"))

        let slide = try await MediaImporter.importFile(at: source, into: package)

        #expect(slide.kind == .video)
        #expect(slide.title == "Tanıtım")
        #expect(abs(try #require(slide.duration) - 2) < 0.2)
        #expect(fileExists(package.mediaURL(for: slide)))
        #expect(fileExists(package.posterURL(for: slide)))
        #expect(fileExists(package.thumbnailURL(for: slide)))
        #expect(package.stageImageURL(for: slide) == package.posterURL(for: slide))
    }

    @Test func largeImageThumbnailIsDownsampled() async throws {
        let temp = try TemporaryDirectory()
        let source = temp.file("buyuk.png")
        try TestMedia.writePNG(to: source, width: 2000, height: 1000)
        let package = DeckPackage(url: temp.file("Deste.sunum"))

        let slide = try await MediaImporter.importFile(at: source, into: package)
        let thumbnail = try #require(await MediaImporter.decodeImage(at: package.thumbnailURL(for: slide)))
        let full = try #require(await MediaImporter.decodeImage(at: package.stageImageURL(for: slide)))

        #expect(thumbnail.cgImage.width == MediaImporter.thumbnailPixelSize)
        #expect(thumbnail.cgImage.height == MediaImporter.thumbnailPixelSize / 2)
        #expect(full.cgImage.width == 2000)
    }

    @Test func timecodes() {
        #expect(Timecode.string(0) == "0:00")
        #expect(Timecode.string(65.9) == "1:05")
        #expect(Timecode.string(3725) == "1:02:05")
        #expect(Timecode.string(.nan) == "0:00")
        #expect(Timecode.elapsed(765) == "00:12:45")
    }
}
