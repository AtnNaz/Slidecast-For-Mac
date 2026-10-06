import SwiftUI

@main
struct SunummoduApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Sunum Modu", id: "main") {
            ContentView()
                .environment(appDelegate.app)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1120, minHeight: 620)
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            AppCommands(app: appDelegate.app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Finder'da çift tıklanan `.sunum` dosyaları ve Dock simgesine bırakılan resim / videolar buraya gelir.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let deck = urls.first(where: { $0.pathExtension == DeckPackage.fileExtension }) {
            app.requestOpen(deck)
        } else {
            app.importFiles(urls)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.shutdown()
    }
}

struct AppCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Yeni Sunum") { app.requestNew() }
                .keyboardShortcut("n")
            Button("Aç…") { app.requestOpen() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Kaydet") { app.save() }
                .keyboardShortcut("s")
            Button("Farklı Kaydet…") { app.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Dosya Ekle…") { app.addMedia() }
                .keyboardShortcut("i")
        }
        CommandMenu("Slayt") {
            Button("Çoğalt") { app.duplicateSelection() }
                .keyboardShortcut("d")
            Button("Yeniden Adlandır…") { app.beginRenamingSelection() }
            Button("Sığdır / Ekranı Doldur") { app.toggleFillForSelection() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Sil") { app.deleteSelection() }
        }
        CommandMenu("Sunum") {
            Button("Sunumu Başlat / Bitir") { app.presentation.togglePresenting() }
                .keyboardShortcut(.return, modifiers: .command)
            Divider()
            // Tek tuşlu kısayollar (→ ← boşluk + − M B) KeyboardHandler'da; menüye bağlanırsa not yazmayı bozar.
            Button("Sonraki Slayt  (→)") { app.presentation.next() }
            Button("Önceki Slayt  (←)") { app.presentation.previous() }
            Divider()
            Button("Başlat / Durdur  (Boşluk)") { app.playback.togglePlayPause() }
            Button("Sesi Yükselt  (+)") { app.playback.adjustVolume(by: PlaybackController.volumeStep) }
            Button("Sesi Alçalt  (−)") { app.playback.adjustVolume(by: -PlaybackController.volumeStep) }
            Button("Sesi Kapat / Aç  (M)") { app.playback.toggleMute() }
            Divider()
            Button("Ekranı Karart  (B)") { app.presentation.toggleBlackout() }
        }
    }
}
