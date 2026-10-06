import Foundation

nonisolated enum MediaKind: String, Codable, Sendable {
    case image
    case video
}

nonisolated struct Slide: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: MediaKind
    /// Paketin `Media/` klasöründeki dosya adı.
    var fileName: String
    var title: String
    var notes: String
    /// Saniye; yalnızca videolarda dolu.
    var duration: Double?

    init(
        id: UUID = UUID(),
        kind: MediaKind,
        fileName: String,
        title: String,
        notes: String = "",
        duration: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.title = title
        self.notes = notes
        self.duration = duration
    }
}
