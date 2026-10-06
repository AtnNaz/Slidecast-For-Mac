import AppKit
import SwiftUI

/// İzleyicinin gördüğü pencere: harici ekranda kenarlıksız tam ekran, ekran yoksa normal önizleme penceresi.
final class OutputWindowController: NSObject, NSWindowDelegate {
    /// Kullanıcı önizleme penceresini kendi kapattığında çağrılır.
    var onUserClose: (() -> Void)?

    private var window: NSWindow?
    private var isFullScreen = false

    /// `screen` nil ise pencere modunda açar. Zaten aynı hedefte açıksa pencereyi yeniden kurmaz.
    func show(on screen: NSScreen?, rootView: some View) {
        if let window {
            if let screen, isFullScreen {
                window.setFrame(screen.frame, display: true)
                return
            }
            if screen == nil, !isFullScreen {
                return
            }
            close()
        }

        let window: NSWindow
        if let screen {
            window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            // Menü çubuğunu ve Dock'u da örter.
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.hasShadow = false
            window.setFrame(screen.frame, display: true)
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Çıkış Önizlemesi"
            window.contentAspectRatio = NSSize(width: 16, height: 9)
            window.center()
            window.delegate = self
        }
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black

        let hostingView = NSHostingView(rootView: rootView)
        // Pencere boyutunu içerik değil biz belirleriz.
        hostingView.sizingOptions = []
        window.contentView = hostingView

        // Klavye odağı sunucu penceresinde kalsın diye key yapılmaz.
        window.orderFrontRegardless()
        self.window = window
        isFullScreen = screen != nil
    }

    func close() {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        window.contentView = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        onUserClose?()
    }
}
