//
//  Hashing.swift
//  VanityMetal
//
//  SHA-256 comes from CryptoKit. RIPEMD-160 and Keccak-256 are implemented
//  here because Apple ships neither, and pulling in a dependency would break
//  the "standalone, no external anything" requirement.
//

import Foundation
import CryptoKit

public enum Hash {

    // MARK: SHA-256

    public static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(CryptoKit.SHA256.hash(data: Data(data)))
    }

    public static func sha256d(_ data: [UInt8]) -> [UInt8] {
        sha256(sha256(data))
    }

    // MARK: RIPEMD-160

    private static let rl: [Int] = [
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
        7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8,
        3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12,
        1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2,
        4,0,5,9,7,12,2,10,14,1,3,8,11,6,15,13]
    private static let rr: [Int] = [
        5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12,
        6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2,
        15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13,
        8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14,
        12,15,10,4,1,5,8,7,6,2,13,14,0,3,9,11]
    private static let sl: [UInt32] = [
        11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8,
        7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12,
        11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5,
        11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12,
        9,15,5,11,6,8,13,12,5,12,13,14,11,8,5,6]
    private static let sr: [UInt32] = [
        8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6,
        9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11,
        9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5,
        15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8,
        8,5,12,9,12,5,14,6,8,13,6,5,15,13,11,11]
    private static let kl: [UInt32] = [0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E]
    private static let kr: [UInt32] = [0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000]

    @inline(__always)
    private static func rol(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }

    @inline(__always)
    private static func rf(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j {
        case ..<16: return x ^ y ^ z
        case ..<32: return (x & y) | (~x & z)
        case ..<48: return (x | ~y) ^ z
        case ..<64: return (x & z) | (y & ~z)
        default:    return x ^ (y | ~z)
        }
    }

    public static func ripemd160(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var msg = message
        let bitLen = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8((bitLen >> (8 * UInt64(i))) & 0xFF)) }

        var w = [UInt32](repeating: 0, count: 16)
        var offset = 0
        while offset < msg.count {
            for i in 0..<16 {
                let o = offset + i * 4
                w[i] = UInt32(msg[o]) | (UInt32(msg[o + 1]) << 8)
                     | (UInt32(msg[o + 2]) << 16) | (UInt32(msg[o + 3]) << 24)
            }
            var al = h[0], bl = h[1], cl = h[2], dl = h[3], el = h[4]
            var ar = h[0], br = h[1], cr = h[2], dr = h[3], er = h[4]
            for j in 0..<80 {
                let round = j >> 4
                var t = rol(al &+ rf(j, bl, cl, dl) &+ w[rl[j]] &+ kl[round], sl[j]) &+ el
                al = el; el = dl; dl = rol(cl, 10); cl = bl; bl = t
                t = rol(ar &+ rf(79 - j, br, cr, dr) &+ w[rr[j]] &+ kr[round], sr[j]) &+ er
                ar = er; er = dr; dr = rol(cr, 10); cr = br; br = t
            }
            let tmp = h[1] &+ cl &+ dr
            h[1] = h[2] &+ dl &+ er
            h[2] = h[3] &+ el &+ ar
            h[3] = h[4] &+ al &+ br
            h[4] = h[0] &+ bl &+ cr
            h[0] = tmp
            offset += 64
        }

        var out = [UInt8](); out.reserveCapacity(20)
        for v in h { for i in 0..<4 { out.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        return out
    }

    /// RIPEMD160(SHA256(x)) — the Bitcoin HASH160.
    public static func hash160(_ data: [UInt8]) -> [UInt8] {
        ripemd160(sha256(data))
    }

    // MARK: Keccak-256

    private static let keccakRC: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
    private static let keccakRot: [UInt64] = [
        1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44]
    private static let keccakPil: [Int] = [
        10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1]

    @inline(__always)
    private static func rol64(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }

    private static func keccakF(_ a: inout [UInt64]) {
        for round in 0..<24 {
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 { c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ rol64(c[(x + 1) % 5], 1)
                for y in stride(from: 0, to: 25, by: 5) { a[x + y] ^= d }
            }
            var t = a[1]
            for i in 0..<24 {
                let j = keccakPil[i]
                let bc = a[j]
                a[j] = rol64(t, keccakRot[i])
                t = bc
            }
            for y in stride(from: 0, to: 25, by: 5) {
                let tv = Array(a[y..<(y + 5)])
                for x in 0..<5 { a[y + x] = tv[x] ^ (~tv[(x + 1) % 5] & tv[(x + 2) % 5]) }
            }
            a[0] ^= keccakRC[round]
        }
    }

    public static func keccak256(_ message: [UInt8]) -> [UInt8] {
        let rate = 136
        var a = [UInt64](repeating: 0, count: 25)
        var padded = message
        padded.append(0x01)
        while padded.count % rate != 0 { padded.append(0) }
        padded[padded.count - 1] |= 0x80

        var offset = 0
        while offset < padded.count {
            for i in 0..<(rate / 8) {
                var lane: UInt64 = 0
                for b in 0..<8 { lane |= UInt64(padded[offset + i * 8 + b]) << (8 * UInt64(b)) }
                a[i] ^= lane
            }
            keccakF(&a)
            offset += rate
        }

        var out = [UInt8](); out.reserveCapacity(32)
        for i in 0..<4 {
            for b in 0..<8 { out.append(UInt8((a[i] >> (8 * UInt64(b))) & 0xFF)) }
        }
        return out
    }
}
