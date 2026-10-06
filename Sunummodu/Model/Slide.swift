import Foundation

nonisolated enum MediaKind: String, Codable, Sendable {
    case image
    case video
    case audio
}

/// Görüntünün ekrana nasıl yerleştirileceği.
nonisolated enum SlideScaling: String, Codable, Sendable {
    /// Tamamı görünür; boş kalan yerler siyah.
    case fit
    /// Ekranı doldurur; taşan kenarlar kırpılır.
    case fill
}

nonisolated struct Slide: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: MediaKind
    /// Paketin `Media/` klasöründeki dosya adı.
    var fileName: String
    var title: String
    var notes: String
    /// Saniye; yalnızca video ve seste dolu.
    var duration: Double?
    var scaling: SlideScaling

    init(
        id: UUID = UUID(),
        kind: MediaKind,
        fileName: String,
        title: String,
        notes: String = "",
        duration: Double? = nil,
        scaling: SlideScaling = .fit
    ) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.title = title
        self.notes = notes
        self.duration = duration
        self.scaling = scaling
    }

    /// Eski sürümlerin yazdığı sunumlarda sonradan eklenen alanlar bulunmaz.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(MediaKind.self, forKey: .kind)
        fileName = try container.decode(String.self, forKey: .fileName)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        scaling = try container.decodeIfPresent(SlideScaling.self, forKey: .scaling) ?? .fit
    }

    /// Oynatılan (video ya da ses) bir slayt mı?
    var isPlayable: Bool { kind != .image }
}
