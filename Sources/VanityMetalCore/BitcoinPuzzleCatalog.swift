import Foundation

public struct BitcoinPuzzle: Decodable, Identifiable, Sendable {
    public let number: Int
    public let address: String
    public let status: String
    public let minimumKeyHex: String
    public let maximumKeyHex: String

    public var id: Int { number }
}

public enum BitcoinPuzzleCatalog {
    public static let puzzles: [BitcoinPuzzle] = {
        guard let url = Bundle.module.url(forResource: "BitcoinPuzzleCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let puzzles = try? JSONDecoder().decode([BitcoinPuzzle].self, from: data) else {
            return []
        }
        return puzzles.sorted { $0.number < $1.number }
    }()
}
