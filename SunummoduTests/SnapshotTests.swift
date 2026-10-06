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

        await app.store.importFiles([sampleDirectory])
        try await capture(window, as: "2-ilk-slayt")

        let videoIndex = try #require(app.store.slides.firstIndex { $0.kind == .video })
        app.presentation.go(toIndex: videoIndex)
        try await capture(window, as: "3-video-secili")

        app.store.setNotes("Videodan önce konuyu tanıt.\nBitince soru al.", for: app.store.slides[videoIndex].id)
        app.presentation.goToFirst()
        app.presentation.start()
        try await capture(window, as: "4-sunum-resim")
        // Paralel koşan başka testlerin de çıkış penceresi olabilir; bu sunuma ait olanı bul.
        let outputWindow = try #require(NSApp.windows.first { candidate in
            (candidate.contentView as? NSHostingView<OutputView>)?.rootView.presentation === app.presentation
        })
        try await capture(outputWindow, as: "4-cikis-resim")

        app.presentation.go(toIndex: videoIndex)
        #expect(await waitUntil { app.playback.isPlaying && app.playback.currentTime > 0.5 })
        // Aynı oynatıcı hem önizlemede hem çıkışta görüntü veriyor olmalı.
        let playerViews = [window, outputWindow].flatMap { playerViews(in: $0.contentView) }
        #expect(playerViews.count == 2)
        #expect(await waitUntil { playerViews.allSatisfy { $0.playerLayer.isReadyForDisplay && $0.playerLayer.opacity == 1 } })
        try await capture(window, as: "5-sunum-video")
        try await capture(outputWindow, as: "5-cikis-video")

        app.presentation.toggleBlackout()
        try await capture(window, as: "6-karartma")
        try await capture(outputWindow, as: "6-cikis-karartma")
        app.presentation.toggleBlackout()

        app.presentation.goToLast()
        window.setContentSize(NSSize(width: 1120, height: 640))
        try await capture(window, as: "7-dar-pencere-son-slayt")
    }

    private func capture(_ window: NSWindow, as name: String) async throws {
        try await Task.sleep(for: .milliseconds(700))
        let bitmap: NSBitmapImageRep
        if let composited = compositedImage(of: window) {
            bitmap = NSBitmapImageRep(cgImage: composited)
        } else {
            let view = try #require(window.contentView?.superview ?? window.contentView)
            view.layoutSubtreeIfNeeded()
            bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
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
