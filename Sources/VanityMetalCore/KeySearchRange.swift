import Foundation

/// Inclusive private-key interval sampled at a positive integer stride.
public struct KeySearchRange: Sendable {
    public let minimum: U256
    public let maximum: U256
    public let step: UInt64
    public let minimumStep: UInt64
    public let maximumStep: UInt64
    public let keyCount: U256

    public init(minimum: U256, maximum: U256, step: UInt64) throws {
        try self.init(minimum: minimum, maximum: maximum,
                      minimumStep: step, maximumStep: step, selectedStep: step)
    }

    private init(minimum: U256, maximum: U256, minimumStep: UInt64,
                 maximumStep: UInt64, selectedStep: UInt64) throws {
        guard !minimum.isZero, minimum < Fn.n, !maximum.isZero, maximum < Fn.n else {
            throw KeyRangeError.outsideScalarField
        }
        guard minimum <= maximum else { throw KeyRangeError.reversedBounds }
        guard minimumStep > 0, minimumStep <= maximumStep,
              selectedStep >= minimumStep, selectedStep <= maximumStep else {
            throw KeyRangeError.invalidStepRange
        }
        let delta = U256.subb(maximum, minimum).0
        let (q, _) = divModSmall(delta, selectedStep)
        let (count, carry) = U256.addSmall(q, 1)
        guard carry == 0 else { throw KeyRangeError.rangeTooWide }
        self.minimum = minimum
        self.maximum = maximum
        self.step = selectedStep
        self.minimumStep = minimumStep
        self.maximumStep = maximumStep
        self.keyCount = count
    }

    public func nextCycle() -> KeySearchRange {
        let chosen = UInt64.random(in: minimumStep...maximumStep)
        // The same validated key bounds and step limits are reused each cycle.
        return try! KeySearchRange(minimum: minimum, maximum: maximum,
                                   minimumStep: minimumStep, maximumStep: maximumStep,
                                   selectedStep: chosen)
    }

    public static func parse(minimum: String, maximum: String,
                             minimumStep: String, maximumStep: String) throws -> KeySearchRange {
        guard let lo = U256(hex: minimum.trimmingCharacters(in: .whitespacesAndNewlines)),
              let hi = U256(hex: maximum.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw KeyRangeError.invalidHex
        }
        let low = try parseStep(minimumStep)
        let high = try parseStep(maximumStep)
        guard low <= high else { throw KeyRangeError.invalidStepRange }
        return try KeySearchRange(minimum: lo, maximum: hi,
                                  minimumStep: low, maximumStep: high,
                                  selectedStep: UInt64.random(in: low...high))
    }

    private static func parseStep(_ text: String) throws -> UInt64 {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let radix = raw.lowercased().hasPrefix("0x") ? 16 : 10
        let digits = radix == 16 ? String(raw.dropFirst(2)) : raw
        guard !digits.isEmpty, let amount = UInt64(digits, radix: radix), amount > 0 else {
            throw KeyRangeError.invalidStep
        }
        return amount
    }
}

public enum KeyRangeError: LocalizedError {
    case invalidHex, invalidStep, invalidStepRange, reversedBounds, outsideScalarField, rangeTooWide
    public var errorDescription: String? {
        switch self {
        case .invalidHex: return "Enter minimum and maximum as hexadecimal private keys."
        case .invalidStep: return "Step limits must be positive integers (decimal or 0x-prefixed hexadecimal)."
        case .invalidStepRange: return "Minimum step must not exceed maximum step."
        case .reversedBounds: return "Minimum key must not exceed maximum key."
        case .outsideScalarField: return "Keys must be between 1 and secp256k1 order minus 1."
        case .rangeTooWide: return "The selected range is too wide to represent."
        }
    }
}
