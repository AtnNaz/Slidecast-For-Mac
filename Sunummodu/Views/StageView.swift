import AVFoundation
import SwiftUI

/// Bir slaytın tam kare görüntüsü. Çıkış penceresi ve sunucu önizlemesi aynı görünümü kullanır.
struct StageView: View {
    let slide: Slide?
    let package: DeckPackage
    let images: ImageStore
    let player: AVPlayer
    var isBlackedOut = false

    var body: some View {
        ZStack {
            Color.black
            if let slide, !isBlackedOut {
                // Videoda oynatıcı ilk kareyi hazırlayana kadar altta poster kare görünür; siyah parlama olmaz.
                StageImage(slide: slide, package: package, images: images)
                if slide.kind == .video {
                    PlayerLayerView(player: player)
                        .id(slide.id)
                }
            }
        }
    }
}

private struct StageImage: View {
    let slide: Slide
    let package: DeckPackage
    let images: ImageStore
    @State private var loaded: (url: URL, image: NSImage)?

    var body: some View {
        let url = package.stageImageURL(for: slide)
        // Tam boy görüntü çözülene kadar küçük resim gösterilir.
        let image = images.cachedStageImage(at: url)
            ?? (loaded?.url == url ? loaded?.image : nil)
            ?? images.thumbnail(for: slide, in: package)
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            if let image = await images.stageImage(at: url) {
                loaded = (url, image)
            }
        }
    }
}

/// Çıkış penceresinin içeriği: izleyicinin gördüğü tek şey.
struct OutputView: View {
    let presentation: PresentationController

    var body: some View {
        StageView(
            slide: presentation.currentSlide,
            package: presentation.store.package,
            images: presentation.images,
            player: presentation.playback.player,
            isBlackedOut: presentation.isBlackedOut
        )
        .ignoresSafeArea()
    }
}
