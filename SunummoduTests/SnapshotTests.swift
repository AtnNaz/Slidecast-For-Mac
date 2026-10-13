import AppKit
import SwiftUI
import Testing
@testable import Sunummodu

/// Arayüzü gözle kontrol etmek için pencereleri PNG olarak kaydeder. Normal test koşusunda atlanır;
/// çalıştırmak için:
///
///     TEST_RUNNER_SUNUM_SNAPSHOT_DIR=/çıktı/klasörü TEST_RUNNER_SUNUM_SAMPLE_DIR=/resim-ve-video/klasörü \
///       xcodebuild test -project Sunummodu.xcodeproj -scheme Sunummodu -only-testing:SunummoduTests/SnapshotTests
///
/// Video görüntüsü (AVPlayerLayer) bu yöntemle yakalanamaz; videonun altındaki poster kare görünür.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUNUM_SNAPSHOT_DIR"] != nil))
struct SnapshotTests {
    private let outputDirectory: URL
    private let sampleDirectory: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        outputDirectory = URL(fileURLWithPath: try #require(environment["SUNUM_SNAPSHOT_DIR"]), isDirectory: true)
        sampleDirectory = URL(fileURLWithPath: try #require(environment["SUNUM_SAMPLE_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    @Test func captureWindowStates() async throws {
        let app = AppModel()
        app.screens.target = .window
        // Örnek video ve müzik sesli olabilir; test sessiz koşsun.
        app.playback.setVolume(0)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 820),
            // SwiftUI'nin kendi pencereleri gibi; aksi halde araç çubuğunun altında bulanık bir bant oluşuyor.
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hostingView = NSHostingView(rootView: ContentView().environment(app).preferredColorScheme(.dark))
        hostingView.sceneBridgingOptions = .all
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer {
            app.shutdown()
            window.close()
        }

        try await capture(window, as: "1-bos")

        // Örnek klasör: 2 resim, video, dikey resim, 2 sayfalı PDF, ses.
        await app.store.importFiles([sampleDirectory])
        let ids = app.store.slides.map(\.id)
        let videoIndex = try #require(app.store.slides.firstIndex { $0.kind == .video })
        let audioIndex = try #require(app.store.slides.firstIndex { $0.kind == .audio })
        try await capture(window, as: "2-ilk-slayt")

        // Çoklu seçim, sığdır / doldur ve ses slaytına görsel.
        app.setFill(true, for: [ids[1], ids[3]])
        app.presentation.select([ids[1]])
        app.presentation.select([ids[1], ids[2], ids[3]])
        try await capture(window, as: "3-coklu-secim-ve-doldur")
        try await MediaImporter.setArtwork(
            from: app.store.package.mediaURL(for: app.store.slides[0]), for: app.store.slides[audioIndex],
            in: app.store.package
        )
        app.images.removeAll()
        app.store.setNotes("Videodan önce konuyu tanıt.\nBitince soru al.", for: ids[videoIndex])

        // Arka plan müziği: ilk iki resim aynı müziği, PDF sayfaları başka bir müziği paylaşır.
        let music = app.store.package.mediaURL(for: app.store.slides[audioIndex])
        try await app.store.setBackgroundAudio(from: music, for: [ids[0], ids[1]])
        try await app.store.setBackgroundAudio(from: music, for: Set(ids[4...5]))
        app.presentation.select([ids[0]])
        try await capture(window, as: "3-arka-plan-muzigi")

        // Tekrar ve otomatik ilerleme etiketleri; sunum adımları elle ilerlediği için sonra kapatılır.
        app.store.setLoops(true)
        app.store.setAutoAdvance(seconds: 5)
        try await capture(window, as: "3-tekrar-ve-otomatik")
        app.store.setLoops(false)
        app.store.setAutoAdvance(seconds: 0)

        // Sunum: geçişin ortası yakalanabilsin diye uzun bir geçiş süresi.
        app.presentation.transitionDuration = 2
        app.presentation.goToFirst()
        app.presentation.start()
        try await capture(window, as: "4-sunum-resim")
        // Paralel koşan başka testlerin de çıkış penceresi olabilir; bu sunuma ait olanı bul.
        let outputWindow = try #require(NSApp.windows.first { candidate in
            (candidate.contentView as? NSHostingView<OutputView>)?.rootView.presentation === app.presentation
        })
        let before = try await capture(outputWindow, as: "4-cikis-resim")

        // Resimden resme yumuşak geçiş: ortasında renkler iki slaytın arasında olmalı, kararmamalı.
        app.presentation.next()
        let middle = try await capture(outputWindow, as: "5-gecis-ortasi", after: .milliseconds(1000))
        let after = try await capture(outputWindow, as: "5-gecis-sonu", after: .milliseconds(1800))
        if let from = backgroundColor(of: before), let mid = backgroundColor(of: middle), let to = backgroundColor(of: after) {
            for channel in 0..<3 {
                #expect(mid[channel] > min(from[channel], to[channel]) - 0.03)
                #expect(mid[channel] < max(from[channel], to[channel]) + 0.03)
            }
            #expect(abs(mid[2] - from[2]) > 0.02 || abs(mid[0] - from[0]) > 0.02)
            #expect(abs(mid[2] - to[2]) > 0.02 || abs(mid[0] - to[0]) > 0.02)
        }

        app.presentation.go(toIndex: videoIndex)
        #expect(await waitUntil { app.playback.isPlaying && app.playback.currentTime > 2.5 })
        // Geçiş bittikten sonra aynı oynatıcı hem önizlemede hem çıkışta görüntü veriyor olmalı.
        let playerViews = [window, outputWindow].flatMap { playerViews(in: $0.contentView) }
        #expect(playerViews.count == 2)
        #expect(await waitUntil { playerViews.allSatisfy { $0.playerLayer.isReadyForDisplay && $0.playerLayer.opacity == 1 } })
        try await capture(window, as: "6-sunum-video", after: .milliseconds(100))

        // Videodan resme geçişin ortası: giden video hâlâ görünüyor olmalı.
        app.presentation.next()
        try await capture(outputWindow, as: "7-gecis-ortasi-videodan", after: .milliseconds(1000))
        try await capture(window, as: "7-gecis-sonu-doldur", after: .milliseconds(1500))

        app.presentation.toggleBlackout()
        try await capture(outputWindow, as: "8-cikis-karartma", after: .milliseconds(2300))
        try await capture(window, as: "8-karartma", after: .milliseconds(100))
        app.presentation.toggleBlackout()

        app.presentation.transitionDuration = 0
        app.presentation.go(toIndex: audioIndex)
        #expect(await waitUntil { app.playback.isPlaying })
        try await capture(window, as: "9-ses-slayti")
        try await capture(outputWindow, as: "9-cikis-ses-slayti", after: .milliseconds(100))

        app.renamingID = ids[0]
        try await capture(window, as: "10-yeniden-adlandir")
        app.renamingID = nil

        window.setContentSize(NSSize(width: 1120, height: 640))
        try await capture(window, as: "11-dar-pencere")
    }

    @discardableResult
    private func capture(_ window: NSWindow, as name: String, after delay: Duration = .milliseconds(700)) async throws -> CGImage? {
        try await Task.sleep(for: delay)
        let composited = compositedImage(of: window)
        let bitmap: NSBitmapImageRep
        if let composited {
            bitmap = NSBitmapImageRep(cgImage: composited)
        } else {
            let view = try #require(window.contentView?.superview ?? window.contentView)
            view.layoutSubtreeIfNeeded()
            bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
        return composited
    }

    /// Slayt zemininden (ortadaki yazının üstünden) bir pikselin kırmızı, yeşil, mavi değerleri (0–1).
    private func backgroundColor(of image: CGImage?) -> [Double]? {
        guard let image else { return nil }
        let color = NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 4)?
            .usingColorSpace(.sRGB)
        return color.map { [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)] }
    }

    /// Pencerenin ekrandaki gerçek görüntüsü (video ve saydam yüzeyler dahil). Swift'e kapalı olan
    /// `CGWindowListCreateImage` dinamik olarak çağrılır; uygulamanın kendi pencereleri için ekran kaydı
    /// izni gerekmez. Kullanılamıyorsa nil döner ve `cacheDisplay` ile yetinilir.
    private func compositedImage(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(defaultHandle, "CGWindowListCreateImage") else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let ignoreFramingAtBestResolution: UInt32 = (1 << 0) | (1 << 3)
        let image = createImage(.null, includingWindow, UInt32(window.windowNumber), ignoreFramingAtBestResolution)?
            .takeRetainedValue()
        guard let image, image.width > 1, image.height > 1 else { return nil }
        return image
    }

    private func playerViews(in view: NSView?) -> [PlayerNSView] {
        guard let view else { return [] }
        return ((view as? PlayerNSView).map { [$0] } ?? []) + view.subviews.flatMap { playerViews(in: $0) }
    }
}
