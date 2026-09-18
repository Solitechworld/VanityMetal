//
//  CoreTests.swift
//  VanityMetalCoreTests
//
//  Run with:  swift test
//
//  These are the tests that matter: if they pass, a key this app hands you is
//  a key that really controls the address it is shown next to.
//

import XCTest
@testable import VanityMetalCore

final class FieldTests: XCTestCase {

    func testU256HexRoundTrip() {
        let hex = "c0ffee0badcafe1234567890abcdef00112233445566778899aabbccddeeff01"
        let v = U256(hex: hex)
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.hexString, hex)
        XCTAssertEqual(U256(hex: "0x1")?.l0, 1)
        XCTAssertNil(U256(hex: "zz"))
    }

    func testMetalLimbRoundTrip() {
        let v = U256(hex: "0123456789abcdeffedcba98765432100011223344556677889900aabbccddee")!
        XCTAssertEqual(U256(metalLimbs: v.metalLimbs), v)
        XCTAssertEqual(v.bigEndianBytes.count, 32)
        XCTAssertEqual(U256(bigEndianBytes: v.bigEndianBytes), v)
    }

    func testFieldAddWrapsAtP() {
        let pMinus1 = U256.subb(Fp.p, U256(1)).0
        XCTAssertEqual(Fp.add(pMinus1, U256(2)), U256(1))
        XCTAssertEqual(Fp.add(pMinus1, U256(1)), U256.zero)
        XCTAssertEqual(Fp.sub(U256.zero, U256(1)), pMinus1)
    }

    func testInverseRoundTrips() {
        let samples = [U256(1), U256(2), U256(hex: "deadbeef")!,
                       Secp256k1.G.x, Secp256k1.G.y,
                       U256.subb(Fp.p, U256(1)).0]
        for a in samples {
            XCTAssertEqual(Fp.mul(a, Fp.inv(a)), U256(1), "inverse failed for \(a)")
        }
    }

    func testMultiplicationAgainstKnownProduct() {
        // (p-1)^2 mod p == 1
        let pMinus1 = U256.subb(Fp.p, U256(1)).0
        XCTAssertEqual(Fp.mul(pMinus1, pMinus1), U256(1))
        // 2^128 * 2^128 == 2^256 == 2^32 + 977 (mod p)
        let twoPow128 = U256(0, 0, 1, 0)
        XCTAssertEqual(Fp.mul(twoPow128, twoPow128), U256(0x1_0000_03D1))
    }
}

final class CurveTests: XCTestCase {

    func testGeneratorIsOnCurve() {
        // y^2 == x^3 + 7
        let g = Secp256k1.G
        let lhs = Fp.sqr(g.y)
        let rhs = Fp.add(Fp.mul(Fp.sqr(g.x), g.x), U256(7))
        XCTAssertEqual(lhs, rhs)
    }

    func testCombLadderMatchesReference() {
        var seed: UInt64 = 0x5EED
        func next() -> U256 {
            func mix() -> UInt64 {
                seed &+= 0x9E3779B97F4A7C15
                var z = seed
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return z ^ (z >> 31)
            }
            return U256(mix(), mix(), mix(), mix() >> 2)
        }
        for _ in 0..<12 {
            let k = next()
            XCTAssertEqual(Secp256k1.multiplyG(k), Secp256k1.multiplyGReference(k))
        }
    }

    func testGTableIsSuccessiveMultiples() {
        let (table, jump) = Secp256k1.buildGTable(halfGroup: KernelConstants.groupHalf)
        XCTAssertEqual(table.count, KernelConstants.groupHalf)
        XCTAssertEqual(table[0], Secp256k1.G)
        for i in 0..<table.count {
            XCTAssertEqual(table[i], Secp256k1.multiplyG(U256(UInt64(i + 1))),
                           "G table entry \(i) is wrong")
        }
        XCTAssertEqual(jump, Secp256k1.multiplyG(U256(UInt64(KernelConstants.groupSize))))
    }
}

final class HashTests: XCTestCase {

    func testSHA256Vector() {
        XCTAssertEqual(Hash.sha256(Array("abc".utf8)).hexString,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testRIPEMD160Vectors() {
        XCTAssertEqual(Hash.ripemd160([]).hexString,
                       "9c1185a5c5e9fc54612808977ee8f548b2258d31")
        XCTAssertEqual(Hash.ripemd160(Array("abc".utf8)).hexString,
                       "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")
        XCTAssertEqual(Hash.ripemd160(Array("message digest".utf8)).hexString,
                       "5d0689ef49d2fae572b881b123a85ffa21595f36")
        XCTAssertEqual(Hash.ripemd160([UInt8](repeating: 0, count: 32)).hexString,
                       "d1a70126ff7a149ca6f9b638db084480440ff842")
    }

    func testKeccak256Vectors() {
        XCTAssertEqual(Hash.keccak256(Array("abc".utf8)).hexString,
                       "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        XCTAssertEqual(Hash.keccak256([]).hexString,
                       "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        XCTAssertEqual(Hash.keccak256([UInt8](repeating: 0, count: 64)).hexString,
                       "ad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5")
    }
}

final class AddressTests: XCTestCase {

    /// One key, every address form, all cross-checked against values produced
    /// by an independent Python implementation.
    static let key = U256(hex: "c0ffee0badcafe1234567890abcdef00112233445566778899aabbccddeeff01")!

    func testKnownPublicKey() {
        let p = Secp256k1.multiplyG(Self.key)
        XCTAssertEqual(p.x.hexString, "d990d67c5805e94dc27e0d5e1916b4c1c33cbd7c7aabf196e65aec7941f0d7b2")
        XCTAssertEqual(p.y.hexString, "4b8e5593b47897e9ff3beb922e8553a780185097887d8895bc877866413989e4")
    }

    func testKnownAddresses() {
        let p = Secp256k1.multiplyG(Self.key)
        XCTAssertEqual(SearchController.address(for: p, kind: .p2pkhCompressed)?.address,
                       "1PTVvDsBpbbC2DEV8Mkwtj93v9RiTmvrso")
        XCTAssertEqual(SearchController.address(for: p, kind: .p2pkhUncompressed)?.address,
                       "16fb4BW1UZQKbK9wZ6SNS8ZnAdvU1G17JM")
        XCTAssertEqual(SearchController.address(for: p, kind: .p2sh)?.address,
                       "3LitrRHAS9yXwMfJssV5PDJViHKAuMzpmg")
        XCTAssertEqual(SearchController.address(for: p, kind: .bech32)?.address,
                       "bc1q7e2m3vdvt5phqtmjd9mwmh766vgkygmcpqejja")
        XCTAssertEqual(SearchController.address(for: p, kind: .eth)?.address,
                       "0x01f645F1D938010CdE1d3FD807880f916B36Cfb2")
    }

    func testWIF() {
        XCTAssertEqual(WIF.encode(Self.key, compressed: true),
                       "L3gspuyD5DkjReBoyX7bP8FY1aEtbDxX4E2JVawhA94xqMHU8BxW")
        XCTAssertEqual(WIF.encode(Self.key, compressed: false),
                       "5KHHVyrtg25UHTYuL9dqa7B6DN8E3md9AnzqpiDqySqvtP6246T")
    }

    func testBase58CheckRoundTrip() {
        let payload = [UInt8](repeating: 0xAB, count: 20)
        let s = Base58.checkEncode(version: 0x00, payload: payload)
        let decoded = Base58.checkDecode(s)
        XCTAssertEqual(decoded?.version, 0x00)
        XCTAssertEqual(decoded?.payload, payload)
        XCTAssertNil(Base58.checkDecode(String(s.dropLast()) + "Z"))
    }
}

final class TargetTests: XCTestCase {

    /// The property that has to hold: an address always falls inside the
    /// ranges built from its own prefix.
    func testAddressMatchesItsOwnPrefix() throws {
        for seed in 1...40 {
            let key = U256(UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 12345)
            let p = Secp256k1.multiplyG(key)
            for kind in [AddressKind.p2pkhCompressed, .p2sh, .bech32, .eth] {
                guard let built = SearchController.address(for: p, kind: kind) else { continue }
                let minLen = (kind == .bech32) ? 5 : (kind == .eth ? 4 : 3)
                for len in minLen...(minLen + 3) {
                    let prefix = String(built.address.prefix(len))
                    let target = try TargetParser.parse(prefix, forceKind: kind)
                    let hash = Self.hash(for: p, kind: kind)
                    XCTAssertTrue(target.ranges.contains { hashInRange(hash, $0) },
                                  "\(built.address) not matched by its own prefix \(prefix)")
                }
            }
        }
    }

    static func hash(for p: ECPoint, kind: AddressKind) -> [UInt8] {
        switch kind {
        case .p2pkhCompressed, .bech32: return Hash.hash160(Secp256k1.compressedPubkey(p))
        case .p2pkhUncompressed: return Hash.hash160(Secp256k1.uncompressedPubkey(p))
        case .p2sh: return Hash.hash160([0x00, 0x14] + Hash.hash160(Secp256k1.compressedPubkey(p)))
        case .eth: return Array(Hash.keccak256(Secp256k1.rawPubkey(p))[12...])
        }
    }

    func testDifficultyOfBitAlignedPrefixes() throws {
        // Bech32 and hex prefixes are exactly bit-aligned, so their difficulty
        // must come out as a clean power.
        let bech = try TargetParser.parse("bc1qne0n", forceKind: .bech32)
        XCTAssertEqual(bech.difficulty, pow(32.0, 4.0), accuracy: 1.0)
        let eth = try TargetParser.parse("0xdecaf", forceKind: .eth)
        XCTAssertEqual(eth.difficulty, pow(16.0, 5.0), accuracy: 1.0)
    }

    func testBase58DifficultyIsNotNaive() throws {
        // "1A" is roughly 2.5x easier than the usual 58^1 estimate, because the
        // second character of a Base58 address is not uniformly distributed.
        let t = try TargetParser.parse("1A")
        XCTAssertLessThan(t.difficulty, 58.0)
        XCTAssertGreaterThan(t.difficulty, 10.0)
    }

    func testImpossiblePrefixesAreRejected() {
        XCTAssertThrowsError(try TargetParser.parse("2abc", forceKind: .p2pkhCompressed))
        XCTAssertThrowsError(try TargetParser.parse("1abc", forceKind: .p2sh))
        XCTAssertThrowsError(try TargetParser.parse("1IOl"))          // not Base58
        XCTAssertThrowsError(try TargetParser.parse("bc1qb"))         // 'b' not in Bech32
    }

    func testBareOnesPrefixAcceptsEverything() throws {
        let t = try TargetParser.parse("1")
        XCTAssertTrue(t.ranges.contains { hashInRange([UInt8](repeating: 0, count: 20), $0) })
        XCTAssertTrue(t.ranges.contains { hashInRange([UInt8](repeating: 0xFF, count: 20), $0) })
    }
}

final class EngineTests: XCTestCase {

    /// End to end on the CPU engine: hunt a deliberately easy prefix and check
    /// the key it returns really produces that address.
    func testCPUEngineFindsAndKeysAreCorrect() throws {
        let target = try TargetParser.parse("1A", forceKind: .p2pkhCompressed)
        let engine = CPUEngine()
        engine.prepare(targets: target.ranges, threadCount: 2)

        var found = 0
        for _ in 0..<40 {
            let (hits, scanned) = engine.run(iterations: 4)
            XCTAssertEqual(scanned, 2 * 4 * UInt64(KernelConstants.groupSize))
            for hit in hits {
                guard let key = engine.privateKey(for: hit) else {
                    XCTFail("hit could not be traced to a key"); continue
                }
                let p = Secp256k1.multiplyG(key)
                guard let built = SearchController.address(for: p, kind: hit.kind) else { continue }
                XCTAssertTrue(built.address.hasPrefix("1A"),
                              "engine returned \(built.address) for prefix 1A")
                XCTAssertEqual(TargetTests.hash(for: p, kind: hit.kind), hit.hash,
                               "reported hash does not match the re-derived one")
                found += 1
            }
            if found > 3 { break }
        }
        XCTAssertGreaterThan(found, 0, "no hits at difficulty ~23 after 40k keys")
    }

    /// The walk must cover a contiguous block of keys with no gaps and no
    /// repeats — that is what makes the search exhaustive rather than random.
    func testWalkCoversContiguousKeys() {
        let engine = CPUEngine()
        // A range that matches everything, so every generated key is reported.
        let all = HashRange(lo: [UInt8](repeating: 0, count: 20),
                            hi: [UInt8](repeating: 0xFF, count: 20),
                            kind: .p2pkhCompressed)
        engine.prepare(targets: [all], threadCount: 1)
        let start = engine.startKeys[0]
        let (hits, _) = engine.run(iterations: 3)
        XCTAssertEqual(hits.count, 3 * KernelConstants.groupSize)

        var keys = Set<String>()
        for hit in hits {
            guard let k = engine.privateKey(for: hit) else { continue }
            keys.insert(k.hexString)
        }
        XCTAssertEqual(keys.count, 3 * KernelConstants.groupSize, "the walk repeated a key")

        // Every key must lie in [start - 64, start - 64 + 3*129).
        let half = UInt64(KernelConstants.groupHalf)
        let low = Fn.sub(start, U256(half))
        var expected = Set<String>()
        var cursor = low
        for _ in 0..<(3 * KernelConstants.groupSize) {
            expected.insert(cursor.hexString)
            cursor = Fn.add(cursor, U256(1))
        }
        XCTAssertEqual(keys, expected, "the walk left gaps in the key space")
    }
}
