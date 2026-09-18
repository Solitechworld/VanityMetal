//
//  main.swift
//  VanityMetalVerify
//
//  A self-contained verification run that needs no XCTest, so it works with a
//  plain Command Line Tools install. It repeats the unit-test coverage and then
//  does the check that matters most: it runs the Metal kernel and the CPU
//  engine over the *same* seeded key range and confirms they report byte-for-byte
//  identical results.
//
//      swift run -c release VanityMetalVerify
//

import Foundation
import Metal
import VanityMetalCore

var checksRun = 0
var failures: [String] = []

let bold = "\u{1B}[1m", dim = "\u{1B}[2m", cyan = "\u{1B}[36m"
let green = "\u{1B}[32m", red = "\u{1B}[31m", off = "\u{1B}[0m"

func section(_ title: String) {
    print("\n\(cyan)\(bold)▸ \(title)\(off)")
}

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    checksRun += 1
    let mark = ok ? "\(green)  PASS\(off)" : "\(red)  FAIL\(off)"
    let tail = extra.isEmpty ? "" : "  \(dim)\(extra)\(off)"
    print("\(mark)  \(name)\(tail)")
    if !ok { failures.append(name) }
}

func info(_ text: String) { print("        \(dim)\(text)\(off)") }

print("\(bold)VanityMetal verification\(off)")

// ===========================================================================
section("Field arithmetic, p = 2^256 - 2^32 - 977")

let hexRT = "c0ffee0badcafe1234567890abcdef00112233445566778899aabbccddeeff01"
check("U256 hex round trip", U256(hex: hexRT)?.hexString == hexRT)
check("U256 rejects non-hex", U256(hex: "zz") == nil)

let sample = U256(hex: "0123456789abcdeffedcba98765432100011223344556677889900aabbccddee")!
check("metal limb round trip", U256(metalLimbs: sample.metalLimbs) == sample)
check("big-endian byte round trip", U256(bigEndianBytes: sample.bigEndianBytes) == sample)

let pMinus1 = U256.subb(Fp.p, U256(1)).0
check("(p-1) + 2 == 1", Fp.add(pMinus1, U256(2)) == U256(1))
check("(p-1) + 1 == 0", Fp.add(pMinus1, U256(1)) == U256.zero)
check("0 - 1 == p-1", Fp.sub(U256.zero, U256(1)) == pMinus1)
check("(p-1)^2 == 1", Fp.mul(pMinus1, pMinus1) == U256(1))
let twoPow128 = U256(0, 0, 1, 0)
check("2^128 * 2^128 == 2^32 + 977", Fp.mul(twoPow128, twoPow128) == U256(0x1_0000_03D1))

var invOK = true
for a in [U256(1), U256(2), U256(hex: "deadbeef")!, Secp256k1.G.x, Secp256k1.G.y, pMinus1] {
    if Fp.mul(a, Fp.inv(a)) != U256(1) { invOK = false }
}
check("modular inverse round trips (addition chain)", invOK)

// A deterministic sweep, so this is not just six lucky values.
var rngState: UInt64 = 0x5EED_C0DE
func nextWord() -> UInt64 {
    rngState &+= 0x9E37_79B9_7F4A_7C15
    var z = rngState
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}
func nextField() -> U256 { Fp.condSubP(U256(nextWord(), nextWord(), nextWord(), nextWord() >> 1)) }

var sweepOK = true
for _ in 0..<2000 {
    let a = nextField(), b = nextField()
    // (a+b)*(a-b) == a^2 - b^2 is a cheap identity that exercises every path.
    let lhs = Fp.mul(Fp.add(a, b), Fp.sub(a, b))
    let rhs = Fp.sub(Fp.sqr(a), Fp.sqr(b))
    if lhs != rhs { sweepOK = false; break }
    if !a.isZero && Fp.mul(a, Fp.inv(a)) != U256(1) { sweepOK = false; break }
}
check("2000 random elements satisfy (a+b)(a-b) == a²-b² and a·a⁻¹ == 1", sweepOK)

// ===========================================================================
section("Curve")

let g = Secp256k1.G
check("generator satisfies y² = x³ + 7",
      Fp.sqr(g.y) == Fp.add(Fp.mul(Fp.sqr(g.x), g.x), U256(7)))

var ladderOK = true
for _ in 0..<10 {
    let k = U256(nextWord(), nextWord(), nextWord(), nextWord() >> 2)
    if Secp256k1.multiplyG(k) != Secp256k1.multiplyGReference(k) { ladderOK = false; break }
}
check("comb ladder matches plain double-and-add", ladderOK)

let (gtab, jump) = Secp256k1.buildGTable(halfGroup: KernelConstants.groupHalf)
var tableOK = gtab.count == KernelConstants.groupHalf
for i in 0..<gtab.count where tableOK {
    if gtab[i] != Secp256k1.multiplyG(U256(UInt64(i + 1))) { tableOK = false }
}
check("G table holds 1G … \(KernelConstants.groupHalf)G", tableOK)
check("jump point is \(KernelConstants.groupSize)G",
      jump == Secp256k1.multiplyG(U256(UInt64(KernelConstants.groupSize))))

// ===========================================================================
section("Hashes")

check("sha256(\"abc\")",
      Hash.sha256(Array("abc".utf8)).hexString ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("ripemd160(\"\")",
      Hash.ripemd160([]).hexString == "9c1185a5c5e9fc54612808977ee8f548b2258d31")
check("ripemd160(\"abc\")",
      Hash.ripemd160(Array("abc".utf8)).hexString == "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")
check("ripemd160(\"message digest\")",
      Hash.ripemd160(Array("message digest".utf8)).hexString == "5d0689ef49d2fae572b881b123a85ffa21595f36")
check("ripemd160(00 × 32)",
      Hash.ripemd160([UInt8](repeating: 0, count: 32)).hexString == "d1a70126ff7a149ca6f9b638db084480440ff842")
check("keccak256(\"\")",
      Hash.keccak256([]).hexString == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
check("keccak256(\"abc\")",
      Hash.keccak256(Array("abc".utf8)).hexString ==
      "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
check("keccak256(00 × 64)",
      Hash.keccak256([UInt8](repeating: 0, count: 64)).hexString ==
      "ad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5")

// ===========================================================================
section("Addresses for a known key")

let knownKey = U256(hex: "c0ffee0badcafe1234567890abcdef00112233445566778899aabbccddeeff01")!
let knownPoint = Secp256k1.multiplyG(knownKey)
check("public key X",
      knownPoint.x.hexString == "d990d67c5805e94dc27e0d5e1916b4c1c33cbd7c7aabf196e65aec7941f0d7b2")
check("public key Y",
      knownPoint.y.hexString == "4b8e5593b47897e9ff3beb922e8553a780185097887d8895bc877866413989e4")

let expected: [(AddressKind, String)] = [
    (.p2pkhCompressed,   "1PTVvDsBpbbC2DEV8Mkwtj93v9RiTmvrso"),
    (.p2pkhUncompressed, "16fb4BW1UZQKbK9wZ6SNS8ZnAdvU1G17JM"),
    (.p2sh,              "3LitrRHAS9yXwMfJssV5PDJViHKAuMzpmg"),
    (.bech32,            "bc1q7e2m3vdvt5phqtmjd9mwmh766vgkygmcpqejja"),
    (.eth,               "0x01f645F1D938010CdE1d3FD807880f916B36Cfb2")
]
for (kind, want) in expected {
    let got = SearchController.address(for: knownPoint, kind: kind)?.address ?? "<nil>"
    check("\(kind.shortTitle) address", got == want, got == want ? "" : "got \(got)")
}
check("WIF (compressed)",
      WIF.encode(knownKey, compressed: true) == "L3gspuyD5DkjReBoyX7bP8FY1aEtbDxX4E2JVawhA94xqMHU8BxW")
check("WIF (uncompressed)",
      WIF.encode(knownKey, compressed: false) == "5KHHVyrtg25UHTYuL9dqa7B6DN8E3md9AnzqpiDqySqvtP6246T")

let payload = [UInt8](repeating: 0xAB, count: 20)
let encoded = Base58.checkEncode(version: 0x00, payload: payload)
check("Base58Check round trip", Base58.checkDecode(encoded)?.payload == payload)
check("Base58Check rejects a corrupted checksum",
      Base58.checkDecode(String(encoded.dropLast()) + "Z") == nil)

// ===========================================================================
section("Prefix targets")

func hash(for p: ECPoint, kind: AddressKind) -> [UInt8] {
    switch kind {
    case .p2pkhCompressed, .bech32: return Hash.hash160(Secp256k1.compressedPubkey(p))
    case .p2pkhUncompressed:        return Hash.hash160(Secp256k1.uncompressedPubkey(p))
    case .p2sh:  return Hash.hash160([0x00, 0x14] + Hash.hash160(Secp256k1.compressedPubkey(p)))
    case .eth:   return Array(Hash.keccak256(Secp256k1.rawPubkey(p))[12...])
    }
}

var roundTripMisses = 0
var roundTripTried = 0
for seed in 1...60 {
    let k = U256(UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 12_345)
    let p = Secp256k1.multiplyG(k)
    for kind in [AddressKind.p2pkhCompressed, .p2sh, .bech32, .eth] {
        guard let built = SearchController.address(for: p, kind: kind) else { continue }
        let minLen = (kind == .bech32) ? 5 : (kind == .eth ? 4 : 3)
        for len in minLen...(minLen + 3) {
            let prefix = String(built.address.prefix(len))
            guard let target = try? TargetParser.parse(prefix, forceKind: kind) else {
                roundTripMisses += 1; continue
            }
            let h = hash(for: p, kind: kind)
            roundTripTried += 1
            if !target.ranges.contains(where: { hashInRange(h, $0) }) { roundTripMisses += 1 }
        }
    }
}
check("every address falls inside the ranges built from its own prefix",
      roundTripMisses == 0, "\(roundTripTried) prefixes tested")

if let bech = try? TargetParser.parse("bc1qne0n", forceKind: .bech32) {
    check("bech32 'bc1qne0n' difficulty is exactly 32⁴",
          abs(bech.difficulty - pow(32.0, 4.0)) < 1.0,
          String(format: "%.0f", bech.difficulty))
} else { check("bech32 prefix parses", false) }

if let eth = try? TargetParser.parse("0xdecaf", forceKind: .eth) {
    check("eth '0xdecaf' difficulty is exactly 16⁵",
          abs(eth.difficulty - pow(16.0, 5.0)) < 1.0,
          String(format: "%.0f", eth.difficulty))
} else { check("eth prefix parses", false) }

if let t = try? TargetParser.parse("1A") {
    check("Base58 difficulty is the true one, not 58ⁿ",
          t.difficulty < 58.0 && t.difficulty > 10.0,
          String(format: "1 in %.2f (naive would say 58)", t.difficulty))
} else { check("'1A' parses", false) }

check("a P2PKH prefix not starting with 1 is rejected",
      (try? TargetParser.parse("2abc", forceKind: .p2pkhCompressed)) == nil)
check("a P2SH prefix starting with 1 is rejected",
      (try? TargetParser.parse("1abc", forceKind: .p2sh)) == nil)
check("non-Base58 characters are rejected",
      (try? TargetParser.parse("1IOl")) == nil)
if let bare = try? TargetParser.parse("1") {
    check("'1' alone accepts every P2PKH hash",
          bare.ranges.contains { hashInRange([UInt8](repeating: 0, count: 20), $0) } &&
          bare.ranges.contains { hashInRange([UInt8](repeating: 0xFF, count: 20), $0) })
} else { check("'1' parses", false) }

// ===========================================================================
section("CPU engine")

let everything = HashRange(lo: [UInt8](repeating: 0, count: 20),
                           hi: [UInt8](repeating: 0xFF, count: 20),
                           kind: .p2pkhCompressed)
let walkEngine = CPUEngine()
walkEngine.prepare(targets: [everything], threadCount: 1)
let walkStart = walkEngine.startKeys[0]
let walkRun = walkEngine.run(iterations: 3)
check("3 batches produce exactly 3 × \(KernelConstants.groupSize) keys",
      walkRun.hits.count == 3 * KernelConstants.groupSize, "\(walkRun.hits.count)")

var walked = Set<String>()
for hit in walkRun.hits { if let k = walkEngine.privateKey(for: hit) { walked.insert(k.hexString) } }
var wanted = Set<String>()
var cursor = Fn.sub(walkStart, U256(UInt64(KernelConstants.groupHalf)))
for _ in 0..<(3 * KernelConstants.groupSize) {
    wanted.insert(cursor.hexString)
    cursor = Fn.add(cursor, U256(1))
}
check("the walk covers a contiguous key range with no gaps or repeats", walked == wanted)

var derivedOK = true
for hit in walkRun.hits.prefix(40) {
    guard let k = walkEngine.privateKey(for: hit) else { derivedOK = false; break }
    if hash(for: Secp256k1.multiplyG(k), kind: .p2pkhCompressed) != hit.hash { derivedOK = false; break }
}
check("reported hashes match keys re-derived from scratch", derivedOK)

// ===========================================================================
section("GPU kernel")

if let device = MetalEngine.device(matching: nil) {
    info("device: \(device.name)")
    do {
        let started = Date()
        let engine = try MetalEngine(device: device)
        info(String(format: "kernels compiled in %.2fs", Date().timeIntervalSince(started)))

        try engine.runSelfTest()
        check("GPU known-answer tests (field, inverse, SHA-256, RIPEMD-160, Keccak-256)", true)

        // Accept hashes whose first byte is zero: about 1 in 256, so a couple of
        // hundred hits — enough to compare, small enough to fit the buffer.
        var hi = [UInt8](repeating: 0xFF, count: 20)
        hi[0] = 0x00
        let narrow = HashRange(lo: [UInt8](repeating: 0, count: 20), hi: hi, kind: .p2pkhCompressed)
        let sharedSeed = U256(hex: "0badc0de00000000feedface000000001234567800000000abcdef0000000001")!

        try engine.prepare(targets: [narrow], threadCount: 256, seed: sharedSeed)
        let threads = engine.threadCount
        let cpu = CPUEngine()
        cpu.prepare(targets: [narrow], threadCount: threads, seed: sharedSeed)

        check("both engines started from the same keys", engine.startKeys == cpu.startKeys)

        func fingerprint(_ h: RawHit) -> String {
            "\(h.threadId)|\(h.offset)|\(h.iteration)|\(h.hash.hexString)"
        }
        func report(_ label: String, _ gset: Set<String>, _ cset: Set<String>) {
            check(label, gset == cset && !gset.isEmpty,
                  "GPU \(gset.count), CPU \(cset.count), shared \(gset.intersection(cset).count)")
            if gset != cset {
                for m in cset.subtracting(gset).sorted().prefix(2) { info("CPU only: \(m)") }
                for m in gset.subtracting(cset).sorted().prefix(2) { info("GPU only: \(m)") }
            }
        }

        // --- seeding: does the GPU start where we think it does? ------------
        let seeded = engine.currentPoints
        var seedMismatch = 0
        for t in 0..<threads where seeded[t] != Secp256k1.multiplyG(engine.startKeys[t]) {
            seedMismatch += 1
        }
        check("GPU start points equal startKey · G", seedMismatch == 0,
              seedMismatch == 0 ? "" : "\(seedMismatch)/\(threads) wrong")

        // --- is the G table intact as the kernel sees it? -------------------
        // Note: "advance by 129" below would pass even if this table were pure
        // garbage, because the jump's 1/dx falls out of the batch inversion
        // whatever the other denominators are. So test the table directly.
        if let dumped = engine.dumpTableEntry(index: 0) {
            check("G table entry 0 reaches the GPU as 1·G", dumped.g == Secp256k1.G,
                  dumped.g == Secp256k1.G ? "" : "x=\(dumped.g.x.hexString)")
            check("jump point reaches the GPU as \(KernelConstants.groupSize)·G",
                  dumped.jump == Secp256k1.multiplyG(U256(UInt64(KernelConstants.groupSize))))
        }
        if let dumped = engine.dumpTableEntry(index: KernelConstants.groupHalf - 1) {
            let want = Secp256k1.multiplyG(U256(UInt64(KernelConstants.groupHalf)))
            check("G table entry \(KernelConstants.groupHalf - 1) reaches the GPU as \(KernelConstants.groupHalf)·G",
                  dumped.g == want,
                  dumped.g == want ? "" : "x=\(dumped.g.x.hexString)")
        }

        // --- exhaustive: one walker, one batch, every offset checked --------
        let everythingRange = HashRange(lo: [UInt8](repeating: 0, count: 20),
                                        hi: [UInt8](repeating: 0xFF, count: 20),
                                        kind: .p2pkhCompressed)
        try engine.prepare(targets: [everythingRange], threadCount: 1, seed: sharedSeed)
        let solo = try engine.run(iterations: 1)
        check("one walker, one batch reports all \(KernelConstants.groupSize) keys",
              solo.hits.count == KernelConstants.groupSize, "\(solo.hits.count)")

        let k0 = engine.startKeys[0]
        func h160(_ offset: Int) -> [UInt8] {
            hash(for: Secp256k1.multiplyG(Fn.addOffset(k0, Int64(offset))), kind: .p2pkhCompressed)
        }
        var wrong: [Int] = []
        for hit in solo.hits where h160(hit.offset) != hit.hash { wrong.append(hit.offset) }
        let wrongList = wrong.sorted().prefix(8).map(String.init).joined(separator: ", ")
        check("every offset in a batch maps to the right key", wrong.isEmpty,
              wrong.isEmpty ? "" : "\(wrong.count)/\(solo.hits.count) wrong, first few: " + wrongList)

        if !wrong.isEmpty {
            // Work out what the GPU actually computed, so the pattern is obvious.
            var table: [String] = []
            for probe in wrong.sorted().prefix(6) {
                guard let hit = solo.hits.first(where: { $0.offset == probe }) else { continue }
                var actual = "not any offset in ±200"
                for d in -200...200 where h160(d) == hit.hash { actual = "offset \(d)"; break }
                table.append("reported \(probe) → actually \(actual)")
            }
            for line in table { info(line) }
            let rightCount = solo.hits.count - wrong.count
            info("\(rightCount) of \(solo.hits.count) offsets were correct")
            let good = solo.hits.filter { h160($0.offset) == $0.hash }.map { $0.offset }.sorted()
            let goodList = good.prefix(20).map(String.init).joined(separator: ", ")
            info("correct offsets: " + goodList)
        }

        // rebuild the 1-in-256 setup for the comparison checks below
        try engine.prepare(targets: [narrow], threadCount: 256, seed: sharedSeed)

        // --- one batch: exercises the ± point generation, not the jump ------
        let g1 = try engine.run(iterations: 1)
        let c1 = cpu.run(iterations: 1)
        report("batch 0 — GPU and CPU report identical hits",
               Set(g1.hits.map(fingerprint)), Set(c1.hits.map(fingerprint)))

        // --- the advance: did the walk land on startKey + 129? --------------
        let advanced = engine.currentPoints
        var jumpMismatch = 0
        var firstBad = -1
        for t in 0..<threads {
            let want = Secp256k1.multiplyG(Fn.add(engine.startKeys[t],
                                                  U256(UInt64(KernelConstants.groupSize))))
            if advanced[t] != want {
                jumpMismatch += 1
                if firstBad < 0 { firstBad = t }
            }
        }
        check("the GPU walk advances by exactly \(KernelConstants.groupSize) keys",
              jumpMismatch == 0,
              jumpMismatch == 0 ? "" : "\(jumpMismatch)/\(threads) walkers landed elsewhere")
        if firstBad >= 0 {
            let want = Secp256k1.multiplyG(Fn.add(engine.startKeys[firstBad],
                                                  U256(UInt64(KernelConstants.groupSize))))
            info("walker \(firstBad) start  x=\(Secp256k1.multiplyG(engine.startKeys[firstBad]).x.hexString)")
            info("walker \(firstBad) wanted x=\(want.x.hexString)")
            info("walker \(firstBad) got    x=\(advanced[firstBad].x.hexString)")
            // Is it perhaps a different, still-valid multiple of G?
            var found = "not a small multiple of the start point"
            for delta in [-2, -1, 1, 2, 63, 64, 65, 127, 128, 129, 130, 192, 256, 258] {
                let cand = Secp256k1.multiplyG(Fn.addOffset(engine.startKeys[firstBad], Int64(delta)))
                if cand == advanced[firstBad] { found = "it is start + \(delta)" ; break }
            }
            info("diagnosis: \(found)")
        }

        // --- second batch, which depends on the advance ---------------------
        let g2 = try engine.run(iterations: 1)
        let c2 = cpu.run(iterations: 1)
        report("batch 1 — GPU and CPU report identical hits",
               Set(g2.hits.map(fingerprint)), Set(c2.hits.map(fingerprint)))

        info("\(threads) walkers × 2 steps = \(g1.keysScanned &+ g2.keysScanned) keys on each engine")

        var gpuKeysOK = !g1.hits.isEmpty
        for hit in (g1.hits + g2.hits).prefix(25) {
            guard let k = engine.privateKey(for: hit),
                  hash(for: Secp256k1.multiplyG(k), kind: .p2pkhCompressed) == hit.hash
            else { gpuKeysOK = false; break }
        }
        check("GPU hits re-derive to the right private keys", gpuKeysOK)

        // Throughput at a realistic walker count. The comparisons above used
        // 256 walkers so the result buffer stayed small; that is nowhere near
        // enough to saturate a GPU, so measure again at the real default.
        var impossible = [UInt8](repeating: 0, count: 20)
        for i in 0..<20 { impossible[i] = UInt8.random(in: 0...255) }
        let never = HashRange(lo: impossible, hi: impossible, kind: .p2pkhCompressed)

        for walkers in [1024, 4096, engine.suggestedThreadCount] {
            try engine.prepare(targets: [never], threadCount: walkers)
            // Size each dispatch to roughly 100 ms, measured rather than
            // guessed, so a slow GPU never sits in one uninterruptible kernel.
            let probeStart = Date()
            _ = try engine.run(iterations: 1)
            let probe = max(Date().timeIntervalSince(probeStart), 0.0002)
            let iters = max(1, min(engine.maxIterationsPerDispatch, Int(0.1 / probe)))

            let benchStart = Date()
            var benchKeys: UInt64 = 0
            while Date().timeIntervalSince(benchStart) < 1.2 {
                let pass = try engine.run(iterations: iters)
                benchKeys &+= pass.keysScanned
            }
            let rate = Double(benchKeys) / Date().timeIntervalSince(benchStart)
            info(String(format: "throughput: %7.2f Mkey/s at %6d walkers (%d steps/dispatch)",
                        rate / 1e6, engine.threadCount, iters))
        }
    } catch {
        check("GPU engine", false, "\(error.localizedDescription)")
    }
} else {
    info("no Metal device found — GPU checks skipped")
}

// ===========================================================================
print("")
if failures.isEmpty {
    print("\(green)\(bold)ALL \(checksRun) CHECKS PASSED\(off)\n")
    exit(0)
} else {
    print("\(red)\(bold)\(failures.count) of \(checksRun) CHECKS FAILED\(off)")
    for f in failures { print("\(red)  · \(f)\(off)") }
    print("")
    exit(1)
}
