import SwiftUI

/// Güncel saat ve sunumun başından beri geçen süre.
struct ClockTimerView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let presentation = app.presentation
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    PanelLabel("SAAT")
                    Text(context.date.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 22, weight: .medium).monospacedDigit())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    PanelLabel("SÜRE")
                    Text(Timecode.elapsed(presentation.startedAt.map { context.date.timeIntervalSince($0) } ?? 0))
                        .font(.system(size: 22, weight: .medium).monospacedDigit())
                        .foregroundStyle(presentation.isPresenting ? .primary : .tertiary)
                }
                Button {
                    presentation.resetTimer()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!presentation.isPresenting)
                .help("Süreyi sıfırla")
                .padding(.bottom, 4)
            }
        }
    }
}

struct NextSlidePanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelLabel("SONRAKİ")
            if let slide = app.presentation.nextSlide {
                SlideThumbnail(slide: slide)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.white.opacity(0.15))
                    }
                HStack(spacing: 5) {
                    Image(systemName: slide.kind == .video ? "film" : "photo")
                    Text(slide.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.black.opacity(0.35))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        Text(app.store.slides.isEmpty ? "Slayt yok" : "Sunumun sonu")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
    }
}

/// Gösterilen slaytın konuşmacı notu; yalnızca bu pencerede görünür.
struct NotesEditor: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let slideID = app.presentation.currentID
        VStack(alignment: .leading, spacing: 6) {
            PanelLabel("NOTLAR")
                .padding(.horizontal, 16)
                .padding(.top, 14)
            TextEditor(text: notes(for: slideID))
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 11)
                .padding(.bottom, 8)
                .disabled(app.presentation.currentSlide == nil)
                .overlay(alignment: .topLeading) {
                    if app.presentation.currentSlide?.notes.isEmpty ?? true {
                        Text("Bu slayt için not yaz. İzleyici görmez.")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .allowsHitTesting(false)
                    }
                }
                // Slayt değişince düzenleyicinin imleci ve geri alma geçmişi sıfırlansın.
                .id(slideID)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func notes(for slideID: Slide.ID?) -> Binding<String> {
        Binding(
            get: { app.store.slides.first { $0.id == slideID }?.notes ?? "" },
            set: { newValue in
                if let slideID {
                    app.store.setNotes(newValue, for: slideID)
                }
            }
        )
    }
}

private struct PanelLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
