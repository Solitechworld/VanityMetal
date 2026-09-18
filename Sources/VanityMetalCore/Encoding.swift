//
//  Encoding.swift
//  VanityMetal
//
//  Base58 / Base58Check, Bech32 (BIP-173), WIF and EIP-55 helpers.
//

import Foundation

public enum Base58 {
    public static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let index: [Character: Int] = {
        var m = [Character: Int]()
        for (i, c) in alphabet.enumerated() { m[c] = i }
        return m
    }()

    public static func value(of c: Character) -> Int? { index[c] }

    public static func encode(_ data: [UInt8]) -> String {
        var zeros = 0
        while zeros < data.count && data[zeros] == 0 { zeros += 1 }
        var digits: [UInt8] = []
        for byte in data[zeros...] {
            var carry = Int(byte)
            for i in 0..<digits.count {
                carry += Int(digits[i]) << 8
                digits[i] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        var out = String(repeating: "1", count: zeros)
        for d in digits.reversed() { out.append(alphabet[Int(d)]) }
        return out
    }

    public static func decode(_ s: String) -> [UInt8]? {
        var zeros = 0
        let chars = Array(s)
        while zeros < chars.count && chars[zeros] == "1" { zeros += 1 }
        var bytes: [UInt8] = []
        for c in chars[zeros...] {
            guard let v = index[c] else { return nil }
            var carry = v
            for i in 0..<bytes.count {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xFF))
                carry >>= 8
            }
        }
        return [UInt8](repeating: 0, count: zeros) + bytes.reversed()
    }

    public static func checkEncode(version: UInt8, payload: [UInt8]) -> String {
        let body = [version] + payload
        let checksum = Array(Hash.sha256d(body)[0..<4])
        return encode(body + checksum)
    }

    public static func checkDecode(_ s: String) -> (version: UInt8, payload: [UInt8])? {
        guard let raw = decode(s), raw.count >= 5 else { return nil }
        let body = Array(raw[0..<(raw.count - 4)])
        let checksum = Array(raw[(raw.count - 4)...])
        guard Array(Hash.sha256d(body)[0..<4]) == checksum else { return nil }
        return (body[0], Array(body[1...]))
    }
}

public enum Bech32 {
    public static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let charIndex: [Character: Int] = {
        var m = [Character: Int]()
        for (i, c) in charset.enumerated() { m[c] = i }
        return m
    }()

    public static func value(of c: Character) -> Int? { charIndex[c] }

    private static func polymod(_ values: [Int]) -> Int {
        let gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk = 1
        for v in values {
            let b = chk >> 25
            chk = ((chk & 0x1ffffff) << 5) ^ v
            for i in 0..<5 where (b >> i) & 1 == 1 { chk ^= gen[i] }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [Int] {
        let s = Array(hrp.unicodeScalars).map { Int($0.value) }
        return s.map { $0 >> 5 } + [0] + s.map { $0 & 31 }
    }

    private static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0, bits = 0
        var out: [UInt8] = []
        let maxv = (1 << to) - 1
        for value in data {
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((acc << (to - bits)) & maxv)) }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        return out
    }

    /// Segwit v0 address (P2WPKH when `program` is a 20-byte hash160).
    public static func encodeSegwit(hrp: String, witnessVersion: Int, program: [UInt8]) -> String? {
        guard let converted = convertBits(program, from: 8, to: 5, pad: true) else { return nil }
        let data = [UInt8(witnessVersion)] + converted
        let values = hrpExpand(hrp) + data.map { Int($0) }
        let mod = polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1
        var checksum: [Int] = []
        for i in 0..<6 { checksum.append((mod >> (5 * (5 - i))) & 31) }
        let body = data.map { charset[Int($0)] } + checksum.map { charset[$0] }
        return hrp + "1" + String(body)
    }
}

public enum WIF {
    /// Wallet Import Format private key.
    public static func encode(_ key: U256, compressed: Bool, testnet: Bool = false) -> String {
        var payload = key.bigEndianBytes
        if compressed { payload.append(0x01) }
        return Base58.checkEncode(version: testnet ? 0xEF : 0x80, payload: payload)
    }
}

public enum EIP55 {
    /// Checksummed Ethereum address ("0x" + mixed-case hex).
    public static func encode(_ address20: [UInt8]) -> String {
        let lower = address20.map { String(format: "%02x", $0) }.joined()
        let hash = Hash.keccak256(Array(lower.utf8))
        var out = "0x"
        for (i, ch) in lower.enumerated() {
            let nibble = (hash[i / 2] >> (i % 2 == 0 ? 4 : 0)) & 0xF
            out.append(nibble >= 8 ? Character(ch.uppercased()) : ch)
        }
        return out
    }
}

public extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        var s = hexString
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
        guard s.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }
}
