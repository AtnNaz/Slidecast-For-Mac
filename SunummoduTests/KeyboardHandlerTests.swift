import AppKit
import Testing
@testable import Sunummodu

@Suite struct KeyboardHandlerTests {
    let temp: TemporaryDirectory
    let presentation: PresentationController

    /// Deste: resim "a", bir saniyelik video "klip", resim "b".
    init() async throws {
        temp = try TemporaryDirectory()
        let store = DeckStore(draftURL: temp.file("Taslak.sunum"))
        let settings = InMemorySettings()
        let screens = ScreenManager()
        screens.target = .window
        presentation = PresentationController(
            store: store, playback: PlaybackController(settings: settings), screens: screens, images: ImageStore(),
            settings: settings
        )
        let a = temp.file("a.png")
        let clip = temp.file("klip.mov")
        let b = temp.file("b.png")
        try TestMedia.writePNG(to: a)
        try await TestMedia.writeVideo(to: clip)
        try TestMedia.writePNG(to: b)
        await store.importFiles([a, clip, b])
        presentation.slidesDidChange()
    }

    /// Olay tüketildiyse true döner.
    private func press(
        keyCode: UInt16 = 0, characters: String = "", modifiers: NSEvent.ModifierFlags = []
    ) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
        return KeyboardHandler.handle(event, presentation: presentation)
    }

    @Test func arrowsAndClickerKeysNavigate() throws {
        #expect(try press(keyCode: 124))  // →
        #expect(presentation.currentIndex == 1)
        #expect(try press(keyCode: 121))  // PageDown (kumanda)
        #expect(presentation.currentIndex == 2)
        #expect(try press(keyCode: 123))  // ←
        #expect(presentation.currentIndex == 1)
        #expect(try press(keyCode: 116))  // PageUp (kumanda)
        #expect(presentation.currentIndex == 0)
        #expect(try press(keyCode: 119))  // End
        #expect(presentation.currentIndex == 2)
        #expect(try press(keyCode: 115))  // Home
        #expect(presentation.currentIndex == 0)
    }

    @Test func spaceAdvancesOnImageAndTogglesVideo() async throws {
        #expect(try press(keyCode: 49))
        #expect(presentation.currentSlide?.title == "klip")

        #expect(try press(keyCode: 49))
        #expect(presentation.currentSlide?.title == "klip")
        #expect(await waitUntil { presentation.playback.isPlaying })

        #expect(try press(keyCode: 49))
        #expect(await waitUntil { !presentation.playback.isPlaying })
    }

    @Test func volumeAndMuteKeys() throws {
        let playback = presentation.playback
        #expect(try press(characters: "-"))
        #expect(abs(playback.volume - 0.9) < 0.001)
        #expect(try press(characters: "+"))
        #expect(playback.volume == 1)
        #expect(try press(characters: "m"))
        #expect(playback.isMuted)
        #expect(try press(characters: "M"))
        #expect(!playback.isMuted)
    }

    @Test func escapeAndBlackoutOnlyWhilePresenting() throws {
        #expect(try !press(keyCode: 53))
        #expect(try !press(characters: "b"))

        presentation.start()
        #expect(try press(characters: "b"))
        #expect(presentation.isBlackedOut)
        #expect(try press(keyCode: 53))
        #expect(!presentation.isPresenting)
    }

    @Test func shortcutsWithModifiersAndOtherKeysPassThrough() throws {
        #expect(try !press(keyCode: 124, modifiers: .command))
        #expect(try !press(characters: "s", modifiers: .command))
        #expect(try !press(characters: "x"))
        #expect(presentation.currentIndex == 0)
    }

    @Test func shiftArrowsAreLeftToTheListForExtendingSelection() throws {
        #expect(try !press(keyCode: 125, modifiers: .shift))
        #expect(try !press(keyCode: 124, modifiers: .shift))
        #expect(presentation.currentIndex == 0)
    }

    @Test func droppedFileProviderYieldsItsURL() async throws {
        let file = temp.file("a.png")
        let provider = NSItemProvider(object: file as NSURL)
        #expect(await provider.fileURL()?.standardizedFileURL == file.standardizedFileURL)
    }

    @Test func spaceStillAdvancesOnImageWithBackgroundMusic() async throws {
        let music = temp.file("fon.wav")
        try TestMedia.writeAudio(to: music, seconds: 2)
        try await presentation.store.setBackgroundAudio(from: music, for: [presentation.store.slides[0].id])
        presentation.backgroundAudioDidChange()
        #expect(presentation.playback.hasMedia)

        #expect(try press(keyCode: 49))
        #expect(presentation.currentIndex == 1)
    }
}
