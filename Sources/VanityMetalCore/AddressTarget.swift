//
//  AddressTarget.swift
//  VanityMetal
//
//  Turns a human-typed prefix ("1Love", "bc1qneon", "3Cyber", "0xdecaf") into
//  one or more exact inclusive ranges over the 20-byte hash the GPU compares
//  against — plus the true difficulty of hitting it.
//
//  Base58 prefixes do not align to bit boundaries, so a bit-mask would be
//  wrong in both directions. Ranges are exact.
//

import Foundation

public enum AddressKind: UInt32, CaseIterable, Identifiable, Sendable {
    case p2pkhCompressed = 0
    case p2pkhUncompressed = 1
    case p2sh = 2
    case bech32 = 3
    case eth = 4

    public var id: UInt32 { rawValue }

    public var title: String {
        switch self {
        case .p2pkhCompressed:   return "P2PKH (1…)"
        case .p2pkhUncompressed: return "P2PKH uncompressed (1…)"
        case .p2sh:              return "P2SH-P2WPKH (3…)"
        case .bech32:            return "Bech32 SegWit (bc1q…)"
        case .eth:               return "Ethereum (0x…)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .p2pkhCompressed:   return "P2PKH"
        case .p2pkhUncompressed: return "P2PKH-U"
        case .p2sh:              return "P2SH"
        case .bech32:            return "BECH32"
        case .eth:               return "ETH"
        }
    }

    /// Bit flag telling the kernel which hash path this kind needs.
    public var hashPath: UInt32 {
        switch self {
        case .p2pkhCompressed, .bech32: return 1 << 0
        case .p2pkhUncompressed:        return 1 << 1
        case .p2sh:                     return 1 << 2
        case .eth:                      return 1 << 3
        }
    }

    public var versionByte: UInt8 {
        switch self {
        case .p2sh: return 0x05
        default:    return 0x00
        }
    }
}

// MARK: - Non-modular 256-bit helpers used only for range maths

@inline(__always)
func mulAddSmall(_ a: U256, _ m: UInt64, _ add: UInt64) -> U256 {
    let (r0, c0) = madd64(a.l0, m, add, 0)
    let (r1, c1) = madd64(a.l1, m, c0, 0)
    let (r2, c2) = madd64(a.l2, m, c1, 0)
    let (r3, _)  = madd64(a.l3, m, c2, 0)
    return U256(r0, r1, r2, r3)
}

@inline(__always)
func shiftRight32(_ a: U256) -> U256 {
    U256((a.l0 >> 32) | (a.l1 << 32),
         (a.l1 >> 32) | (a.l2 << 32),
         (a.l2 >> 32) | (a.l3 << 32),
          a.l3 >> 32)
}

func pow2(_ n: Int) -> U256 {
    precondition(n >= 0 && n < 256)
    var r = U256()
    switch n >> 6 {
    case 0: r.l0 = 1 << UInt64(n & 63)
    case 1: r.l1 = 1 << UInt64(n & 63)
    case 2: r.l2 = 1 << UInt64(n & 63)
    default: r.l3 = 1 << UInt64(n & 63)
    }
    return r
}

/// 2^n - 1
func maskBits(_ n: Int) -> U256 {
    if n >= 256 { return U256(~0, ~0, ~0, ~0) }
    if n == 0 { return .zero }
    return U256.subb(pow2(n), U256(1)).0
}

// MARK: - A resolved target

public struct HashRange: Equatable, Sendable {
    public var lo: [UInt8]      // 20 bytes, inclusive
    public var hi: [UInt8]      // 20 bytes, inclusive
    public var kind: AddressKind

    public init(lo: [UInt8], hi: [UInt8], kind: AddressKind) {
        self.lo = lo; self.hi = hi; self.kind = kind
    }
}

public struct SearchTarget: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var text: String
    public var kind: AddressKind
    public var ranges: [HashRange]
    /// Expected number of keys per hit.
    public var difficulty: Double
    public var caseSensitive: Bool

    public var isValid: Bool { !ranges.isEmpty }
}

public enum TargetParseError: LocalizedError {
    case empty
    case badCharacter(Character, String)
    case tooLong
    case impossible(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "Prefix is empty."
        case .badCharacter(let c, let set):
            return "‘\(c)’ is not a valid \(set) character."
        case .tooLong: return "Prefix is longer than the address it has to fit inside."
        case .impossible(let why): return why
        case .unsupported(let why): return why
        }
    }
}

public enum TargetParser {

    // MARK: Public entry point

    /// Parses a prefix and works out which kind it is from its shape, unless
    /// `forceKind` pins it.
    public static func parse(_ raw: String,
                             forceKind: AddressKind? = nil,
                             caseSensitive: Bool = true) throws -> SearchTarget {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TargetParseError.empty }

        let kind: AddressKind
        if let f = forceKind {
            kind = f
        } else if text.lowercased().hasPrefix("0x") {
            kind = .eth
        } else if text.lowercased().hasPrefix("bc1") || text.lowercased().hasPrefix("tb1") {
            kind = .bech32
        } else if text.hasPrefix("3") {
            kind = .p2sh
        } else {
            kind = .p2pkhCompressed
        }

        let ranges: [HashRange]
        switch kind {
        case .eth:      ranges = try parseHexPrefix(text, kind: kind)
        case .bech32:   ranges = try parseBech32Prefix(text)
        case .p2sh:     ranges = try parseBase58Prefix(text, kind: .p2sh)
        case .p2pkhCompressed, .p2pkhUncompressed:
            ranges = try parseBase58Prefix(text, kind: kind)
        }

        guard !ranges.isEmpty else {
            throw TargetParseError.impossible("No address can begin with “\(text)”.")
        }

        return SearchTarget(text: text, kind: kind, ranges: ranges,
                            difficulty: difficulty(of: ranges),
                            caseSensitive: caseSensitive)
    }

    /// Expected keys per hit: 2^160 divided by the number of accepted hashes.
    public static func difficulty(of ranges: [HashRange]) -> Double {
        var accepted = 0.0
        for r in ranges {
            var lo = 0.0, hi = 0.0
            for b in r.lo { lo = lo * 256 + Double(b) }
            for b in r.hi { hi = hi * 256 + Double(b) }
            accepted += (hi - lo + 1)
        }
        guard accepted > 0 else { return .infinity }
        return pow(2.0, 160.0) / accepted
    }

    // MARK: Base58 (P2PKH / P2SH)

    static func parseBase58Prefix(_ prefix: String, kind: AddressKind) throws -> [HashRange] {
        let chars = Array(prefix)
        for c in chars where Base58.value(of: c) == nil {
            throw TargetParseError.badCharacter(c, "Base58")
        }
        guard chars.count <= 35 else { throw TargetParseError.tooLong }

        let version = kind.versionByte
        let versionBase = mulAddSmall(pow2(192), UInt64(version), 0)   // version * 2^192
        let payloadLo = versionBase
        let payloadHi = U256.addc(versionBase, maskBits(192)).0

        // Leading '1' characters are literal leading zero bytes of the payload.
        var z = 0
        while z < chars.count && chars[z] == "1" { z += 1 }
        let rest = Array(chars[z...])

        // For version 0 the payload always starts with one zero byte, so a
        // P2PKH prefix must start with '1'. For version 5 it must not.
        if version == 0x00 && z == 0 {
            throw TargetParseError.impossible("A P2PKH address always begins with ‘1’.")
        }
        if version != 0x00 && z > 0 {
            throw TargetParseError.impossible("A P2SH address never begins with ‘1’.")
        }

        // A prefix made entirely of '1's only sets an upper bound: "1" quite
        // correctly matches "11xyz…" as well.  As soon as a non-'1' character
        // follows, the number of leading zero bytes is pinned exactly, which
        // gives a lower bound too.
        var zeroLo = U256.zero
        var zeroHi = maskBits(200)
        if z > 0 {
            guard z <= 24 else { throw TargetParseError.tooLong }
            zeroHi = U256.subb(pow2(8 * (25 - z)), U256(1)).0
            if !rest.isEmpty { zeroLo = pow2(8 * (24 - z)) }
        }

        var out: [HashRange] = []

        func consider(_ numLo: U256, _ numHi: U256) {
            // Intersect the three constraints.
            var lo = numLo, hi = numHi
            if payloadLo > lo { lo = payloadLo }
            if hi > payloadHi { hi = payloadHi }
            if zeroLo > lo { lo = zeroLo }
            if hi > zeroHi { hi = zeroHi }
            guard !(hi < lo) else { return }
            let h160Lo = shiftRight32(U256.subb(lo, versionBase).0)
            let h160Hi = shiftRight32(U256.subb(hi, versionBase).0)
            out.append(HashRange(lo: Array(h160Lo.bigEndianBytes[12...]),
                                 hi: Array(h160Hi.bigEndianBytes[12...]),
                                 kind: kind))
        }

        if rest.isEmpty {
            // Prefix is nothing but '1's: the numeric part is unconstrained.
            consider(.zero, maskBits(200))
        } else {
            // The numeric part has some digit count d; try every plausible one.
            for d in rest.count...35 {
                var lo = U256.zero, hi = U256.zero
                for c in rest {
                    let v = UInt64(Base58.value(of: c)!)
                    lo = mulAddSmall(lo, 58, v)
                    hi = mulAddSmall(hi, 58, v)
                }
                for _ in 0..<(d - rest.count) {
                    lo = mulAddSmall(lo, 58, 0)      // pad with '1' = 0
                    hi = mulAddSmall(hi, 58, 57)     // pad with 'z' = 57
                }
                consider(lo, hi)
            }
        }

        return mergeRanges(out, kind: kind)
    }

    // MARK: Bech32

    static func parseBech32Prefix(_ prefix: String) throws -> [HashRange] {
        let lower = prefix.lowercased()
        let hrp: String
        if lower.hasPrefix("bc1") { hrp = "bc" }
        else if lower.hasPrefix("tb1") { hrp = "tb" }
        else { throw TargetParseError.unsupported("A SegWit prefix must start with bc1 or tb1.") }

        var body = Array(lower.dropFirst(hrp.count + 1))
        if body.isEmpty {
            return [HashRange(lo: [UInt8](repeating: 0x00, count: 20),
                              hi: [UInt8](repeating: 0xFF, count: 20), kind: .bech32)]
        }
        // The first data character encodes the witness version; v0 is 'q'.
        guard body[0] == "q" else {
            throw TargetParseError.unsupported("Only witness version 0 (bc1q…) is supported.")
        }
        body.removeFirst()

        guard body.count <= 32 else { throw TargetParseError.tooLong }
        var value = U256.zero
        for c in body {
            guard let v = Bech32.value(of: c) else {
                throw TargetParseError.badCharacter(c, "Bech32")
            }
            value = mulAddSmall(value, 32, UInt64(v))
        }
        let freeBits = 160 - 5 * body.count
        let shifted = shiftLeft(value, freeBits)
        let hiVal = U256.addc(shifted, maskBits(freeBits)).0
        return [HashRange(lo: Array(shifted.bigEndianBytes[12...]),
                          hi: Array(hiVal.bigEndianBytes[12...]),
                          kind: .bech32)]
    }

    // MARK: Hex (Ethereum)

    static func parseHexPrefix(_ prefix: String, kind: AddressKind) throws -> [HashRange] {
        var s = prefix
        if s.lowercased().hasPrefix("0x") { s.removeFirst(2) }
        s = s.lowercased()
        if s.isEmpty {
            return [HashRange(lo: [UInt8](repeating: 0x00, count: 20),
                              hi: [UInt8](repeating: 0xFF, count: 20), kind: kind)]
        }
        guard s.count <= 40 else { throw TargetParseError.tooLong }
        var value = U256.zero
        for c in s {
            guard let v = c.hexDigitValue else {
                throw TargetParseError.badCharacter(c, "hexadecimal")
            }
            value = mulAddSmall(value, 16, UInt64(v))
        }
        let freeBits = 160 - 4 * s.count
        let shifted = shiftLeft(value, freeBits)
        let hiVal = U256.addc(shifted, maskBits(freeBits)).0
        return [HashRange(lo: Array(shifted.bigEndianBytes[12...]),
                          hi: Array(hiVal.bigEndianBytes[12...]),
                          kind: kind)]
    }

    // MARK: helpers

    static func shiftLeft(_ a: U256, _ bits: Int) -> U256 {
        if bits <= 0 { return a }
        var r = a
        var remaining = bits
        while remaining >= 64 {
            r = U256(0, r.l0, r.l1, r.l2)
            remaining -= 64
        }
        if remaining > 0 {
            let s = UInt64(remaining)
            let inv = UInt64(64 - remaining)
            r = U256(r.l0 << s,
                     (r.l1 << s) | (r.l0 >> inv),
                     (r.l2 << s) | (r.l1 >> inv),
                     (r.l3 << s) | (r.l2 >> inv))
        }
        return r
    }

    static func mergeRanges(_ ranges: [HashRange], kind: AddressKind) -> [HashRange] {
        guard ranges.count > 1 else { return ranges }
        let sorted = ranges.sorted { lexLess($0.lo, $1.lo) }
        var out: [HashRange] = []
        for r in sorted {
            if var last = out.last, !lexLess(incremented(last.hi), r.lo) {
                if lexLess(last.hi, r.hi) { last.hi = r.hi }
                out[out.count - 1] = last
            } else {
                out.append(r)
            }
        }
        return out
    }

    static func lexLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for i in 0..<min(a.count, b.count) {
            if a[i] != b[i] { return a[i] < b[i] }
        }
        return false
    }

    static func incremented(_ a: [UInt8]) -> [UInt8] {
        var r = a
        var i = r.count - 1
        while i >= 0 {
            if r[i] == 0xFF { r[i] = 0; i -= 1 } else { r[i] += 1; return r }
        }
        return [UInt8](repeating: 0xFF, count: a.count)   // saturate
    }
}
