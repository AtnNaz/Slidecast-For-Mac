import Foundation

/// Sunumun nasıl oynatılacağına dair, sunumla birlikte kaydedilen ayarlar.
nonisolated struct DeckSettings: Codable, Equatable, Sendable {
    /// Sunum sırasında son slayttan sonra ilk slayta dönülür.
    var loops = false
    /// Sunum sırasında resimlerin ekranda kalma süresi (saniye); 0 ise slaytlar yalnızca elle değişir.
    /// Açıkken video ve sesler bitince kendiliğinden sonraki slayta geçilir.
    var autoAdvanceSeconds: Double = 0
}

nonisolated struct Deck: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Deck.currentVersion
    var slides: [Slide] = []
    var settings = DeckSettings()

    init() {}

    /// Eski sürümlerin yazdığı sunumlarda ayarlar bulunmaz.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Deck.currentVersion
        slides = try container.decode([Slide].self, forKey: .slides)
        settings = try container.decodeIfPresent(DeckSettings.self, forKey: .settings) ?? DeckSettings()
    }
}
