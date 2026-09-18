//
//  Secp256k1.swift
//  VanityMetal
//
//  A compact, dependency-free secp256k1 implementation used for three things:
//    1. building the per-thread starting points the GPU walks from,
//    2. building the small table of G multiples the kernel needs,
//    3. re-deriving and verifying every hit the GPU reports.
//
//  Arithmetic is on four 64-bit limbs, little-endian (l0 is least significant).
//

import Foundation
import Security

// MARK: - 256-bit unsigned integer

public struct U256: Equatable, Hashable, Comparable, CustomStringConvertible, Sendable {
    public var l0: UInt64
    public var l1: UInt64
    public var l2: UInt64
    public var l3: UInt64

    public init(_ l0: UInt64 = 0, _ l1: UInt64 = 0, _ l2: UInt64 = 0, _ l3: UInt64 = 0) {
        self.l0 = l0; self.l1 = l1; self.l2 = l2; self.l3 = l3
    }

    public static let zero = U256()
    public static let one = U256(1)

    /// Big-endian hex, with or without a `0x` prefix. Returns nil on bad input.
    public init?(hex: String) {
        var s = hex.lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard !s.isEmpty, s.count <= 64, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        s = String(repeating: "0", count: 64 - s.count) + s
        var limbs = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            let start = s.index(s.startIndex, offsetBy: i * 16)
            let end = s.index(start, offsetBy: 16)
            guard let v = UInt64(s[start..<end], radix: 16) else { return nil }
            limbs[3 - i] = v
        }
        self.init(limbs[0], limbs[1], limbs[2], limbs[3])
    }

    /// Big-endian 32 bytes.
    public init(bigEndianBytes b: [UInt8]) {
        precondition(b.count == 32)
        func word(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(b[o + i]) }
            return v
        }
        self.init(word(24), word(16), word(8), word(0))
    }

    public var bigEndianBytes: [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        for (i, w) in [l3, l2, l1, l0].enumerated() {
            for j in 0..<8 { out[i * 8 + j] = UInt8((w >> (56 - 8 * j)) & 0xFF) }
        }
        return out
    }

    /// Little-endian 32-bit limbs — the layout the Metal kernel expects.
    public var metalLimbs: [UInt32] {
        var out = [UInt32](repeating: 0, count: 8)
        for (i, w) in [l0, l1, l2, l3].enumerated() {
            out[i * 2] = UInt32(truncatingIfNeeded: w)
            out[i * 2 + 1] = UInt32(truncatingIfNeeded: w >> 32)
        }
        return out
    }

    public init(metalLimbs m: [UInt32]) {
        precondition(m.count == 8)
        func w(_ i: Int) -> UInt64 { UInt64(m[i * 2]) | (UInt64(m[i * 2 + 1]) << 32) }
        self.init(w(0), w(1), w(2), w(3))
    }

    public var hexString: String {
        [l3, l2, l1, l0].map { String(format: "%016lx", $0) }.joined()
    }
    public var description: String { "0x" + hexString }

    public var isZero: Bool { l0 == 0 && l1 == 0 && l2 == 0 && l3 == 0 }
    public var bitWidth: Int {
        if l3 != 0 { return 256 - l3.leadingZeroBitCount }
        if l2 != 0 { return 192 - l2.leadingZeroBitCount }
        if l1 != 0 { return 128 - l1.leadingZeroBitCount }
        return 64 - l0.leadingZeroBitCount
    }

    public func bit(_ i: Int) -> Bool {
        switch i >> 6 {
        case 0: return (l0 >> UInt64(i & 63)) & 1 == 1
        case 1: return (l1 >> UInt64(i & 63)) & 1 == 1
        case 2: return (l2 >> UInt64(i & 63)) & 1 == 1
        default: return (l3 >> UInt64(i & 63)) & 1 == 1
        }
    }

    public static func < (a: U256, b: U256) -> Bool {
        if a.l3 != b.l3 { return a.l3 < b.l3 }
        if a.l2 != b.l2 { return a.l2 < b.l2 }
        if a.l1 != b.l1 { return a.l1 < b.l1 }
        return a.l0 < b.l0
    }

    /// Wrapping add, returns the carry out.
    @inline(__always)
    public static func addc(_ a: U256, _ b: U256) -> (U256, UInt64) {
        var r = U256(); var c: UInt64 = 0; var o = false
        (r.l0, o) = a.l0.addingReportingOverflow(b.l0); c = o ? 1 : 0
        (r.l1, o) = a.l1.addingReportingOverflow(b.l1); var c2: UInt64 = o ? 1 : 0
        (r.l1, o) = r.l1.addingReportingOverflow(c); if o { c2 += 1 }
        (r.l2, o) = a.l2.addingReportingOverflow(b.l2); var c3: UInt64 = o ? 1 : 0
        (r.l2, o) = r.l2.addingReportingOverflow(c2); if o { c3 += 1 }
        (r.l3, o) = a.l3.addingReportingOverflow(b.l3); var c4: UInt64 = o ? 1 : 0
        (r.l3, o) = r.l3.addingReportingOverflow(c3); if o { c4 += 1 }
        return (r, c4)
    }

    /// Wrapping subtract, returns the borrow out.
    @inline(__always)
    public static func subb(_ a: U256, _ b: U256) -> (U256, UInt64) {
        var r = U256(); var o = false
        (r.l0, o) = a.l0.subtractingReportingOverflow(b.l0); let br: UInt64 = o ? 1 : 0
        (r.l1, o) = a.l1.subtractingReportingOverflow(b.l1); var br2: UInt64 = o ? 1 : 0
        (r.l1, o) = r.l1.subtractingReportingOverflow(br); if o { br2 += 1 }
        (r.l2, o) = a.l2.subtractingReportingOverflow(b.l2); var br3: UInt64 = o ? 1 : 0
        (r.l2, o) = r.l2.subtractingReportingOverflow(br2); if o { br3 += 1 }
        (r.l3, o) = a.l3.subtractingReportingOverflow(b.l3); var br4: UInt64 = o ? 1 : 0
        (r.l3, o) = r.l3.subtractingReportingOverflow(br3); if o { br4 += 1 }
        return (r, br4)
    }

    /// Add a small unsigned value.
    public static func addSmall(_ a: U256, _ v: UInt64) -> (U256, UInt64) {
        return addc(a, U256(v))
    }
}

@inline(__always)
internal func madd64(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ carry: UInt64) -> (lo: UInt64, hi: UInt64) {
    var m = a.multipliedFullWidth(by: b)
    var o = false
    (m.low, o) = m.low.addingReportingOverflow(c);      if o { m.high &+= 1 }
    (m.low, o) = m.low.addingReportingOverflow(carry);  if o { m.high &+= 1 }
    return (m.low, m.high)
}

// MARK: - Prime field, p = 2^256 - 2^32 - 977

public enum Fp {
    public static let p = U256(0xFFFF_FFFE_FFFF_FC2F, 0xFFFF_FFFF_FFFF_FFFF,
                               0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF)
    /// 2^256 mod p
    static let K: UInt64 = 0x1_0000_03D1

    @inline(__always)
    public static func condSubP(_ a: U256) -> U256 {
        if a < p { return a }
        return U256.subb(a, p).0
    }

    @inline(__always)
    public static func add(_ a: U256, _ b: U256) -> U256 {
        let (s, carry) = U256.addc(a, b)
        if carry != 0 {
            let (t, _) = U256.addc(s, U256(K))
            return condSubP(t)
        }
        return condSubP(s)
    }

    @inline(__always)
    public static func sub(_ a: U256, _ b: U256) -> U256 {
        let (d, borrow) = U256.subb(a, b)
        if borrow != 0 { return U256.addc(d, p).0 }
        return d
    }

    @inline(__always)
    public static func neg(_ a: U256) -> U256 {
        a.isZero ? a : U256.subb(p, a).0
    }

    /// Full 512-bit product, little-endian 64-bit words.
    @inline(__always)
    static func mulWide(_ a: U256, _ b: U256)
        -> (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) {
        var t0: UInt64 = 0, t1: UInt64 = 0, t2: UInt64 = 0, t3: UInt64 = 0
        var t4: UInt64 = 0, t5: UInt64 = 0, t6: UInt64 = 0, t7: UInt64 = 0
        let a0 = a.l0, a1 = a.l1, a2 = a.l2, a3 = a.l3
        let b0 = b.l0, b1 = b.l1, b2 = b.l2, b3 = b.l3
        var c: UInt64

        (t0, c) = madd64(a0, b0, t0, 0)
        (t1, c) = madd64(a0, b1, t1, c)
        (t2, c) = madd64(a0, b2, t2, c)
        (t3, c) = madd64(a0, b3, t3, c)
        t4 = c

        (t1, c) = madd64(a1, b0, t1, 0)
        (t2, c) = madd64(a1, b1, t2, c)
        (t3, c) = madd64(a1, b2, t3, c)
        (t4, c) = madd64(a1, b3, t4, c)
        t5 = c

        (t2, c) = madd64(a2, b0, t2, 0)
        (t3, c) = madd64(a2, b1, t3, c)
        (t4, c) = madd64(a2, b2, t4, c)
        (t5, c) = madd64(a2, b3, t5, c)
        t6 = c

        (t3, c) = madd64(a3, b0, t3, 0)
        (t4, c) = madd64(a3, b1, t4, c)
        (t5, c) = madd64(a3, b2, t5, c)
        (t6, c) = madd64(a3, b3, t6, c)
        t7 = c

        return (t0, t1, t2, t3, t4, t5, t6, t7)
    }

    /// Folds a 512-bit value into the field. Mirrors fe_reduce512 in the kernel.
    @inline(__always)
    static func reduce(_ t: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)) -> U256 {
        var a0 = t.0, a1 = t.1, a2 = t.2, a3 = t.3
        var c: UInt64

        // Pass 1: low + high * K  (high * K < 2^289, so it needs one extra limb)
        (a0, c) = madd64(t.4, K, a0, 0)
        (a1, c) = madd64(t.5, K, a1, c)
        (a2, c) = madd64(t.6, K, a2, c)
        (a3, c) = madd64(t.7, K, a3, c)
        var a4 = c                       // < 2^33

        // Pass 2: fold a4 * K, which is < 2^66 and so spans two limbs.
        let m = a4.multipliedFullWidth(by: K)
        var o = false
        (a0, o) = a0.addingReportingOverflow(m.low)
        let c1: UInt64 = o ? 1 : 0
        (a1, o) = a1.addingReportingOverflow(m.high)
        var c2: UInt64 = o ? 1 : 0
        (a1, o) = a1.addingReportingOverflow(c1); if o { c2 += 1 }
        (a2, o) = a2.addingReportingOverflow(c2)
        let c3: UInt64 = o ? 1 : 0
        (a3, o) = a3.addingReportingOverflow(c3)
        a4 = o ? 1 : 0

        // Pass 3: a4 is now 0 or 1, and when it is 1 the low limbs are tiny,
        // so this fold provably cannot carry out again.
        if a4 != 0 {
            var carry: UInt64
            (a0, o) = a0.addingReportingOverflow(K); carry = o ? 1 : 0
            (a1, o) = a1.addingReportingOverflow(carry); carry = o ? 1 : 0
            (a2, o) = a2.addingReportingOverflow(carry); carry = o ? 1 : 0
            (a3, _) = a3.addingReportingOverflow(carry)
        }

        return condSubP(condSubP(U256(a0, a1, a2, a3)))
    }

    @inline(__always)
    public static func mul(_ a: U256, _ b: U256) -> U256 { reduce(mulWide(a, b)) }

    @inline(__always)
    public static func sqr(_ a: U256) -> U256 { mul(a, a) }

    @inline(__always)
    static func pow2k(_ a: U256, _ k: Int) -> U256 {
        var r = a
        for _ in 0..<k { r = sqr(r) }
        return r
    }

    /// Modular inverse. Same libsecp256k1 addition chain the kernel uses.
    public static func inv(_ a: U256) -> U256 {
        if a.isZero { return .zero }
        let x2 = mul(sqr(a), a)
        let x3 = mul(sqr(x2), a)
        let x6 = mul(pow2k(x3, 3), x3)
        let x9 = mul(pow2k(x6, 3), x3)
        let x11 = mul(pow2k(x9, 2), x2)
        let x22 = mul(pow2k(x11, 11), x11)
        let x44 = mul(pow2k(x22, 22), x22)
        let x88 = mul(pow2k(x44, 44), x44)
        let x176 = mul(pow2k(x88, 88), x88)
        let x220 = mul(pow2k(x176, 44), x44)
        let x223 = mul(pow2k(x220, 3), x3)
        var t = pow2k(x223, 23)
        t = mul(t, x22)
        t = mul(pow2k(t, 5), a)
        t = mul(pow2k(t, 3), x2)
        t = mul(pow2k(t, 2), a)
        return t
    }
}

// MARK: - Scalar field (group order n)

public enum Fn {
    public static let n = U256(0xBFD2_5E8C_D036_4141, 0xBAAE_DCE6_AF48_A03B,
                               0xFFFF_FFFF_FFFF_FFFE, 0xFFFF_FFFF_FFFF_FFFF)

    public static func add(_ a: U256, _ b: U256) -> U256 {
        let (s, carry) = U256.addc(a, b)
        if carry != 0 || !(s < n) { return U256.subb(s, n).0 }
        return s
    }

    public static func sub(_ a: U256, _ b: U256) -> U256 {
        let (d, borrow) = U256.subb(a, b)
        if borrow != 0 { return U256.addc(d, n).0 }
        return d
    }

    /// Adds a signed offset, wrapping in the scalar field.
    public static func addOffset(_ a: U256, _ off: Int64) -> U256 {
        if off >= 0 { return add(a, U256(UInt64(off))) }
        return sub(a, U256(UInt64(-off)))
    }

    public static func random() -> U256 {
        var bytes = [UInt8](repeating: 0, count: 32)
        var out = U256.zero
        repeat {
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
            out = U256(bigEndianBytes: bytes)
        } while out.isZero || !(out < n)
        return out
    }
}

// MARK: - Curve points

public struct ECPoint: Equatable, Sendable {
    public var x: U256
    public var y: U256
    public var isInfinity: Bool

    public init(x: U256, y: U256) { self.x = x; self.y = y; self.isInfinity = false }
    public init() { self.x = .zero; self.y = .zero; self.isInfinity = true }

    public var parity: UInt8 { UInt8(y.l0 & 1) }
}

struct Jacobian {
    var x: U256
    var y: U256
    var z: U256
    var isInfinity: Bool

    static let infinity = Jacobian(x: .one, y: .one, z: .zero, isInfinity: true)

    init(x: U256, y: U256, z: U256, isInfinity: Bool = false) {
        self.x = x; self.y = y; self.z = z; self.isInfinity = isInfinity
    }
    init(_ p: ECPoint) {
        self.init(x: p.x, y: p.y, z: .one, isInfinity: p.isInfinity)
    }

    var affine: ECPoint {
        if isInfinity || z.isZero { return ECPoint() }
        let zi = Fp.inv(z)
        let zi2 = Fp.sqr(zi)
        let zi3 = Fp.mul(zi2, zi)
        return ECPoint(x: Fp.mul(x, zi2), y: Fp.mul(y, zi3))
    }

    func doubled() -> Jacobian {
        if isInfinity || y.isZero { return .infinity }
        // dbl-2009-l (a = 0)
        let A = Fp.sqr(x)
        let B = Fp.sqr(y)
        let C = Fp.sqr(B)
        var D = Fp.sub(Fp.sub(Fp.sqr(Fp.add(x, B)), A), C)
        D = Fp.add(D, D)
        let E = Fp.add(Fp.add(A, A), A)
        let F = Fp.sqr(E)
        let x3 = Fp.sub(F, Fp.add(D, D))
        var c8 = Fp.add(C, C); c8 = Fp.add(c8, c8); c8 = Fp.add(c8, c8)
        let y3 = Fp.sub(Fp.mul(E, Fp.sub(D, x3)), c8)
        let z3 = Fp.add(Fp.mul(y, z), Fp.mul(y, z))
        return Jacobian(x: x3, y: y3, z: z3)
    }

    /// Mixed addition with an affine point (madd-2007-bl).
    func adding(affine q: ECPoint) -> Jacobian {
        if q.isInfinity { return self }
        if isInfinity { return Jacobian(q) }
        let z1z1 = Fp.sqr(z)
        let u2 = Fp.mul(q.x, z1z1)
        let s2 = Fp.mul(Fp.mul(q.y, z), z1z1)
        let h = Fp.sub(u2, x)
        let r0 = Fp.sub(s2, y)
        if h.isZero {
            if r0.isZero { return doubled() }
            return .infinity
        }
        let hh = Fp.sqr(h)
        var i = Fp.add(hh, hh); i = Fp.add(i, i)
        let j = Fp.mul(h, i)
        let r = Fp.add(r0, r0)
        let v = Fp.mul(x, i)
        let x3 = Fp.sub(Fp.sub(Fp.sqr(r), j), Fp.add(v, v))
        var y1j = Fp.mul(y, j); y1j = Fp.add(y1j, y1j)
        let y3 = Fp.sub(Fp.mul(r, Fp.sub(v, x3)), y1j)
        let z3 = Fp.sub(Fp.sub(Fp.sqr(Fp.add(z, h)), z1z1), hh)
        return Jacobian(x: x3, y: y3, z: z3)
    }
}

public enum Secp256k1 {
    public static let G = ECPoint(
        x: U256(0x59F2_815B_16F8_1798, 0x029B_FCDB_2DCE_28D9,
                0x55A0_6295_CE87_0B07, 0x79BE_667E_F9DC_BBAC),
        y: U256(0x9C47_D08F_FB10_D4B8, 0xFD17_B448_A685_5419,
                0x5DA4_FBFC_0E11_08A8, 0x483A_DA77_26A3_C465))

    /// Comb table: comb[w][j] == j * 16^w * G, for the 64 nibbles of a scalar.
    /// 1024 points, built once (~70 KB), after which a scalar multiply costs
    /// 64 mixed additions and no doublings at all.
    private static let comb: [[ECPoint]] = {
        var table = [[ECPoint]](repeating: [], count: 64)
        var base = G
        for w in 0..<64 {
            var row = [ECPoint()]       // index 0 is the point at infinity
            var acc = Jacobian(base)
            row.append(base)
            for _ in 2...15 {
                acc = acc.adding(affine: base)
                row.append(acc.affine)
            }
            table[w] = row
            if w < 63 {
                var j = Jacobian(base)
                for _ in 0..<4 { j = j.doubled() }   // base *= 16
                base = j.affine
            }
        }
        return table
    }()

    /// k * G via the comb table. Roughly 8x faster than the plain ladder,
    /// which is what makes seeding tens of thousands of GPU threads instant.
    public static func multiplyG(_ k: U256) -> ECPoint {
        if k.isZero { return ECPoint() }
        var acc = Jacobian.infinity
        let words = [k.l0, k.l1, k.l2, k.l3]
        for wi in 0..<4 {
            let word = words[wi]
            for n in 0..<16 {
                let nibble = Int((word >> UInt64(4 * n)) & 0xF)
                if nibble == 0 { continue }
                acc = acc.adding(affine: comb[wi * 16 + n][nibble])
            }
        }
        return acc.affine
    }

    /// Straightforward, obviously-correct double-and-add. Used as the reference
    /// that `multiplyG` is checked against in the unit tests.
    public static func multiplyGReference(_ k: U256) -> ECPoint {
        var acc = Jacobian.infinity
        for i in stride(from: 255, through: 0, by: -1) {
            acc = acc.doubled()
            if k.bit(i) { acc = acc.adding(affine: G) }
        }
        return acc.affine
    }

    public static func add(_ a: ECPoint, _ b: ECPoint) -> ECPoint {
        Jacobian(a).adding(affine: b).affine
    }

    /// The table the kernel needs: 1G … (halfGroup)G plus the jump point.
    public static func buildGTable(halfGroup: Int) -> (points: [ECPoint], jump: ECPoint) {
        var pts: [ECPoint] = []
        pts.reserveCapacity(halfGroup)
        var acc = Jacobian(G)
        pts.append(G)
        for _ in 1..<halfGroup {
            acc = acc.adding(affine: G)
            pts.append(acc.affine)
        }
        let jump = multiplyGReference(U256(UInt64(2 * halfGroup + 1)))
        return (pts, jump)
    }

    /// 33-byte compressed public key.
    public static func compressedPubkey(_ p: ECPoint) -> [UInt8] {
        [0x02 + p.parity] + p.x.bigEndianBytes
    }

    /// 65-byte uncompressed public key.
    public static func uncompressedPubkey(_ p: ECPoint) -> [UInt8] {
        [0x04] + p.x.bigEndianBytes + p.y.bigEndianBytes
    }

    /// 64-byte raw public key (Ethereum form).
    public static func rawPubkey(_ p: ECPoint) -> [UInt8] {
        p.x.bigEndianBytes + p.y.bigEndianBytes
    }
}
