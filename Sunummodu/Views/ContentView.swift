import SwiftUI
import UniformTypeIdentifiers

/// Ana pencere: solda slayt listesi, ortada gösterilen slayt ve kontroller, sağda sunucu paneli.
struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            SlideSidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        } detail: {
            HStack(spacing: 0) {
                CurrentSlidePane()
                Divider()
                SidePanel()
                    .frame(width: 290)
            }
        }
        .navigationTitle(app.store.displayName)
        .navigationSubtitle(app.store.slides.isEmpty ? "" : "\(app.store.slides.count) slayt")
        .toolbar {
            MainToolbar(app: app)
        }
        // Pencerenin herhangi bir yerine bırakılan dosyalar sona eklenir; liste kendi bırakma konumunu kullanır.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            app.importDropped(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: app.store.slides.count) {
            app.presentation.ensureSelection()
        }
        .alert("Bazı dosyalar eklenemedi", isPresented: skippedAlertBinding) {
            Button("Tamam") {}
        } message: {
            Text(skippedMessage)
        }
        .alert("Hata", isPresented: errorAlertBinding) {
            Button("Tamam") {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    private var skippedAlertBinding: Binding<Bool> {
        Binding(
            get: { !app.store.skippedFiles.isEmpty && !app.store.isImporting },
            set: { if !$0 { app.store.skippedFiles = [] } }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )
    }

    private var skippedMessage: String {
        let names = app.store.skippedFiles
        let listed = names.prefix(8).joined(separator: "\n")
        let more = names.count > 8 ? "\n… ve \(names.count - 8) dosya daha" : ""
        return "Bu dosyalar desteklenen bir resim ya da video biçiminde değil:\n\(listed)\(more)"
    }
}

/// Ortadaki bölüm: izleyicinin gördüğü slaytın canlı önizlemesi ve kontroller.
private struct CurrentSlidePane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.store.slides.isEmpty {
                EmptyDropView()
            } else {
                VStack(spacing: 0) {
                    header
                    stage
                    TransportBar()
                }
            }
        }
        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        let presentation = app.presentation
        return HStack(spacing: 10) {
            Text("ŞU ANKİ SLAYT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let slide = presentation.currentSlide, let index = presentation.currentIndex {
                Text("\(index + 1) / \(app.store.slides.count)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                Text(slide.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            LiveBadge(isPresenting: presentation.isPresenting, screenName: presentation.outputScreenName)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var stage: some View {
        let presentation = app.presentation
        let shape = RoundedRectangle(cornerRadius: 10)
        return StageView(
            slide: presentation.currentSlide,
            package: app.store.package,
            images: app.images,
            player: app.playback.player
        )
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(shape)
        .overlay {
            if presentation.isBlackedOut {
                shape.fill(.black.opacity(0.85))
                Label("Ekran karartıldı — açmak için B", systemImage: "eye.slash.fill")
                    .font(.headline)
            }
        }
        .overlay {
            shape.strokeBorder(
                presentation.isPresenting ? Color.live : Color.white.opacity(0.15),
                lineWidth: presentation.isPresenting ? 2 : 1
            )
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
    }
}

private struct LiveBadge: View {
    let isPresenting: Bool
    let screenName: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isPresenting ? Color.live : Color.secondary)
                .frame(width: 8, height: 8)
            Text(isPresenting ? "YAYINDA · \(screenName ?? "Pencere")" : "Sunum başlamadı")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isPresenting ? Color.live.opacity(0.22) : Color.white.opacity(0.08), in: Capsule())
    }
}

private struct SidePanel: View {
    var body: some View {
        VStack(spacing: 0) {
            ClockTimerView()
                .padding(16)
            Divider()
            NextSlidePanel()
                .padding(16)
            Divider()
            NotesEditor()
        }
        .background(Color.black.opacity(0.18))
    }
}

struct MainToolbar: ToolbarContent {
    let app: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                app.addMedia()
            } label: {
                Label("Ekle", systemImage: "plus")
            }
            .help("Resim veya video ekle (⌘I)")
        }
        ToolbarItem(placement: .primaryAction) {
            OutputMenu(screens: app.screens)
        }
        ToolbarItem(placement: .primaryAction) {
            BlackoutButton(presentation: app.presentation)
        }
        ToolbarItem(placement: .primaryAction) {
            PresentButton(app: app)
        }
    }
}

private struct OutputMenu: View {
    @Bindable var screens: ScreenManager

    var body: some View {
        Menu {
            Picker("Çıkış ekranı", selection: $screens.target) {
                Text("Otomatik (harici ekran)").tag(OutputTarget.automatic)
                ForEach(screens.displays) { display in
                    Text(display.isBuiltin ? "\(display.name) (dahili)" : display.name)
                        .tag(OutputTarget.display(display.id))
                }
                Text("Pencere (önizleme)").tag(OutputTarget.window)
            }
            .pickerStyle(.inline)
            if screens.isMirroring {
                Divider()
                Text("Ekran yansıtma açık. Ayrı çıkış için Sistem Ayarları › Ekranlar'dan “Genişletilmiş ekran”ı seç.")
            }
        } label: {
            Label("Çıkış", systemImage: "display.2")
        }
        .help("Sunumun yansıtılacağı ekran")
    }
}

private struct BlackoutButton: View {
    let presentation: PresentationController

    var body: some View {
        Button {
            presentation.toggleBlackout()
        } label: {
            Label("Karart", systemImage: presentation.isBlackedOut ? "eye.slash.fill" : "eye.slash")
        }
        .disabled(!presentation.isPresenting)
        .help("Yansıtılan ekranı karart / aç (B)")
    }
}

private struct PresentButton: View {
    let app: AppModel

    var body: some View {
        let isPresenting = app.presentation.isPresenting
        Button {
            app.presentation.togglePresenting()
        } label: {
            Label(
                isPresenting ? "Sunumu Bitir" : "Sunumu Başlat",
                systemImage: isPresenting ? "stop.fill" : "play.fill"
            )
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .tint(isPresenting ? .red : .accentColor)
        .disabled(app.store.slides.isEmpty)
        .help(isPresenting ? "Sunumu bitir (Esc)" : "Sunumu başlat (⌘↩)")
    }
}
