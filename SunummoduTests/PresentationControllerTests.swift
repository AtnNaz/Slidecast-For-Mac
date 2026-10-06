import Foundation
import Testing
@testable import Sunummodu

@Suite struct PresentationControllerTests {
    let temp: TemporaryDirectory
    let store: DeckStore
    let defaults: UserDefaults
    let presentation: PresentationController

    /// Deste: resim "a", resim "b", bir saniyelik video "klip".
    init() async throws {
        temp = try TemporaryDirectory()
        store = DeckStore(draftURL: temp.file("Taslak.sunum"))
        defaults = try #require(UserDefaults(suiteName: "SunummoduTests-\(UUID().uuidString)"))
        let screens = ScreenManager()
        // Testte çıkış harici ekrana tam ekran açılmasın.
        screens.target = .window
        presentation = PresentationController(
            store: store, playback: PlaybackController(defaults: defaults), screens: screens, images: ImageStore()
        )

        let a = temp.file("a.png")
        let b = temp.file("b.png")
        let clip = temp.file("klip.mov")
        try TestMedia.writePNG(to: a)
        try TestMedia.writePNG(to: b)
        try await TestMedia.writeVideo(to: clip)
        await store.importFiles([a, b, clip])
        presentation.ensureSelection()
    }

    private var titles: [String] { store.slides.map(\.title) }

    @Test func selectsFirstSlide() {
        #expect(titles == ["a", "b", "klip"])
        #expect(presentation.currentSlide?.title == "a")
        #expect(presentation.nextSlide?.title == "b")
        #expect(!presentation.canGoPrevious)
        #expect(presentation.canGoNext)
    }

    @Test func navigationStopsAtBothEnds() {
        presentation.previous()
        #expect(presentation.currentIndex == 0)

        presentation.next()
        presentation.next()
        #expect(presentation.currentIndex == 2)
        #expect(presentation.nextSlide == nil)
        #expect(!presentation.canGoNext)

        presentation.next()
        #expect(presentation.currentIndex == 2)

        presentation.goToFirst()
        #expect(presentation.currentIndex == 0)
        presentation.goToLast()
        #expect(presentation.currentIndex == 2)
    }

    @Test func deletingCurrentSlideMovesToNeighbor() throws {
        presentation.go(toIndex: 1)
        presentation.delete(try #require(presentation.currentID))
        #expect(titles == ["a", "klip"])
        #expect(presentation.currentSlide?.title == "klip")

        presentation.delete(try #require(presentation.currentID))
        #expect(presentation.currentSlide?.title == "a")

        presentation.delete(try #require(presentation.currentID))
        #expect(store.slides.isEmpty)
        #expect(presentation.currentSlide == nil)
        #expect(!presentation.playback.hasVideo)
    }

    @Test func deletingAnotherSlideKeepsCurrent() {
        presentation.go(toIndex: 1)
        presentation.delete(store.slides[0].id)
        #expect(presentation.currentSlide?.title == "b")
        #expect(presentation.currentIndex == 0)
    }

    @Test func videoIsLoadedPausedWhileNotPresenting() async {
        let playback = presentation.playback
        #expect(!playback.hasVideo)

        presentation.goToLast()
        #expect(playback.hasVideo)
        #expect(abs(playback.duration - 1) < 0.2)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!playback.isPlaying)
        #expect(playback.currentTime == 0)

        presentation.goToFirst()
        #expect(!playback.hasVideo)
    }

    @Test func videoAutoplaysWhenPresentingAndHoldsLastFrame() async {
        let playback = presentation.playback
        presentation.start()
        #expect(presentation.isPresenting)
        #expect(presentation.startedAt != nil)
        #expect(!playback.isPlaying)

        presentation.goToLast()
        #expect(await waitUntil { playback.isPlaying && playback.currentTime > 0.2 })

        // Bitince durur ve son karede kalır.
        #expect(await waitUntil { !playback.isPlaying })
        #expect(playback.currentTime > playback.duration - 0.2)

        // Sondayken Başlat baştan oynatır.
        playback.togglePlayPause()
        #expect(await waitUntil { playback.isPlaying && playback.currentTime < 0.6 })

        playback.togglePlayPause()
        #expect(await waitUntil { !playback.isPlaying })

        presentation.stop()
        #expect(!presentation.isPresenting)
        #expect(presentation.startedAt == nil)
    }

    @Test func blackoutOnlyWhilePresentingAndClearsOnNavigation() {
        presentation.toggleBlackout()
        #expect(!presentation.isBlackedOut)

        presentation.start()
        presentation.toggleBlackout()
        #expect(presentation.isBlackedOut)
        presentation.next()
        #expect(!presentation.isBlackedOut)
        presentation.stop()
    }

    @Test func volumeStepsClampPersistAndUnmute() {
        let playback = presentation.playback
        #expect(playback.volume == 1)

        playback.adjustVolume(by: PlaybackController.volumeStep)
        #expect(playback.volume == 1)

        playback.adjustVolume(by: -PlaybackController.volumeStep)
        playback.adjustVolume(by: -PlaybackController.volumeStep)
        #expect(abs(playback.volume - 0.8) < 0.001)
        #expect(abs(playback.player.volume - 0.8) < 0.001)
        #expect(abs(PlaybackController(defaults: defaults).volume - 0.8) < 0.001)

        playback.toggleMute()
        #expect(playback.isMuted)
        #expect(playback.player.isMuted)
        playback.adjustVolume(by: PlaybackController.volumeStep)
        #expect(!playback.isMuted)

        playback.setVolume(-3)
        #expect(playback.volume == 0)
    }

    @Test func switchingDeckSelectsItsFirstSlideAndEndsPresentation() async throws {
        let other = temp.file("Diğer.sunum")
        let otherStore = DeckStore(draftURL: other)
        let image = temp.file("z.png")
        try TestMedia.writePNG(to: image)
        await otherStore.importFiles([image])
        otherStore.flush()

        presentation.goToLast()
        presentation.start()
        try store.open(other)
        presentation.deckDidChange()

        #expect(!presentation.isPresenting)
        #expect(presentation.currentSlide?.title == "z")
        #expect(!presentation.playback.hasVideo)
    }
}
