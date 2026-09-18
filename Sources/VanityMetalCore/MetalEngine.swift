//
//  MetalEngine.swift
//  VanityMetal
//
//  Owns the Metal device, compiles the kernels at launch, and drives the
//  search loop. Buffers are laid out as flat UInt32 arrays that exactly match
//  the structs in the shader, which keeps the two sides in step without
//  relying on Swift/C struct-layout agreement.
//

import Foundation
import Metal

public enum KernelConstants {
    /// Must match GRP_HALF in VanityKernels.metal.
    public static let groupHalf = 64
    /// Keys generated per thread per batch: -64 … +64 inclusive.
    public static let groupSize = 2 * groupHalf + 1     // 129
    public static let paramWords = 8
    public static let targetWords = 12
    public static let resultWords = 16
}

public struct GPUDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: UInt64
    public let name: String
    public let isLowPower: Bool
    public let isRemovable: Bool
    public let hasUnifiedMemory: Bool
    public let recommendedWorkingSetMB: Int
    public let maxThreadsPerThreadgroup: Int

    public var summary: String {
        var bits: [String] = []
        bits.append(hasUnifiedMemory ? "unified" : "discrete")
        if isLowPower { bits.append("low-power") }
        if isRemovable { bits.append("eGPU") }
        bits.append("\(recommendedWorkingSetMB) MB")
        return bits.joined(separator: " · ")
    }
}

public struct RawHit: Sendable {
    public let threadId: Int
    public let offset: Int
    public let iteration: UInt64
    public let targetIndex: Int
    public let kind: AddressKind
    public let parity: UInt8
    public let hash: [UInt8]
}

public enum EngineError: LocalizedError {
    case noDevice
    case compileFailed(String)
    case functionMissing(String)
    case bufferAllocationFailed
    case selfTestFailed(UInt32)

    public var errorDescription: String? {
        switch self {
        case .noDevice: return "No Metal-capable GPU was found on this Mac."
        case .compileFailed(let m): return "The GPU kernels did not compile: \(m)"
        case .functionMissing(let n): return "Kernel function ‘\(n)’ is missing."
        case .bufferAllocationFailed: return "The GPU refused to allocate the search buffers."
        case .selfTestFailed(let mask):
            var parts: [String] = []
            if mask & 1 != 0 { parts.append("field addition") }
            if mask & 2 != 0 { parts.append("modular inverse") }
            if mask & 4 != 0 { parts.append("SHA-256") }
            if mask & 8 != 0 { parts.append("RIPEMD-160") }
            if mask & 16 != 0 { parts.append("Keccak-256") }
            if mask & 32 != 0 { parts.append("public-key serialisation / HASH160") }
            if mask & 64 != 0 { parts.append("Ethereum address derivation") }
            return "GPU self-test failed (\(parts.joined(separator: ", "))). Falling back to the CPU engine."
        }
    }
}

public final class MetalEngine {

    public let device: MTLDevice
    public let info: GPUDeviceInfo

    private let queue: MTLCommandQueue
    private let searchPipeline: MTLComputePipelineState
    private let selfTestPipeline: MTLComputePipelineState
    private let dumpPipeline: MTLComputePipelineState?

    private var startXBuf: MTLBuffer?
    private var startYBuf: MTLBuffer?
    private var gTabXBuf: MTLBuffer?
    private var gTabYBuf: MTLBuffer?
    private var jumpBuf: MTLBuffer?
    private var targetBuf: MTLBuffer?
    private var resultBuf: MTLBuffer?
    private var counterBuf: MTLBuffer?
    private var paramBuf: MTLBuffer?
    private var scratchBuf: MTLBuffer?

    public private(set) var threadCount: Int = 0
    public private(set) var startKeys: [U256] = []
    public private(set) var iterationsDone: UInt64 = 0
    private var targetKinds: [AddressKind] = []
    private var hashPaths: UInt32 = 0
    private let maxResults = 4096

    // MARK: Discovery

    public static func availableDevices() -> [GPUDeviceInfo] {
        MTLCopyAllDevices().map { d in
            GPUDeviceInfo(id: d.registryID,
                          name: d.name,
                          isLowPower: d.isLowPower,
                          isRemovable: d.isRemovable,
                          hasUnifiedMemory: d.hasUnifiedMemory,
                          recommendedWorkingSetMB: Int(d.recommendedMaxWorkingSetSize / (1024 * 1024)),
                          maxThreadsPerThreadgroup: d.maxThreadsPerThreadgroup.width)
        }
        .sorted { a, b in
            if a.isLowPower != b.isLowPower { return !a.isLowPower }
            return a.recommendedWorkingSetMB > b.recommendedWorkingSetMB
        }
    }

    public static func device(matching id: UInt64?) -> MTLDevice? {
        let all = MTLCopyAllDevices()
        if let id, let match = all.first(where: { $0.registryID == id }) { return match }
        return MTLCreateSystemDefaultDevice() ?? all.first
    }

    // MARK: Lifecycle

    public init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw EngineError.noDevice }
        self.queue = q

        // The kernels are integer-only, so the default compile options are fine.
        let options = MTLCompileOptions()
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: MetalShaderSource.source, options: options)
        } catch {
            throw EngineError.compileFailed(error.localizedDescription)
        }

        guard let searchFn = library.makeFunction(name: "vanity_search") else {
            throw EngineError.functionMissing("vanity_search")
        }
        guard let testFn = library.makeFunction(name: "vanity_selftest") else {
            throw EngineError.functionMissing("vanity_selftest")
        }
        self.searchPipeline = try device.makeComputePipelineState(function: searchFn)
        self.selfTestPipeline = try device.makeComputePipelineState(function: testFn)
        if let dumpFn = library.makeFunction(name: "vanity_dump") {
            self.dumpPipeline = try? device.makeComputePipelineState(function: dumpFn)
        } else {
            self.dumpPipeline = nil
        }

        self.info = GPUDeviceInfo(id: device.registryID,
                                  name: device.name,
                                  isLowPower: device.isLowPower,
                                  isRemovable: device.isRemovable,
                                  hasUnifiedMemory: device.hasUnifiedMemory,
                                  recommendedWorkingSetMB: Int(device.recommendedMaxWorkingSetSize / (1024 * 1024)),
                                  maxThreadsPerThreadgroup: device.maxThreadsPerThreadgroup.width)
    }

    /// Runs the known-answer tests baked into the shader. Throws if the GPU
    /// disagrees with the reference values.
    public func runSelfTest() throws {
        guard let out = device.makeBuffer(length: 8, options: .storageModeShared) else {
            throw EngineError.bufferAllocationFailed
        }
        memset(out.contents(), 0, 8)
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
            throw EngineError.bufferAllocationFailed
        }
        enc.setComputePipelineState(selfTestPipeline)
        enc.setBuffer(out, offset: 0, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let words = out.contents().bindMemory(to: UInt32.self, capacity: 2)
        if words[0] != 0 { throw EngineError.selfTestFailed(words[0]) }
        precondition(Int(words[1]) == KernelConstants.groupSize,
                     "Kernel group size \(words[1]) does not match Swift's \(KernelConstants.groupSize)")
    }

    /// A sensible default walker count.
    ///
    /// The kernel keeps a 65-slot batch-inversion scratch array per thread —
    /// about 2 KB of private memory — so piling on threads past the point where
    /// the GPU saturates just buys spill traffic. A few thousand walkers, each
    /// producing 129 keys per step, already keeps every Apple GPU busy.
    public var suggestedThreadCount: Int {
        let perGroup = threadsPerThreadgroup
        // Walker count sets the *granularity* of a dispatch: one step is
        // walkers x 129 keys and cannot be subdivided. Too many walkers and
        // even a single step overruns the dispatch window, so the engine loses
        // its ability to keep the machine responsive. A couple of thousand
        // already saturates an Apple GPU; throughput past that comes from more
        // steps per dispatch, not more walkers.
        var target = info.hasUnifiedMemory ? 2048 : 1536
        if info.isLowPower { target = 1024 }
        if info.recommendedWorkingSetMB >= 16_000 { target = 4096 }
        let groups = max(2, target / max(perGroup, 1))
        return perGroup * groups
    }

    public var threadsPerThreadgroup: Int {
        max(1, min(searchPipeline.maxTotalThreadsPerThreadgroup, 256))
    }

    // MARK: Preparation

    public func prepare(targets: [HashRange], threadCount: Int, seed: U256? = nil) throws {
        self.threadCount = max(1, threadCount)   // the kernel guards on tid >= threadCount
        self.targetKinds = targets.map(\.kind)
        self.hashPaths = targets.reduce(UInt32(0)) { $0 | $1.kind.hashPath }
        self.iterationsDone = 0

        // ---- targets ------------------------------------------------------
        var targetWords = [UInt32]()
        targetWords.reserveCapacity(targets.count * KernelConstants.targetWords)
        for t in targets {
            targetWords.append(contentsOf: beWords(t.lo))
            targetWords.append(contentsOf: beWords(t.hi))
            targetWords.append(t.kind.rawValue)
            targetWords.append(0)
        }
        if targetWords.isEmpty { targetWords = [UInt32](repeating: 0, count: KernelConstants.targetWords) }
        targetBuf = makeBuffer(targetWords)

        // ---- G table ------------------------------------------------------
        let (table, jump) = Secp256k1.buildGTable(halfGroup: KernelConstants.groupHalf)
        gTabXBuf = makeBuffer(table.flatMap { $0.x.metalLimbs })
        gTabYBuf = makeBuffer(table.flatMap { $0.y.metalLimbs })
        jumpBuf = makeBuffer(jump.x.metalLimbs + jump.y.metalLimbs)

        // ---- starting points ----------------------------------------------
        try seedStartPoints(base: seed)

        // ---- results ------------------------------------------------------
        // Batch-inversion scratch, laid out [slot][limb][thread] so a SIMD group
        // reads consecutive words. 65 slots x 8 limbs x 4 bytes per walker.
        let scratchBytes = self.threadCount * (KernelConstants.groupHalf + 1) * 8 * 4
        scratchBuf = device.makeBuffer(length: scratchBytes, options: .storageModePrivate)

        resultBuf = device.makeBuffer(length: maxResults * KernelConstants.resultWords * 4,
                                      options: .storageModeShared)
        counterBuf = device.makeBuffer(length: 4, options: .storageModeShared)
        paramBuf = device.makeBuffer(length: KernelConstants.paramWords * 4, options: .storageModeShared)
        guard resultBuf != nil, counterBuf != nil, paramBuf != nil, scratchBuf != nil,
              startXBuf != nil, startYBuf != nil, gTabXBuf != nil, gTabYBuf != nil else {
            throw EngineError.bufferAllocationFailed
        }
    }

    /// Picks one random 256-bit base key and gives thread *i* the key
    /// `base + i * span`, where the span is large enough that no two threads
    /// can ever walk into each other's territory.
    public func seedStartPoints(base: U256? = nil) throws {
        let baseKey = base ?? Fn.random()
        let span = U256(0, 0, 1, 0)     // 2^128 keys of headroom per thread

        var keys = [U256](repeating: .zero, count: threadCount)
        var acc = baseKey
        for i in 0..<threadCount {
            keys[i] = acc
            acc = Fn.add(acc, span)
        }
        self.startKeys = keys

        var xs = [UInt32](repeating: 0, count: threadCount * 8)
        var ys = [UInt32](repeating: 0, count: threadCount * 8)
        let chunks = min(threadCount, 64)
        let chunkSize = (threadCount + chunks - 1) / chunks
        let count = threadCount
        xs.withUnsafeMutableBufferPointer { xp in
            ys.withUnsafeMutableBufferPointer { yp in
                let xb = xp, yb = yp
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let lo = chunk * chunkSize
                    let hi = min(count, lo + chunkSize)
                    guard lo < hi else { return }
                    for i in lo..<hi {
                        let p = Secp256k1.multiplyG(keys[i])
                        let lx = p.x.metalLimbs, ly = p.y.metalLimbs
                        for k in 0..<8 {
                            xb[i * 8 + k] = lx[k]
                            yb[i * 8 + k] = ly[k]
                        }
                    }
                }
            }
        }

        startXBuf = makeBuffer(xs)
        startYBuf = makeBuffer(ys)
        iterationsDone = 0
    }

    /// How long a single dispatch should take. This is a *latency* target, not
    /// a throughput limit: dispatches run back to back, so a GPU twice as fast
    /// simply does twice as many keys inside the same window.
    ///
    /// It exists because macOS does not meaningfully preempt compute kernels —
    /// a dispatch that runs for seconds holds the GPU, freezes the desktop and
    /// can trip the watchdog. Raise it for a few percent more throughput at the
    /// cost of a choppier machine; lower it for a perfectly smooth desktop.
    public var targetDispatchSeconds: Double = 0.10

    /// Smoothed keys-per-second actually achieved by this device, measured
    /// from real dispatches rather than assumed.
    public private(set) var measuredKeyRate: Double = 0

    /// Steps per dispatch, derived from what the GPU has actually delivered so
    /// far. Before the first measurement it deliberately starts small, then the
    /// hardware decides.
    public var maxIterationsPerDispatch: Int {
        let perIteration = max(1, threadCount * KernelConstants.groupSize)
        guard measuredKeyRate > 0 else {
            return max(1, 500_000 / perIteration)   // one cautious probe
        }
        let keys = measuredKeyRate * targetDispatchSeconds
        return max(1, Int(keys / Double(perIteration)))
    }

    // MARK: Running

    /// Runs `iterations` batches on every thread and returns whatever hits the
    /// GPU flagged. Each batch is 129 keys per thread.
    @discardableResult
    public func run(iterations: Int) throws -> (hits: [RawHit], keysScanned: UInt64) {
        guard let startXBuf, let startYBuf, let gTabXBuf, let gTabYBuf,
              let jumpBuf, let targetBuf, let resultBuf, let counterBuf, let paramBuf,
              let scratchBuf else {
            throw EngineError.bufferAllocationFailed
        }
        // Clamped so a caller asking for a huge batch cannot lock up the display.
        let iterations = max(1, min(iterations, maxIterationsPerDispatch))
        let dispatchStart = Date()

        memset(counterBuf.contents(), 0, 4)
        let params: [UInt32] = [
            UInt32(max(1, targetKinds.count)),
            hashPaths,
            UInt32(iterations),
            UInt32(maxResults),
            UInt32(threadCount),
            0, 0, 0
        ]
        params.withUnsafeBytes { raw in
            paramBuf.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }

        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
            throw EngineError.bufferAllocationFailed
        }
        enc.setComputePipelineState(searchPipeline)
        enc.setBuffer(paramBuf, offset: 0, index: 0)
        enc.setBuffer(targetBuf, offset: 0, index: 1)
        enc.setBuffer(startXBuf, offset: 0, index: 2)
        enc.setBuffer(startYBuf, offset: 0, index: 3)
        enc.setBuffer(gTabXBuf, offset: 0, index: 4)
        enc.setBuffer(gTabYBuf, offset: 0, index: 5)
        enc.setBuffer(jumpBuf, offset: 0, index: 6)
        enc.setBuffer(resultBuf, offset: 0, index: 7)
        enc.setBuffer(counterBuf, offset: 0, index: 8)
        enc.setBuffer(scratchBuf, offset: 0, index: 9)

        let tpg = threadsPerThreadgroup
        let groups = (threadCount + tpg - 1) / tpg
        enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        if let err = cmd.error {
            throw EngineError.compileFailed(err.localizedDescription)
        }

        let base = iterationsDone
        iterationsDone &+= UInt64(iterations)

        let found = Int(counterBuf.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        var hits: [RawHit] = []
        if found > 0 {
            let n = min(found, maxResults)
            let words = resultBuf.contents().bindMemory(to: UInt32.self,
                                                        capacity: n * KernelConstants.resultWords)
            for i in 0..<n {
                let o = i * KernelConstants.resultWords
                let kindRaw = words[o + 4]
                guard let kind = AddressKind(rawValue: kindRaw) else { continue }
                var hash = [UInt8]()
                for w in 0..<5 {
                    let v = words[o + 6 + w]
                    hash.append(UInt8((v >> 24) & 0xFF)); hash.append(UInt8((v >> 16) & 0xFF))
                    hash.append(UInt8((v >> 8) & 0xFF));  hash.append(UInt8(v & 0xFF))
                }
                hits.append(RawHit(threadId: Int(words[o]),
                                   offset: Int(Int32(bitPattern: words[o + 1])),
                                   iteration: base &+ UInt64(words[o + 2]),
                                   targetIndex: Int(words[o + 3]),
                                   kind: kind,
                                   parity: UInt8(words[o + 5] & 1),
                                   hash: hash))
            }
        }

        let scanned = UInt64(threadCount) * UInt64(iterations) * UInt64(KernelConstants.groupSize)

        // Learn this device's real throughput so the next dispatch can be sized
        // to the hardware instead of to a guess.
        let elapsed = Date().timeIntervalSince(dispatchStart)
        if elapsed > 0 {
            let observed = Double(scanned) / elapsed
            measuredKeyRate = measuredKeyRate == 0 ? observed
                                                   : measuredKeyRate * 0.7 + observed * 0.3
        }
        return (hits, scanned)
    }

    /// Reads one G-table entry and the jump point back exactly as the kernel
    /// sees them. Diagnostics only.
    public func dumpTableEntry(index: Int) -> (g: ECPoint, jump: ECPoint)? {
        guard let pipeline = dumpPipeline, let gx = gTabXBuf, let gy = gTabYBuf,
              let jp = jumpBuf,
              let out = device.makeBuffer(length: 32 * 4, options: .storageModeShared),
              let idxBuf = device.makeBuffer(length: 4, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        idxBuf.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = UInt32(index)
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(gx, offset: 0, index: 0)
        enc.setBuffer(gy, offset: 0, index: 1)
        enc.setBuffer(jp, offset: 0, index: 2)
        enc.setBuffer(idxBuf, offset: 0, index: 3)
        enc.setBuffer(out, offset: 0, index: 4)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let w = out.contents().bindMemory(to: UInt32.self, capacity: 32)
        func limbs(_ base: Int) -> [UInt32] { (0..<8).map { w[base + $0] } }
        return (ECPoint(x: U256(metalLimbs: limbs(0)), y: U256(metalLimbs: limbs(8))),
                ECPoint(x: U256(metalLimbs: limbs(16)), y: U256(metalLimbs: limbs(24))))
    }

    /// Reads each walker's current position back off the GPU. Used by the
    /// verifier to check that the walk advances to exactly the same point the
    /// CPU engine reaches.
    public var currentPoints: [ECPoint] {
        guard let xb = startXBuf, let yb = startYBuf, threadCount > 0 else { return [] }
        let xs = xb.contents().bindMemory(to: UInt32.self, capacity: threadCount * 8)
        let ys = yb.contents().bindMemory(to: UInt32.self, capacity: threadCount * 8)
        var out: [ECPoint] = []
        out.reserveCapacity(threadCount)
        for t in 0..<threadCount {
            var lx = [UInt32](repeating: 0, count: 8)
            var ly = [UInt32](repeating: 0, count: 8)
            for k in 0..<8 {
                lx[k] = xs[t * 8 + k]
                ly[k] = ys[t * 8 + k]
            }
            out.append(ECPoint(x: U256(metalLimbs: lx), y: U256(metalLimbs: ly)))
        }
        return out
    }

    /// Rebuilds the private key a hit corresponds to.
    public func privateKey(for hit: RawHit) -> U256? {
        guard hit.threadId < startKeys.count else { return nil }
        let advance = mulAddSmall(U256(hit.iteration), UInt64(KernelConstants.groupSize), 0)
        let walked = Fn.add(startKeys[hit.threadId], advance)
        return Fn.addOffset(walked, Int64(hit.offset))
    }

    // MARK: helpers

    private func makeBuffer(_ words: [UInt32]) -> MTLBuffer? {
        words.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
    }

    private func beWords(_ bytes: [UInt8]) -> [UInt32] {
        precondition(bytes.count == 20)
        var out = [UInt32]()
        for i in 0..<5 {
            var v: UInt32 = 0
            for j in 0..<4 { v = (v << 8) | UInt32(bytes[i * 4 + j]) }
            out.append(v)
        }
        return out
    }
}
