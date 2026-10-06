import AVFoundation
import SwiftUI

/// Oynatıcının görüntüsünü gösteren katman. Aynı `AVPlayer` birden çok görünümde gösterilebilir.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    /// true ise video ekranı doldurur (kenarlar kırpılır), değilse tamamı sığdırılır.
    var fills = false

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView(player: player)
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        if view.playerLayer.videoGravity != gravity {
            view.playerLayer.videoGravity = gravity
        }
    }

    private var gravity: AVLayerVideoGravity {
        fills ? .resizeAspectFill : .resizeAspect
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    private var readyObservation: NSKeyValueObservation?

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        playerLayer.player = player
        // İlk kare hazır olana kadar görünmez; alttaki poster kare görünür kalır.
        playerLayer.opacity = 0
        layer?.addSublayer(playerLayer)
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateVisibility() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) kullanılmıyor")
    }

    override func layout() {
        super.layout()
        withoutAnimation {
            playerLayer.frame = bounds
        }
    }

    private func updateVisibility() {
        withoutAnimation {
            playerLayer.opacity = playerLayer.isReadyForDisplay ? 1 : 0
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
