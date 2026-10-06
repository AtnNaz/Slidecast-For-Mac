import AVFoundation
import SwiftUI

/// Bir slaytın tam kare görüntüsü. Çıkış penceresi ve sunucu önizlemesi aynı görünümü kullanır.
struct StageView: View {
    let slide: Slide?
    let package: DeckPackage
    let images: ImageStore
    let player: AVPlayer
    var isBlackedOut = false
    /// Her slayt değişiminde artan sayaç; geçiş bu değer değişince canlanır.
    var generation = 0
    /// Yumuşak geçişin süresi (saniye); 0 ise slaytlar kesmeyle değişir.
    var transitionDuration: Double = 0

    var body: some View {
        let animation: Animation? = transitionDuration > 0 ? .easeInOut(duration: transitionDuration) : nil
        ZStack {
            Color.black
            // Her slayt değişiminde yeni bir katman eklenir ve eskisinin üzerinde belirir. Kimlik ForEach ile
            // verilir; `.id()` ile verilseydi geçiş uygulanmaz, iki katman birden solardı.
            ForEach(layers, id: \.generation) { layer in
                SlideLayer(slide: layer.slide, package: package, images: images, player: player)
                    .zIndex(Double(layer.generation))
                    .transition(CrossfadeTransition())
            }
            Color.black
                .opacity(isBlackedOut ? 1 : 0)
                .zIndex(.greatestFiniteMagnitude)
                .animation(animation, value: isBlackedOut)
        }
        .animation(animation, value: generation)
    }

    private var layers: [(generation: Int, slide: Slide)] {
        slide.map { [(generation, $0)] } ?? []
    }
}

/// Yeni slayt eskisinin üzerinde belirir; eski slayt geçiş bitene kadar altta tam görünür kalır.
/// (İkisi birden solsaydı geçişin ortasında görüntü kararırdı.)
private struct CrossfadeTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        // Tek bir ifade olmalı: evreler ayrı dallarda olursa SwiftUI aralarını canlandırmak yerine
        // görünümü değiştirir ve giden katman da solar.
        content.opacity(opacity(in: phase))
    }

    private func opacity(in phase: TransitionPhase) -> Double {
        switch phase {
        case .willAppear: 0
        case .identity: 1
        // Gözle fark edilmeyen bir değişim; katmanın geçiş süresince yerinde kalmasını sağlar.
        case .didDisappear: 0.999
        }
    }
}

/// Tek bir slaytın katmanı. Kendi siyah zemini vardır; böylece geçişte alttaki slayt kenar boşluklarından görünmez.
private struct SlideLayer: View {
    let slide: Slide
    let package: DeckPackage
    let images: ImageStore
    let player: AVPlayer

    var body: some View {
        ZStack {
            Color.black
            // Videoda oynatıcı ilk kareyi hazırlayana kadar altta poster kare görünür; siyah parlama olmaz.
            // Ses slaytında yalnızca (varsa) seçilen görsel durur.
            StageImage(slide: slide, package: package, images: images)
            if slide.kind == .video {
                PlayerLayerView(player: player, fills: slide.scaling == .fill)
            }
        }
        // Katman tek parça olarak solmalı; yoksa kendi siyah zemini de ayrıca saydamlaşır ve
        // geçişin ortasında alttaki slayt kararır.
        .compositingGroup()
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
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: slide.scaling == .fill ? .fill : .fit)
                }
            }
            .clipped()
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
            isBlackedOut: presentation.isBlackedOut,
            generation: presentation.transitionGeneration,
            transitionDuration: presentation.activeTransitionDuration
        )
        .ignoresSafeArea()
    }
}
