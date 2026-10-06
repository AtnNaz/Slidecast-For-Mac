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

    @Test(arguments: ["notlar.txt", "belge.pdf", "ses.mp3", "sunum.pptx", "uzantisiz"])
    func rejectsOtherFiles(name: String) {
        #expect(MediaImporter.kind(of: URL(fileURLWithPath: "/tmp/\(name)")) == nil)
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
