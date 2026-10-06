import Foundation

nonisolated struct Deck: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Deck.currentVersion
    var slides: [Slide] = []
}
