import SwiftUI

/// Önceki / sonraki, başlat / durdur, video ilerleme çubuğu ve ses kontrolleri.
struct TransportBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let presentation = app.presentation
        let playback = app.playback
        VStack(spacing: 14) {
            ProgressRow(playback: playback)
            // Pencere daralınca ses kaydırıcısı gizlenir; düğmeler kalır.
            ViewThatFits(in: .horizontal) {
                controls(presentation: presentation, playback: playback, showsVolumeSlider: true)
                controls(presentation: presentation, playback: playback, showsVolumeSlider: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    private func controls(
        presentation: PresentationController, playback: PlaybackController, showsVolumeSlider: Bool
    ) -> some View {
        HStack(spacing: 16) {
            NavigationButtons(presentation: presentation, playback: playback)
            Spacer(minLength: 0)
            VolumeControl(playback: playback, showsSlider: showsVolumeSlider)
        }
    }
}

private struct ProgressRow: View {
    let playback: PlaybackController

    var body: some View {
        HStack(spacing: 10) {
            Text(Timecode.string(playback.currentTime))
                .frame(minWidth: 44, alignment: .trailing)
            Slider(
                value: Binding(get: { playback.currentTime }, set: { playback.scrub(to: $0) }),
                in: 0...max(playback.duration, 0.1)
            ) { isEditing in
                if isEditing {
                    playback.beginScrubbing()
                } else {
                    playback.endScrubbing()
                }
            }
            Text("-" + Timecode.string(max(playback.duration - playback.currentTime, 0)))
                .frame(minWidth: 44, alignment: .leading)
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .disabled(!playback.hasVideo)
        .opacity(playback.hasVideo ? 1 : 0.35)
        .help(playback.hasVideo ? "Videoda ileri / geri sar" : "Bu slaytta video yok")
    }
}

private struct NavigationButtons: View {
    let presentation: PresentationController
    let playback: PlaybackController

    var body: some View {
        HStack(spacing: 12) {
            Button {
                presentation.previous()
            } label: {
                Label("Önceki", systemImage: "chevron.left")
            }
            .disabled(!presentation.canGoPrevious)
            .help("Önceki slayt (←)")

            playPauseButton

            Button {
                presentation.next()
            } label: {
                Label("Sonraki", systemImage: "chevron.right")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .disabled(!presentation.canGoNext)
            .help("Sonraki slayt (→)")
        }
        .buttonStyle(.bordered)
        .controlSize(.extraLarge)
        .fixedSize()
    }

    /// Yalnızca video varken vurgulu; resim slaytında sönük ve devre dışı.
    @ViewBuilder private var playPauseButton: some View {
        let button = Button {
            playback.togglePlayPause()
        } label: {
            Label(playback.isPlaying ? "Durdur" : "Başlat", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                .frame(minWidth: 76)
        }
        if playback.hasVideo {
            button
                .buttonStyle(.borderedProminent)
                .help("Videoyu başlat / durdur (Boşluk)")
        } else {
            button
                .disabled(true)
                .help("Bu slaytta video yok")
        }
    }
}

private struct VolumeControl: View {
    let playback: PlaybackController
    let showsSlider: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                playback.toggleMute()
            } label: {
                Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .help("Sesi kapat / aç (M)")

            Button {
                playback.adjustVolume(by: -PlaybackController.volumeStep)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(playback.volume <= 0)
            .help("Sesi alçalt (−)")

            if showsSlider {
                Slider(
                    value: Binding(get: { playback.volume }, set: { playback.setVolume($0) }),
                    in: 0...1
                )
                .frame(width: 72)
            }

            Button {
                playback.adjustVolume(by: PlaybackController.volumeStep)
            } label: {
                Image(systemName: "plus")
            }
            .disabled(playback.volume >= 1)
            .help("Sesi yükselt (+)")

            Text("%\(Int((playback.volume * 100).rounded()))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(playback.isMuted ? .tertiary : .secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize()
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}
