import AppKit

/// Sunum kısayollarını (ok tuşları, boşluk, kumanda tuşları) uygulama genelinde yakalar.
final class KeyboardHandler {
    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let home: UInt16 = 115
        static let pageUp: UInt16 = 116
        static let end: UInt16 = 119
        static let pageDown: UInt16 = 121
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    private var monitor: Any?

    func install(for presentation: PresentationController) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak presentation] event in
            guard let presentation, Self.handle(event, presentation: presentation) else { return event }
            return nil
        }
    }

    /// Olay tüketildiyse true döner.
    static func handle(_ event: NSEvent, presentation: PresentationController) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        // Aç/kaydet panelleri ve uyarılar kendi tuşlarını kullanır.
        if let window = event.window, window is NSPanel || window.attachedSheet != nil { return false }
        if event.window?.firstResponder is NSText {
            // Not yazarken yalnızca Esc yakalanır: odağı nottan çıkarır.
            guard event.keyCode == KeyCode.escape else { return false }
            event.window?.makeFirstResponder(nil)
            return true
        }

        let arrows = [KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.upArrow, KeyCode.downArrow]
        if event.modifierFlags.contains(.shift), arrows.contains(event.keyCode) {
            // ⇧ + ok listede seçimi genişletir.
            return false
        }

        let playback = presentation.playback
        switch event.keyCode {
        case KeyCode.rightArrow, KeyCode.downArrow, KeyCode.pageDown, KeyCode.returnKey, KeyCode.keypadEnter:
            presentation.next()
        case KeyCode.leftArrow, KeyCode.upArrow, KeyCode.pageUp:
            presentation.previous()
        case KeyCode.home:
            presentation.goToFirst()
        case KeyCode.end:
            presentation.goToLast()
        case KeyCode.space:
            if playback.hasMedia {
                playback.togglePlayPause()
            } else {
                presentation.next()
            }
        case KeyCode.escape:
            guard presentation.isPresenting else { return false }
            presentation.stop()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "+", "=":
                playback.adjustVolume(by: PlaybackController.volumeStep)
            case "-":
                playback.adjustVolume(by: -PlaybackController.volumeStep)
            case "m":
                playback.toggleMute()
            case "b", ".":
                guard presentation.isPresenting else { return false }
                presentation.toggleBlackout()
            default:
                return false
            }
        }
        return true
    }
}
