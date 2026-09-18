//
//  CPUEngine.swift
//  VanityMetal
//
//  A multi-core CPU search that runs the identical algorithm to the Metal
//  kernel. It exists for three reasons: as an automatic fallback when a GPU
//  self-test fails, as a low-power / quiet mode, and as the thing the GPU is
//  cross-checked against.
//

import Foundation

@inline(__always)
public func hashInRange(_ hash: [UInt8], _ range: HashRange) -> Bool {
    for i in 0..<20 {
        if hash[i] < range.lo[i] { return false }
        if hash[i] > range.lo[i] { break }
    }
    for i in 0..<20 {
        if hash[i] > range.hi[i] { return false }
        if hash[i] < range.hi[i] { break }
    }
    return true
}

public final class CPUEngine {

    public private(set) var threadCount: Int = 0
    public private(set) var startKeys: [U256] = []
    public private(set) var iterationsDone: UInt64 = 0

    private var points: [ECPoint] = []
    private var targets: [HashRange] = []
    private var hashPaths: UInt32 = 0
    private var gTable: [ECPoint] = []
    private var jump: ECPoint = ECPoint()

    public init() {}

    public var suggestedThreadCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
    }

    public func prepare(targets: [HashRange], threadCount: Int, seed: U256? = nil) {
        self.targets = targets
        self.hashPaths = targets.reduce(UInt32(0)) { $0 | $1.kind.hashPath }
        self.threadCount = max(1, threadCount)
        let built = Secp256k1.buildGTable(halfGroup: KernelConstants.groupHalf)
        self.gTable = built.points
        self.jump = built.jump
        seedStartPoints(base: seed)
    }

    public func seedStartPoints(base: U256? = nil) {
        let baseKey = base ?? Fn.random()
        let span = U256(0, 0, 1, 0)
        var keys: [U256] = []
        var acc = baseKey
        for _ in 0..<threadCount {
            keys.append(acc)
            acc = Fn.add(acc, span)
        }
        startKeys = keys
        points = keys.map { Secp256k1.multiplyG($0) }
        iterationsDone = 0
    }

    /// Runs `iterations` batches on every worker.
    public func run(iterations: Int) -> (hits: [RawHit], keysScanned: UInt64) {
        guard !points.isEmpty else { return ([], 0) }
        let base = iterationsDone
        let workers = threadCount
        var perWorker = [[RawHit]](repeating: [], count: workers)
        var newPoints = points

        perWorker.withUnsafeMutableBufferPointer { hitsBuf in
            newPoints.withUnsafeMutableBufferPointer { ptBuf in
                let hb = hitsBuf, pb = ptBuf
                DispatchQueue.concurrentPerform(iterations: workers) { w in
                    var local: [RawHit] = []
                    var p = pb[w]
                    for iter in 0..<iterations {
                        p = self.walkBatch(from: p, threadId: w,
                                           iteration: base &+ UInt64(iter),
                                           into: &local)
                    }
                    pb[w] = p
                    hb[w] = local
                }
            }
        }

        points = newPoints
        iterationsDone &+= UInt64(iterations)
        let scanned = UInt64(workers) * UInt64(iterations) * UInt64(KernelConstants.groupSize)
        return (perWorker.flatMap { $0 }, scanned)
    }

    /// One batch: 129 keys centred on `p`, using a single modular inverse.
    private func walkBatch(from p: ECPoint, threadId: Int, iteration: UInt64,
                           into hits: inout [RawHit]) -> ECPoint {
        let half = KernelConstants.groupHalf
        let slots = half + 1
        var dxs = [U256](repeating: .zero, count: slots)
        var pfx = [U256](repeating: .zero, count: slots)

        var run = U256.one
        for i in 0..<slots {
            let gx = (i < half) ? gTable[i].x : jump.x
            var dx = Fp.sub(gx, p.x)
            if dx.isZero { dx = U256.one }
            dxs[i] = dx
            run = Fp.mul(run, dx)
            pfx[i] = run
        }

        var inv = Fp.inv(run)
        var next = p

        for i in stride(from: slots - 1, through: 0, by: -1) {
            let isJump = (i == half)
            let g = isJump ? jump : gTable[i]
            let s = (i == 0) ? inv : Fp.mul(inv, pfx[i - 1])
            if i > 0 { inv = Fp.mul(inv, dxs[i]) }

            if isJump {
                let lam = Fp.mul(Fp.sub(g.y, p.y), s)
                let nx = Fp.sub(Fp.sub(Fp.sqr(lam), p.x), g.x)
                let ny = Fp.sub(Fp.mul(lam, Fp.sub(p.x, nx)), p.y)
                next = ECPoint(x: nx, y: ny)
                continue
            }

            let mag = i + 1
            for sign in 0..<2 {
                let qy = sign == 0 ? g.y : Fp.neg(g.y)
                let lam = Fp.mul(Fp.sub(qy, p.y), s)
                let rx = Fp.sub(Fp.sub(Fp.sqr(lam), p.x), g.x)
                let ry = Fp.sub(Fp.mul(lam, Fp.sub(p.x, rx)), p.y)
                test(ECPoint(x: rx, y: ry), threadId: threadId, iteration: iteration,
                     offset: sign == 0 ? mag : -mag, into: &hits)
            }
        }

        test(p, threadId: threadId, iteration: iteration, offset: 0, into: &hits)
        return next
    }

    private func test(_ point: ECPoint, threadId: Int, iteration: UInt64, offset: Int,
                      into hits: inout [RawHit]) {
        var h160c: [UInt8]?
        if hashPaths & AddressKind.p2pkhCompressed.hashPath != 0
            || hashPaths & AddressKind.p2sh.hashPath != 0 {
            h160c = Hash.hash160(Secp256k1.compressedPubkey(point))
        }
        if let hc = h160c, hashPaths & AddressKind.p2pkhCompressed.hashPath != 0 {
            emit(hc, kinds: [.p2pkhCompressed, .bech32], point: point,
                 threadId: threadId, iteration: iteration, offset: offset, into: &hits)
        }
        if let hc = h160c, hashPaths & AddressKind.p2sh.hashPath != 0 {
            let hs = Hash.hash160([0x00, 0x14] + hc)
            emit(hs, kinds: [.p2sh], point: point,
                 threadId: threadId, iteration: iteration, offset: offset, into: &hits)
        }
        if hashPaths & AddressKind.p2pkhUncompressed.hashPath != 0 {
            let hu = Hash.hash160(Secp256k1.uncompressedPubkey(point))
            emit(hu, kinds: [.p2pkhUncompressed], point: point,
                 threadId: threadId, iteration: iteration, offset: offset, into: &hits)
        }
        if hashPaths & AddressKind.eth.hashPath != 0 {
            let he = Array(Hash.keccak256(Secp256k1.rawPubkey(point))[12...])
            emit(he, kinds: [.eth], point: point,
                 threadId: threadId, iteration: iteration, offset: offset, into: &hits)
        }
    }

    private func emit(_ hash: [UInt8], kinds: [AddressKind], point: ECPoint,
                      threadId: Int, iteration: UInt64, offset: Int,
                      into hits: inout [RawHit]) {
        for (index, t) in targets.enumerated() where kinds.contains(t.kind) {
            if hashInRange(hash, t) {
                hits.append(RawHit(threadId: threadId, offset: offset, iteration: iteration,
                                   targetIndex: index, kind: t.kind,
                                   parity: point.parity, hash: hash))
            }
        }
    }

    public func privateKey(for hit: RawHit) -> U256? {
        guard hit.threadId < startKeys.count else { return nil }
        let advance = mulAddSmall(U256(hit.iteration), UInt64(KernelConstants.groupSize), 0)
        return Fn.addOffset(Fn.add(startKeys[hit.threadId], advance), Int64(hit.offset))
    }
}
