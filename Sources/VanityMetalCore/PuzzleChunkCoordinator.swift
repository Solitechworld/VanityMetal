import Foundation
import Security

/// Randomly schedules fixed-size pieces of a puzzle's scalar interval and
/// persists completed chunks plus the current chunk cursor.
public final class PuzzleChunkCoordinator {
    private struct Snapshot: Codable {
        let puzzleID: Int
        let minimumHex: String
        let maximumHex: String
        let chunkSize: UInt64
        let completed: [String]
        let activeIndex: String?
        let activeOffset: String
    }

    private struct Cursor: Codable {
        let puzzleID: Int
        let minimumHex: String
        let maximumHex: String
        let chunkSize: UInt64
        let activeIndex: String?
        let activeOffset: String
    }

    public let puzzleID: Int
    public let minimum: U256
    public let maximum: U256
    public let chunkSize: UInt64
    public let totalChunks: U256

    private var completed = Set<U256>()
    private var activeIndex: U256?
    private var activeOffset = U256.zero
    private let progressURL: URL
    private let journalURL: URL
    private let cursorURL: URL
    private var lastCursorSave = Date.distantPast
    private let checkpointInterval: TimeInterval = 30

    public init(puzzleID: Int, minimum: U256, maximum: U256,
                chunkSize: UInt64) throws {
        guard puzzleID > 0, chunkSize > 0, minimum > .zero, minimum <= maximum,
              maximum < Fn.n else { throw PuzzleChunkError.invalidConfiguration }
        self.puzzleID = puzzleID
        self.minimum = minimum
        self.maximum = maximum
        self.chunkSize = chunkSize
        let width = U256.addSmall(U256.subb(maximum, minimum).0, 1)
        guard width.1 == 0 else { throw PuzzleChunkError.invalidConfiguration }
        let divided = divModSmall(width.0, chunkSize)
        let chunks = divided.remainder == 0 ? divided.quotient
            : U256.addSmall(divided.quotient, 1).0
        self.totalChunks = chunks
        self.progressURL = Self.progressURL(puzzleID: puzzleID, chunkSize: chunkSize)
        self.journalURL = Self.progressURL(puzzleID: puzzleID, chunkSize: chunkSize)
            .deletingPathExtension().appendingPathExtension("completed")
        self.cursorURL = Self.progressURL(puzzleID: puzzleID, chunkSize: chunkSize)
            .deletingPathExtension().appendingPathExtension("cursor.json")

        let hasNewProgress = FileManager.default.fileExists(atPath: journalURL.path)
            || FileManager.default.fileExists(atPath: cursorURL.path)
        if hasNewProgress {
            try loadJournal()
            try loadCursor()
        } else if FileManager.default.fileExists(atPath: progressURL.path) {
            guard let data = try? Data(contentsOf: progressURL),
                  let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
                  saved.puzzleID == puzzleID,
                  saved.minimumHex == minimum.hexString,
                  saved.maximumHex == maximum.hexString,
                  saved.chunkSize == chunkSize,
                  let savedCompleted = Self.parseIndices(saved.completed),
                  let savedOffset = U256(hex: saved.activeOffset) else {
                throw PuzzleChunkError.unreadableProgress
            }
            guard savedCompleted.allSatisfy({ $0 < chunks }) else {
                throw PuzzleChunkError.unreadableProgress
            }
            completed = Set(savedCompleted)
            activeOffset = savedOffset
            if let value = saved.activeIndex {
                guard let index = U256(hex: value), index < chunks else {
                    throw PuzzleChunkError.unreadableProgress
                }
                if completed.contains(index) {
                    activeOffset = .zero
                    activeIndex = nil
                } else {
                    activeIndex = index
                    let bounds = try self.bounds(for: index)
                    let chunkWidth = U256.addSmall(U256.subb(bounds.upper, bounds.lower).0, 1)
                    guard activeOffset < chunkWidth.0 else {
                        throw PuzzleChunkError.unreadableProgress
                    }
                }
            } else if !activeOffset.isZero {
                throw PuzzleChunkError.unreadableProgress
            }
            try writeJournal()
            try persistCursor()
        }
    }

    public var completedChunkCount: Int { completed.count }

    public var activeChunkProgress: Double {
        guard let activeIndex, let chunk = try? bounds(for: activeIndex) else { return 0 }
        let width = U256.subb(chunk.upper, chunk.lower).0.l0 &+ 1
        guard width > 0 else { return 0 }
        return min(1, Double(activeOffset.l0) / Double(width))
    }

    public var progressSummary: String {
        if totalChunks.l3 == 0, totalChunks.l2 == 0, totalChunks.l1 == 0 {
            return "\(completed.count) / \(totalChunks.l0) chunks complete"
        }
        return "\(completed.count) chunks complete · total chunks 0x\(totalChunks.hexString)"
    }

    /// Returns the current unscanned suffix of a chunk, or nil when every
    /// chunk has completed. New chunks are selected uniformly among the
    /// remaining indices using rejection sampling.
    public func nextRange() throws -> KeySearchRange? {
        if activeIndex == nil {
            if isComplete { return nil }
            let index = try chooseUncompletedIndex()
            activeIndex = index
            activeOffset = .zero
            try persistCursor()
        }
        guard let index = activeIndex else { return nil }
        let chunkBounds = try bounds(for: index)
        let (start, overflow) = U256.addc(chunkBounds.lower, activeOffset)
        guard overflow == 0, start <= chunkBounds.upper else {
            throw PuzzleChunkError.invalidProgress
        }
        return try KeySearchRange(minimum: start, maximum: chunkBounds.upper, step: 1)
    }

    /// Records exactly the number of keys returned by one completed GPU
    /// dispatch. Partial progress is checkpointed at most every 30 seconds.
    @discardableResult
    public func recordScanned(_ count: UInt64) throws -> Bool {
        guard count > 0, let index = activeIndex else { return false }
        let (updated, overflow) = U256.addSmall(activeOffset, count)
        guard overflow == 0 else { throw PuzzleChunkError.invalidProgress }
        let chunkBounds = try bounds(for: index)
        let width = U256.addSmall(U256.subb(chunkBounds.upper, chunkBounds.lower).0, 1).0
        guard updated <= width else { throw PuzzleChunkError.invalidProgress }
        activeOffset = updated
        let didComplete = updated == width
        if didComplete {
            completed.insert(index)
            try appendCompleted(index)
            activeIndex = nil
            activeOffset = .zero
            try persistCursor()
        } else if Date().timeIntervalSince(lastCursorSave) >= checkpointInterval {
            try persistCursor()
        }
        return didComplete
    }

    /// Flushes the active cursor when a search stops cleanly.
    public func flushProgress() throws {
        try persistCursor()
    }

    public var isComplete: Bool {
        guard totalChunks.l3 == 0, totalChunks.l2 == 0,
              totalChunks.l1 == 0 else { return false }
        return UInt64(completed.count) == totalChunks.l0 && activeIndex == nil
    }

    public static func resetProgress(puzzleID: Int) {
        let prefix = "puzzle-progress-\(puzzleID)-"
        let dir = ResultStore.directory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func progressURL(puzzleID: Int, chunkSize: UInt64) -> URL {
        ResultStore.directory.appendingPathComponent(
            "puzzle-progress-\(puzzleID)-\(chunkSize).json")
    }

    private static func parseIndices(_ values: [String]) -> [U256]? {
        let parsed = values.compactMap(U256.init(hex:))
        return parsed.count == values.count ? parsed : nil
    }

    private func persistCursor() throws {
        let snapshot = Cursor(puzzleID: puzzleID,
                              minimumHex: minimum.hexString,
                              maximumHex: maximum.hexString,
                              chunkSize: chunkSize,
                              activeIndex: activeIndex?.hexString,
                              activeOffset: activeOffset.hexString)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: cursorURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: cursorURL.path)
        lastCursorSave = Date()
    }

    private func loadJournal() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let data: Data
        do { data = try Data(contentsOf: journalURL) }
        catch { throw PuzzleChunkError.unreadableProgress }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PuzzleChunkError.unreadableProgress
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if !text.hasSuffix("\n"), !lines.isEmpty { lines.removeLast() }
        for line in lines {
            guard let index = U256(hex: String(line)), index < totalChunks else {
                throw PuzzleChunkError.unreadableProgress
            }
            completed.insert(index)
        }
    }

    private func loadCursor() throws {
        guard FileManager.default.fileExists(atPath: cursorURL.path) else { return }
        guard let data = try? Data(contentsOf: cursorURL),
              let saved = try? JSONDecoder().decode(Cursor.self, from: data),
              saved.puzzleID == puzzleID,
              saved.minimumHex == minimum.hexString,
              saved.maximumHex == maximum.hexString,
              saved.chunkSize == chunkSize,
              let offset = U256(hex: saved.activeOffset) else {
            throw PuzzleChunkError.unreadableProgress
        }
        activeOffset = offset
        if let value = saved.activeIndex {
            guard let index = U256(hex: value), index < totalChunks else {
                throw PuzzleChunkError.unreadableProgress
            }
            if completed.contains(index) {
                activeOffset = .zero
                activeIndex = nil
                try persistCursor()
                return
            }
            let bounds = try self.bounds(for: index)
            let width = U256.addSmall(U256.subb(bounds.upper, bounds.lower).0, 1).0
            guard offset < width else { throw PuzzleChunkError.unreadableProgress }
            activeIndex = index
        } else if !offset.isZero {
            throw PuzzleChunkError.unreadableProgress
        }
    }

    private func appendCompleted(_ index: U256) throws {
        let line = Data((index.hexString + "\n").utf8)
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            guard FileManager.default.createFile(atPath: journalURL.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    private func writeJournal() throws {
        let data = Data(completed.map(\.hexString).sorted().joined(separator: "\n").appending("\n").utf8)
        try data.write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: journalURL.path)
    }

    private func bounds(for index: U256) throws -> (lower: U256, upper: U256) {
        guard let offset = multiplySmall(index, chunkSize) else {
            throw PuzzleChunkError.invalidConfiguration
        }
        let (lower, carry) = U256.addc(minimum, offset)
        guard carry == 0, lower <= maximum else { throw PuzzleChunkError.invalidConfiguration }
        let (candidateUpper, upperCarry) = U256.addSmall(lower, chunkSize - 1)
        let upper = upperCarry != 0 || maximum < candidateUpper ? maximum : candidateUpper
        return (lower, upper)
    }

    private func chooseUncompletedIndex() throws -> U256 {
        guard !isComplete else { throw PuzzleChunkError.noChunksRemaining }
        var tries = 0
        while true {
            let candidate = try Self.randomBelow(totalChunks)
            if !completed.contains(candidate) { return candidate }
            tries += 1

            // For small puzzles, avoid a long rejection tail near completion.
            if tries >= 128,
               totalChunks.l3 == 0, totalChunks.l2 == 0,
               totalChunks.l1 == 0, totalChunks.l0 <= 1_000_000 {
                let count = totalChunks.l0
                let start = candidate.l0
                for offset in 0..<count {
                    let index = U256((start + offset) % count)
                    if !completed.contains(index) { return index }
                }
                throw PuzzleChunkError.noChunksRemaining
            }
        }
    }

    private static func randomBelow(_ bound: U256) throws -> U256 {
        guard !bound.isZero else { throw PuzzleChunkError.noChunksRemaining }
        if bound == .one { return .zero }
        while true {
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else { throw PuzzleChunkError.randomSourceFailed }
            let bits = bound.bitWidth
            if bits < 256 {
                for bit in bits..<256 {
                    bytes[31 - bit / 8] &= ~UInt8(1 << (bit % 8))
                }
            }
            let candidate = U256(bigEndianBytes: bytes)
            if candidate < bound { return candidate }
        }
    }
}

public enum PuzzleChunkError: LocalizedError {
    case invalidConfiguration, unreadableProgress, invalidProgress
    case noChunksRemaining, randomSourceFailed

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "The puzzle chunk settings are invalid."
        case .unreadableProgress: return "Saved puzzle progress is invalid. Reset this puzzle's progress to start over."
        case .invalidProgress: return "The saved puzzle cursor is outside its chunk."
        case .noChunksRemaining: return "Every chunk in this puzzle range is complete."
        case .randomSourceFailed: return "The system random source could not choose a puzzle chunk."
        }
    }
}
