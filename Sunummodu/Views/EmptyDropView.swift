import SwiftUI

/// Sunum boşken ortada görünen bırakma alanı.
struct EmptyDropView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("Resim ve videoları buraya sürükle")
                .font(.title2.weight(.semibold))
            Text("Her dosya bir slayt olur. Sıralamayı soldaki listede sürükleyerek değiştirebilirsin.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Dosya Seç…") {
                app.addMedia()
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(24)
        }
    }
}
