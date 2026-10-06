import Foundation
import Testing
@testable import Sunummodu

@Suite struct DeckStoreTests {
    let temp: TemporaryDirectory
    let store: DeckStore

    init() throws {
        temp = try TemporaryDirectory()
        store = DeckStore(draftURL: temp.file("Taslak.sunum"))
    }

    private func makeImages(_ names: String...) throws -> [URL] {
        try names.map { name in
            let url = temp.file(name)
            try TestMedia.writePNG(to: url)
            return url
        }
    }

    @Test func startsAsEmptyDraftOnDisk() {
        #expect(store.isDraft)
        #expect(store.displayName == "Adsız Sunum")
        #expect(store.slides.isEmpty)
        #expect(fileExists(store.package.manifestURL))
    }

    @Test func importCopiesMediaAndKeepsOrder() async throws {
        let sources = try makeImages("a.png", "b.png")
        await store.importFiles(sources)

        #expect(store.slides.map(\.title) == ["a", "b"])
        #expect(store.slides.allSatisfy { $0.kind == .image })
        for slide in store.slides {
            #expect(fileExists(store.package.mediaURL(for: slide)))
            #expect(fileExists(store.package.thumbnailURL(for: slide)))
        }
        #expect(sources.allSatisfy(fileExists))
        #expect(!store.isImporting)
        #expect(store.skippedFiles.isEmpty)
    }

    @Test func importAtIndexInsertsInPlace() async throws {
        await store.importFiles(try makeImages("a.png", "b.png"))
        await store.importFiles(try makeImages("c.png", "d.png"), at: 1)
        #expect(store.slides.map(\.title) == ["a", "c", "d", "b"])
    }

    @Test func unsupportedFilesAreSkippedAndReported() async throws {
        let text = temp.file("notlar.txt")
        try Data("merhaba".utf8).write(to: text)
        let broken = temp.file("bozuk.png")
        try Data("resim değil".utf8).write(to: broken)

        await store.importFiles([text, broken] + (try makeImages("gecerli.png")))

        #expect(store.slides.map(\.title) == ["gecerli"])
        #expect(store.skippedFiles == ["notlar.txt", "bozuk.png"])
    }

    @Test func folderImportTakesOnlyMediaSortedByName() async throws {
        let folder = temp.file("Klasör")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestMedia.writePNG(to: folder.appendingPathComponent("10.png"))
        try TestMedia.writePNG(to: folder.appendingPathComponent("2.png"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("oku.txt"))

        await store.importFiles([folder])

        #expect(store.slides.map(\.title) == ["2", "10"])
        #expect(store.skippedFiles.isEmpty)
    }

    @Test func removeDeletesPackagedCopyButNotOriginal() async throws {
        let sources = try makeImages("a.png", "b.png")
        await store.importFiles(sources)
        let removed = store.slides[0]

        store.remove(removed.id)

        #expect(store.slides.map(\.title) == ["b"])
        #expect(!fileExists(store.package.mediaURL(for: removed)))
        #expect(!fileExists(store.package.thumbnailURL(for: removed)))
        #expect(fileExists(sources[0]))
    }

    @Test func moveReorders() async throws {
        await store.importFiles(try makeImages("a.png", "b.png", "c.png"))
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.slides.map(\.title) == ["b", "c", "a"])
    }

    @Test func changesSurviveReopen() async throws {
        await store.importFiles(try makeImages("a.png", "b.png"))
        store.setNotes("Önce selam ver", for: store.slides[1].id)
        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        store.flush()

        let reopened = DeckStore(draftURL: store.draftURL)

        #expect(reopened.slides == store.slides)
        #expect(reopened.slides[0].notes == "Önce selam ver")
    }

    @Test func saveAsMovesDraftAndKeepsSavingThere() async throws {
        await store.importFiles(try makeImages("a.png"))
        let draft = store.package
        let destination = temp.file("Kayıtlı.sunum")

        try store.saveAs(to: destination)

        #expect(!store.isDraft)
        #expect(store.displayName == "Kayıtlı")
        #expect(fileExists(store.package.mediaURL(for: store.slides[0])))
        #expect(!fileExists(draft.url))

        store.setNotes("yeni not", for: store.slides[0].id)
        store.flush()
        let other = DeckStore(draftURL: temp.file("Diğer.sunum"))
        try other.open(destination)
        #expect(other.slides == store.slides)
        #expect(other.slides[0].notes == "yeni not")
    }

    @Test func saveAsReplacesExistingDeck() async throws {
        let destination = temp.file("Sunum.sunum")
        let old = DeckStore(draftURL: temp.file("Eski.sunum"))
        await old.importFiles(try makeImages("eski.png"))
        try old.saveAs(to: destination)

        await store.importFiles(try makeImages("yeni.png"))
        try store.saveAs(to: destination)

        let reopened = DeckStore(draftURL: temp.file("Diğer.sunum"))
        try reopened.open(destination)
        #expect(reopened.slides.map(\.title) == ["yeni"])
        #expect(fileExists(reopened.package.mediaURL(for: reopened.slides[0])))
    }

    @Test func openingMissingDeckThrowsAndKeepsCurrent() async throws {
        await store.importFiles(try makeImages("a.png"))
        #expect(throws: (any Error).self) {
            try store.open(temp.file("yok.sunum"))
        }
        #expect(store.isDraft)
        #expect(store.slides.map(\.title) == ["a"])
    }

    @Test func resetDraftEmptiesIt() async throws {
        await store.importFiles(try makeImages("a.png"))
        let media = store.package.mediaURL(for: store.slides[0])

        try store.resetDraft()

        #expect(store.isDraft)
        #expect(store.slides.isEmpty)
        #expect(!fileExists(media))
        #expect(fileExists(store.package.manifestURL))
    }
}
