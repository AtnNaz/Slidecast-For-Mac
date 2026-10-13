import Foundation
import Testing
@testable import Sunummodu

@Suite struct DeckStoreTests {
    let temp: TemporaryDirectory
    let store: DeckStore
    let undoManager = UndoManager()

    init() throws {
        temp = try TemporaryDirectory()
        store = DeckStore(draftURL: temp.file("Taslak.sunum"))
        // Uygulamada her kullanıcı işlemi ayrı olaydır; testte her işlem ayrı adım olsun.
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
    }

    private var titles: [String] { store.slides.map(\.title) }

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

    @Test func draftNameIsShownUntilSaved() throws {
        let named = DeckStore(draftURL: temp.file("Deneme.sunum"), draftName: "Deneme Sunumu")
        #expect(named.displayName == "Deneme Sunumu")
        try named.saveAs(to: temp.file("Kayıtlı.sunum"))
        #expect(named.displayName == "Kayıtlı")
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

    // MARK: Geri alma

    @Test func undoRestoresRemovedSlideWithItsFiles() async throws {
        await store.importFiles(try makeImages("a.png", "b.png", "c.png"))
        let removed = store.slides[1]
        let media = store.package.mediaURL(for: removed)

        store.remove(removed.id)
        #expect(titles == ["a", "c"])
        #expect(!fileExists(media))
        #expect(undoManager.undoActionName == "Slaytı Sil")

        undoManager.undo()
        #expect(titles == ["a", "b", "c"])
        #expect(fileExists(media))
        #expect(fileExists(store.package.thumbnailURL(for: removed)))

        undoManager.redo()
        #expect(titles == ["a", "c"])
        #expect(!fileExists(media))
    }

    @Test func removingSeveralSlidesIsOneUndoStep() async throws {
        await store.importFiles(try makeImages("a.png", "b.png", "c.png", "d.png"))
        store.remove([store.slides[0].id, store.slides[2].id])
        #expect(titles == ["b", "d"])
        #expect(undoManager.undoActionName == "Slaytları Sil")

        undoManager.undo()
        #expect(titles == ["a", "b", "c", "d"])
        #expect(store.slides.allSatisfy { fileExists(store.package.mediaURL(for: $0)) })
    }

    @Test func undoRevertsReorderButKeepsLaterNotes() async throws {
        await store.importFiles(try makeImages("a.png", "b.png", "c.png"))
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(titles == ["c", "a", "b"])
        store.setNotes("sonradan yazıldı", for: store.slides[1].id)

        undoManager.undo()
        #expect(titles == ["a", "b", "c"])
        #expect(store.slides[0].notes == "sonradan yazıldı")
    }

    @Test func wholeImportIsOneUndoStep() async throws {
        await store.importFiles(try makeImages("a.png"))
        await store.importFiles(try makeImages("b.png", "c.png"), at: 0)
        #expect(titles == ["b", "c", "a"])
        let imported = Array(store.slides[0...1])

        undoManager.undo()
        #expect(titles == ["a"])
        #expect(imported.allSatisfy { !fileExists(store.package.mediaURL(for: $0)) })

        undoManager.redo()
        #expect(titles == ["b", "c", "a"])
        #expect(imported.allSatisfy { fileExists(store.package.mediaURL(for: $0)) })
    }

    @Test func duplicatePlacesCopiesAfterOriginals() async throws {
        await store.importFiles(try makeImages("a.png", "b.png", "c.png"))
        store.setNotes("not", for: store.slides[0].id)

        let copies = await store.duplicate([store.slides[0].id, store.slides[2].id])

        #expect(titles == ["a", "a kopya", "b", "c", "c kopya"])
        #expect(copies == [store.slides[1].id, store.slides[4].id])
        #expect(store.slides[1].notes == "not")
        #expect(Set(store.slides.map(\.id)).count == 5)
        #expect(Set(store.slides.map(\.fileName)).count == 5)
        #expect(store.slides.allSatisfy { fileExists(store.package.mediaURL(for: $0)) })
        #expect(store.slides.allSatisfy { fileExists(store.package.thumbnailURL(for: $0)) })

        undoManager.undo()
        #expect(titles == ["a", "b", "c"])
    }

    @Test func renameAndScalingCanBeUndone() async throws {
        await store.importFiles(try makeImages("a.png", "b.png"))
        let ids = Set(store.slides.map(\.id))

        store.setTitle("Kapak", for: store.slides[0].id)
        store.setScaling(.fill, for: ids)
        #expect(titles == ["Kapak", "b"])
        #expect(store.slides.allSatisfy { $0.scaling == .fill })

        undoManager.undo()
        #expect(store.slides.allSatisfy { $0.scaling == .fit })
        undoManager.undo()
        #expect(titles == ["a", "b"])
        undoManager.redo()
        undoManager.redo()
        #expect(titles == ["Kapak", "b"])
        #expect(store.slides.allSatisfy { $0.scaling == .fill })
    }

    @Test func undoHistoryDoesNotCrossDecks() async throws {
        await store.importFiles(try makeImages("a.png"))
        let saved = temp.file("Kayıtlı.sunum")
        try store.saveAs(to: saved)
        store.remove(store.slides[0].id)
        #expect(undoManager.canUndo)

        try store.resetDraft()
        #expect(!undoManager.canUndo)
        #expect(store.slides.isEmpty)
    }

    @Test func undoStillWorksAfterSaveAs() async throws {
        await store.importFiles(try makeImages("a.png", "b.png"))
        let removed = store.slides[0]
        store.remove(removed.id)

        try store.saveAs(to: temp.file("Kayıtlı.sunum"))
        undoManager.undo()

        #expect(titles == ["a", "b"])
        #expect(fileExists(store.package.mediaURL(for: removed)))
    }

    @Test func readsDecksWrittenBeforeScalingExisted() throws {
        let id = UUID()
        let json = """
        {"version":1,"slides":[{"id":"\(id.uuidString)","kind":"image","fileName":"x.png","title":"Eski","notes":""}]}
        """
        let package = DeckPackage(url: temp.file("Eski.sunum"))
        try package.createDirectories()
        try Data(json.utf8).write(to: package.manifestURL)

        try store.open(package.url)

        #expect(store.slides == [Slide(id: id, kind: .image, fileName: "x.png", title: "Eski")])
        #expect(store.slides[0].scaling == .fit)
    }

    // MARK: Arka plan müziği

    private func makeAudio(_ name: String, seconds: Double = 1) throws -> URL {
        let url = temp.file(name)
        try TestMedia.writeAudio(to: url, seconds: seconds)
        return url
    }

    @Test func backgroundAudioIsSharedByImageSlidesAndUndoable() async throws {
        await store.importFiles(try makeImages("a.png", "b.png") + [try makeAudio("konuşma.wav")])
        let ids = Set(store.slides.map(\.id))

        let assigned = try await store.setBackgroundAudio(from: try makeAudio("Fon.wav"), for: ids)

        #expect(assigned == 2)
        let audio = try #require(store.slides[0].backgroundAudio)
        #expect(audio.title == "Fon")
        #expect(store.slides[1].backgroundAudio == audio)
        #expect(store.slides[2].backgroundAudio == nil)
        #expect(fileExists(try #require(store.package.backgroundAudioURL(for: store.slides[0]))))
        #expect(undoManager.undoActionName == "Arka Plan Müziği")

        undoManager.undo()
        #expect(store.slides.allSatisfy { $0.backgroundAudio == nil })
        undoManager.redo()
        #expect(store.slides[0].backgroundAudio == audio)
        #expect(store.slides[1].backgroundAudio == audio)

        store.removeBackgroundAudio(for: [store.slides[0].id])
        #expect(store.slides[0].backgroundAudio == nil)
        #expect(store.slides[1].backgroundAudio == audio)
    }

    @Test func backgroundAudioNeedsAnImageSlideAndARealAudioFile() async throws {
        await store.importFiles(try makeImages("a.png") + [try makeAudio("konuşma.wav")])

        let onAudioSlide = try await store.setBackgroundAudio(from: try makeAudio("Fon.wav"), for: [store.slides[1].id])
        #expect(onAudioSlide == 0)

        let notAudio = try makeImages("resim.png")[0]
        await #expect(throws: (any Error).self) {
            try await store.setBackgroundAudio(from: notAudio, for: [store.slides[0].id])
        }
        #expect(store.slides.allSatisfy { $0.backgroundAudio == nil })
    }

    @Test func duplicatedSlideSharesTheSameBackgroundAudio() async throws {
        await store.importFiles(try makeImages("a.png"))
        try await store.setBackgroundAudio(from: try makeAudio("Fon.wav"), for: [store.slides[0].id])

        await store.duplicate([store.slides[0].id])

        #expect(store.slides.count == 2)
        #expect(store.slides[1].backgroundAudio == store.slides[0].backgroundAudio)
    }

    @Test func unusedBackgroundAudioIsRemovedWhenTheDeckCloses() async throws {
        await store.importFiles(try makeImages("a.png"))
        let id = store.slides[0].id
        try await store.setBackgroundAudio(from: try makeAudio("Eski.wav"), for: [id])
        let old = try #require(store.package.backgroundAudioURL(for: store.slides[0]))
        try await store.setBackgroundAudio(from: try makeAudio("Yeni.wav"), for: [id])
        let new = try #require(store.package.backgroundAudioURL(for: store.slides[0]))

        // Geri alınabildiği sürece eski dosya durur.
        #expect(fileExists(old))
        store.close()

        #expect(!fileExists(old))
        #expect(fileExists(new))
        #expect(DeckStore(draftURL: store.draftURL).slides[0].backgroundAudio?.title == "Yeni")
    }
}
