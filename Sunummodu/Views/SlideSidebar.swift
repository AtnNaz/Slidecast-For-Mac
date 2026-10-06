import SwiftUI
import UniformTypeIdentifiers

/// Slayt listesi: tıklayınca o slayta geçer, sürükleyerek sıralanır, Finder'dan dosya bırakılabilir.
struct SlideSidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let store = app.store
        let presentation = app.presentation
        List(selection: selection) {
            ForEach(Array(store.slides.enumerated()), id: \.element.id) { index, slide in
                SlideRow(
                    number: index + 1,
                    slide: slide,
                    isLive: presentation.isPresenting && slide.id == presentation.currentID
                )
                .tag(slide.id)
                .contextMenu {
                    Button("Slaytı Sil…", role: .destructive) {
                        app.requestDelete(slide.id)
                    }
                }
            }
            .onMove { source, destination in
                store.move(fromOffsets: source, toOffset: destination)
            }
            .onInsert(of: [.fileURL]) { index, providers in
                app.importDropped(providers, at: index)
            }
        }
        .onDeleteCommand {
            // Sunum sırasında yanlışlıkla basılan Sil tuşu slaytı götürmesin.
            if !presentation.isPresenting, let id = presentation.currentID {
                app.requestDelete(id)
            }
        }
        .overlay {
            if store.slides.isEmpty, !store.isImporting {
                Text("Henüz slayt yok")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if store.isImporting {
                ImportProgress(done: store.importDone, total: store.importTotal)
            }
        }
    }

    private var selection: Binding<Slide.ID?> {
        Binding(
            get: { app.presentation.currentID },
            // Boş alana tıklamak seçimi kaldırmasın; sunum sırasında ekran boş kalırdı.
            set: { if let id = $0 { app.presentation.go(to: id) } }
        )
    }
}

private struct SlideRow: View {
    let number: Int
    let slide: Slide
    let isLive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                SlideThumbnail(slide: slide)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(alignment: .bottomLeading) {
                        if slide.kind == .video {
                            VideoBadge(duration: slide.duration)
                                .padding(4)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isLive ? Color.live : Color.white.opacity(0.15), lineWidth: isLive ? 2 : 1)
                    }
                Text(slide.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct VideoBadge: View {
    let duration: Double?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
            if let duration {
                Text(Timecode.string(duration))
                    .monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct ImportProgress: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ekleniyor… \(min(done + 1, total)) / \(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(done), total: Double(max(total, 1)))
        }
        .padding(10)
        .background(.bar)
    }
}

/// Slaytın 16:9 küçük resmi; liste satırlarında ve "sonraki slayt" panelinde kullanılır.
struct SlideThumbnail: View {
    let slide: Slide
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Color.black
            if let image = app.images.thumbnail(for: slide, in: app.store.package) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: slide.kind == .video ? "film" : "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }
}
