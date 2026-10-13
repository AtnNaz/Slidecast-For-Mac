import SwiftUI
import UniformTypeIdentifiers

/// Slayt listesi: tıklayınca o slayta geçer, sürükleyerek sıralanır, Finder'dan dosya bırakılabilir.
/// ⌘ / ⇧ ile birden çok slayt seçilip birlikte taşınabilir, çoğaltılabilir ya da silinebilir.
struct SlideSidebar: View {
    @Environment(AppModel.self) private var app
    @State private var renameText = ""

    var body: some View {
        let store = app.store
        let presentation = app.presentation
        ScrollViewReader { proxy in
            list(store: store, presentation: presentation)
                // Klavyeyle ilerlerken gösterilen slayt listede görünür kalsın.
                .onChange(of: presentation.currentID) { _, id in
                    if let id {
                        proxy.scrollTo(id)
                    }
                }
        }
    }

    private func list(store: DeckStore, presentation: PresentationController) -> some View {
        List(selection: selection) {
            ForEach(Array(store.slides.enumerated()), id: \.element.id) { index, slide in
                SlideRow(
                    number: index + 1,
                    slide: slide,
                    isCurrent: slide.id == presentation.currentID,
                    isLive: presentation.isPresenting && slide.id == presentation.currentID
                )
                .tag(slide.id)
            }
            .onMove { source, destination in
                store.move(fromOffsets: source, toOffset: destination)
            }
            .onInsert(of: [.fileURL]) { index, providers in
                app.importDropped(providers, at: index)
            }
        }
        // Menü, tıklanan satır seçimin içindeyse bütün seçime, değilse yalnızca o satıra uygulanır.
        .contextMenu(forSelectionType: Slide.ID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if ids.count == 1 {
                app.renamingID = ids.first
            }
        }
        .onDeleteCommand {
            // Sunum sırasında yanlışlıkla basılan Sil tuşu slaytı götürmesin.
            if !presentation.isPresenting {
                app.deleteSelection()
            }
        }
        .alert("Slaytı Yeniden Adlandır", isPresented: isRenaming) {
            TextField("Slayt adı", text: $renameText)
            Button("Vazgeç", role: .cancel) {}
            Button("Tamam") {
                let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = app.renamingID, !title.isEmpty {
                    store.setTitle(title, for: id)
                }
            }
        }
        .onChange(of: app.renamingID) { _, id in
            if let slide = store.slides.first(where: { $0.id == id }) {
                renameText = slide.title
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

    private var selection: Binding<Set<Slide.ID>> {
        Binding(
            get: { app.presentation.selection },
            set: { app.presentation.select($0) }
        )
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { app.renamingID != nil },
            set: { if !$0 { app.renamingID = nil } }
        )
    }

    @ViewBuilder
    private func menu(for ids: Set<Slide.ID>) -> some View {
        if ids.isEmpty {
            Button("Dosya Ekle…") { app.addMedia() }
        } else {
            if ids.count == 1 {
                Button("Yeniden Adlandır…") { app.renamingID = ids.first }
            }
            Button("Çoğalt") {
                Task { await app.store.duplicate(ids) }
            }
            Toggle("Ekranı Doldur", isOn: Binding(
                get: { app.isFilled(ids) },
                set: { app.setFill($0, for: ids) }
            ))
            if app.containsImage(ids) {
                Divider()
                Button("Arka Plan Müziği Seç…") { app.chooseBackgroundAudio(for: ids) }
                if app.hasBackgroundAudio(ids) {
                    Button("Arka Plan Müziğini Kaldır") { app.store.removeBackgroundAudio(for: ids) }
                }
            }
            if ids.count == 1, let slide = app.store.slides.first(where: { ids.contains($0.id) }), slide.kind == .audio {
                Divider()
                Button("Görsel Seç…") { app.chooseArtwork(for: slide.id) }
                Button("Görseli Kaldır") { app.removeArtwork(for: slide.id) }
            }
            Divider()
            Button(ids.count > 1 ? "\(ids.count) Slaytı Sil" : "Slaytı Sil", role: .destructive) {
                app.presentation.delete(ids)
            }
        }
    }
}

private struct SlideRow: View {
    let number: Int
    let slide: Slide
    /// Sahnede gösterilen slayt; çoklu seçimde hangisinin gösterildiği belli olsun diye işaretlenir.
    let isCurrent: Bool
    let isLive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                SlideThumbnail(slide: slide)
                    .overlay(alignment: .bottomLeading) {
                        if slide.isPlayable {
                            MediaBadge(systemImage: slide.kind == .audio ? "music.note" : "play.fill", duration: slide.duration)
                                .padding(4)
                        } else if let audio = slide.backgroundAudio {
                            MediaBadge(systemImage: "music.note", duration: nil)
                                .padding(4)
                                .padding(.leading, 4)
                                .help("Arka plan müziği: \(audio.title)")
                        }
                    }
                    // Aynı müziği paylaşan slaytlar aynı renkte şeritle işaretlenir.
                    .overlay(alignment: .leading) {
                        if let audio = slide.backgroundAudio {
                            Rectangle()
                                .fill(Color.musicGroup(for: audio.fileName))
                                .frame(width: 5)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if slide.scaling == .fill {
                            MediaBadge(systemImage: "arrow.up.left.and.arrow.down.right", duration: nil)
                                .padding(4)
                                .help("Ekranı dolduruyor")
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(borderColor, lineWidth: isCurrent ? 2 : 1)
                    }
                Text(slide.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
    }

    private var borderColor: Color {
        if isLive { return .live }
        return .white.opacity(isCurrent ? 0.85 : 0.15)
    }
}

private struct MediaBadge: View {
    let systemImage: String
    let duration: Double?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
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
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image = app.images.thumbnail(for: slide, in: app.store.package) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: slide.scaling == .fill ? .fill : .fit)
                } else {
                    Image(systemName: placeholderSymbol)
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
    }

    private var placeholderSymbol: String {
        switch slide.kind {
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        }
    }
}
