import Foundation
import Testing
@testable import Sunummodu

@Suite struct PresentationControllerTests {
    let temp: TemporaryDirectory
    let store: DeckStore
    let settings = InMemorySettings()
    let presentation: PresentationController

    /// Deste: resim "a", resim "b", bir saniyelik video "klip".
    init() async throws {
        temp = try TemporaryDirectory()
        store = DeckStore(draftURL: temp.file("Taslak.sunum"))
        let screens = ScreenManager()
        // Testte çıkış harici ekrana tam ekran açılmasın.
        screens.target = .window
        presentation = PresentationController(
            store: store, playback: PlaybackController(settings: settings), screens: screens, images: ImageStore(),
            settings: settings
        )

        let a = temp.file("a.png")
        let b = temp.file("b.png")
        let clip = temp.file("klip.mov")
        try TestMedia.writePNG(to: a)
        try TestMedia.writePNG(to: b)
        try await TestMedia.writeVideo(to: clip)
        await store.importFiles([a, b, clip])
        presentation.slidesDidChange()
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
        #expect(!presentation.playback.hasMedia)
    }

    @Test func deletingAnotherSlideKeepsCurrent() {
        presentation.go(toIndex: 1)
        presentation.delete(store.slides[0].id)
        #expect(presentation.currentSlide?.title == "b")
        #expect(presentation.currentIndex == 0)
    }

    @Test func videoIsLoadedPausedWhileNotPresenting() async {
        let playback = presentation.playback
        #expect(!playback.hasMedia)

        presentation.goToLast()
        #expect(playback.hasMedia)
        #expect(abs(playback.duration - 1) < 0.2)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!playback.isPlaying)
        #expect(playback.currentTime == 0)

        presentation.goToFirst()
        #expect(!playback.hasMedia)
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
        #expect(abs(PlaybackController(settings: settings).volume - 0.8) < 0.001)

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
        #expect(!presentation.playback.hasMedia)
    }

    @Test func multiSelectionDoesNotChangeShownSlide() {
        let ids = store.slides.map(\.id)
        presentation.select([ids[1]])
        #expect(presentation.currentID == ids[1])
        #expect(presentation.selection == [ids[1]])

        presentation.select([ids[0], ids[1], ids[2]])
        #expect(presentation.currentID == ids[1])
        #expect(presentation.selection.count == 3)

        presentation.select([])
        #expect(presentation.selection.count == 3)

        presentation.next()
        #expect(presentation.currentID == ids[2])
        #expect(presentation.selection == [ids[2]])
    }

    @Test func deletingSelectionIncludingShownSlideMovesToNextSurvivor() {
        let ids = store.slides.map(\.id)
        presentation.select([ids[0]])
        presentation.select([ids[0], ids[1]])

        presentation.delete(presentation.selection)

        #expect(titles == ["klip"])
        #expect(presentation.currentID == ids[2])
        #expect(presentation.selection == [ids[2]])
        #expect(presentation.playback.hasMedia)
    }

    @Test func undoAndRedoKeepAValidShownSlide() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        presentation.goToLast()
        let clip = presentation.currentID

        presentation.delete(presentation.selection)
        #expect(presentation.currentSlide?.title == "b")

        undoManager.undo()
        presentation.slidesDidChange()
        #expect(titles == ["a", "b", "klip"])
        #expect(presentation.currentSlide?.title == "b")

        presentation.go(to: clip)
        undoManager.redo()
        presentation.slidesDidChange()
        #expect(titles == ["a", "b"])
        #expect(presentation.currentSlide?.title == "b")
        #expect(presentation.selection == [store.slides[1].id])
    }

    @Test func audioSlidePlaysLikeVideo() async throws {
        let music = temp.file("müzik.wav")
        try TestMedia.writeAudio(to: music, seconds: 1)
        await store.importFiles([music])
        let playback = presentation.playback

        presentation.goToLast()
        #expect(presentation.currentSlide?.kind == .audio)
        #expect(playback.hasMedia)
        #expect(abs(playback.duration - 1) < 0.1)

        presentation.start()
        #expect(await waitUntil { playback.isPlaying && playback.currentTime > 0.2 })
        #expect(await waitUntil { !playback.isPlaying })
        presentation.stop()
    }

    @Test func transitionDefaultsToHalfSecondAndIsRemembered() {
        #expect(presentation.transitionDuration == 0.5)
        #expect(presentation.activeTransitionDuration == 0)

        presentation.transitionDuration = 1
        presentation.start()
        #expect(presentation.activeTransitionDuration == 1)
        presentation.stop()

        let reloaded = PresentationController(
            store: store, playback: PlaybackController(settings: settings), screens: ScreenManager(),
            images: ImageStore(), settings: settings
        )
        #expect(reloaded.transitionDuration == 1)
    }

    @Test func outgoingVideoKeepsItsPlayerAndFadesOutDuringTransition() async {
        let playback = presentation.playback
        presentation.transitionDuration = 0.4
        presentation.start()
        presentation.goToLast()
        #expect(await waitUntil { playback.isPlaying && playback.currentTime > 0.1 })
        let videoPlayer = playback.player
        let generation = presentation.transitionGeneration

        presentation.goToFirst()

        // Yeni slayt öbür oynatıcıda; giden video geçiş boyunca kendi oynatıcısında oynamayı sürdürür.
        #expect(presentation.transitionGeneration == generation + 1)
        #expect(playback.player !== videoPlayer)
        #expect(!playback.hasMedia)
        #expect(!playback.isPlaying)
        #expect(videoPlayer.currentItem != nil)
        #expect(videoPlayer.timeControlStatus != .paused)

        #expect(await waitUntil { videoPlayer.timeControlStatus == .paused })
        #expect(videoPlayer.volume == playback.volume)
        presentation.stop()
    }

    @Test func returningToVideoMidFadeDoesNotPauseIt() async throws {
        let playback = presentation.playback
        presentation.transitionDuration = 0.4
        presentation.start()
        presentation.goToLast()
        #expect(await waitUntil { playback.isPlaying && playback.currentTime > 0.1 })

        presentation.go(toIndex: 1)
        presentation.goToLast()

        #expect(await waitUntil { playback.isPlaying && playback.currentTime > 0.1 })
        // İlk geçişin kısılma süresi dolduktan sonra da oynuyor ve sesi tam olmalı.
        try await Task.sleep(for: .milliseconds(500))
        #expect(playback.isPlaying)
        #expect(playback.player.volume == playback.volume)
        presentation.stop()
    }

    @Test func withoutTransitionOutgoingVideoStopsImmediately() async {
        let playback = presentation.playback
        presentation.transitionDuration = 0
        presentation.start()
        presentation.goToLast()
        #expect(await waitUntil { playback.isPlaying })
        let videoPlayer = playback.player

        presentation.goToFirst()

        #expect(await waitUntil { videoPlayer.timeControlStatus == .paused })
        presentation.stop()
    }
}
