//
//  SearchController.swift
//  VanityMetal
//
//  The brain the UI binds to: owns the engines, runs the search loop off the
//  main thread, verifies every hit on the CPU before it is shown, and keeps
//  the statistics the dashboard displays.
//
//  Threading rule for this file: the search loop runs on its own Thread and
//  touches nothing published directly. It talks to the UI through `post`,
//  which hops to the main queue, and reads live settings through `flags`,
//  which is lock-protected. No main-queue `sync` anywhere, so the UI can never
//  be deadlocked by a busy GPU.
//

import Foundation
import Combine

// MARK: - A verified result

public struct FoundKey: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var address: String
    public var kindRaw: UInt32
    public var privateKeyHex: String
    public var wif: String
    public var publicKeyHex: String
    public var targetText: String
    public var foundAt: Date
    public var keysScannedWhenFound: UInt64

    public var kind: AddressKind { AddressKind(rawValue: kindRaw) ?? .p2pkhCompressed }

    public var exportLine: String {
        """
        Address     : \(address)
        Type        : \(kind.title)
        Private key : \(privateKeyHex)
        WIF         : \(wif)
        Public key  : \(publicKeyHex)
        Matched     : \(targetText)
        Found       : \(ISO8601DateFormatter().string(from: foundAt))
        """
    }
}

// MARK: - Engine selection

public enum EngineMode: String, CaseIterable, Identifiable, Sendable {
    case gpu, cpu, both
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .gpu: return "GPU"
        case .cpu: return "CPU"
        case .both: return "GPU + CPU"
        }
    }
}

public enum RunState: String, Sendable {
    case idle, preparing, running, paused, stopping

    public var label: String {
        switch self {
        case .idle: return "IDLE"
        case .preparing: return "ARMING"
        case .running: return "SCANNING"
        case .paused: return "HELD"
        case .stopping: return "STOPPING"
        }
    }
}

/// Lock-protected settings the worker thread needs to read while running.
final class RunFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _stop = false
    private var _pause = false
    private var _thermalGuard = true
    private var _fixedIterations = 0

    var stop: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stop }
        set { lock.lock(); _stop = newValue; lock.unlock() }
    }
    var pause: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _pause }
        set { lock.lock(); _pause = newValue; lock.unlock() }
    }
    var thermalGuard: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _thermalGuard }
        set { lock.lock(); _thermalGuard = newValue; lock.unlock() }
    }
    var fixedIterations: Int {
        get { lock.lock(); defer { lock.unlock() }; return _fixedIterations }
        set { lock.lock(); _fixedIterations = newValue; lock.unlock() }
    }
    private var _dispatchSeconds = 0.10
    var dispatchSeconds: Double {
        get { lock.lock(); defer { lock.unlock() }; return _dispatchSeconds }
        set { lock.lock(); _dispatchSeconds = newValue; lock.unlock() }
    }
    private var _deadline: Date?
    var deadline: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _deadline }
        set { lock.lock(); _deadline = newValue; lock.unlock() }
    }
}

// MARK: - Controller

public final class SearchController: ObservableObject {

    // Configuration
    @Published public var targetInputs: [String] = ["1Neo"]
    @Published public private(set) var selectedBitcoinPuzzleID: Int? = nil
    @Published public var keyMinimumHex: String = "1"
    @Published public var keyMaximumHex: String = U256.subb(Fn.n, .one).0.hexString
    @Published public var keyMinimumStepText: String = "1"
    @Published public var keyMaximumStepText: String = "1"
    @Published public var puzzleChunkSizeText: String = "100000000"
    @Published public var forcedKind: AddressKind? = nil
    @Published public var caseSensitive: Bool = true
    @Published public var searchUncompressed: Bool = false
    @Published public var engineMode: EngineMode = .gpu
    @Published public var selectedDeviceID: UInt64? = nil
    @Published public var gpuThreadCount: Int = 0        // 0 = auto
    @Published public var cpuThreadCount: Int = 0        // 0 = auto
    @Published public var batchIterations: Int = 0 { didSet { flags.fixedIterations = batchIterations } }
    /// How long one GPU dispatch may run, in milliseconds. Latency, not
    /// throughput: the engine fits as many keys into the window as the GPU can
    /// manage, so faster hardware simply does more per dispatch.
    @Published public var dispatchWindowMs: Double = 100 {
        didSet { flags.dispatchSeconds = max(0.005, dispatchWindowMs / 1000.0) }
    }
    @Published public var stopOnFirstHit: Bool = false
    @Published public var thermalGuard: Bool = true { didSet { flags.thermalGuard = thermalGuard } }
    @Published public var autoSaveResults: Bool = true

    // Live state
    @Published public private(set) var state: RunState = .idle
    @Published public private(set) var devices: [GPUDeviceInfo] = []
    @Published public private(set) var activeDeviceName: String = "—"
    @Published public private(set) var activeWalkers: Int = 0
    @Published public private(set) var keysScanned: UInt64 = 0
    @Published public private(set) var rate: Double = 0
    @Published public private(set) var peakRate: Double = 0
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var history: [Double] = []
    @Published public private(set) var results: [FoundKey] = []
    @Published public private(set) var log: [LogLine] = []
    @Published public private(set) var parsedTargets: [SearchTarget] = []
    @Published public private(set) var parseError: String? = nil
    @Published public var keyRangeError: String? = nil
    @Published public private(set) var puzzleProgressText: String? = nil
    @Published public private(set) var puzzleChunkProgress: Double = 0
    @Published public private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published public private(set) var gpuSelfTestPassed: Bool? = nil

    public struct LogLine: Identifiable, Sendable {
        public let id = UUID()
        public let time: Date
        public let level: Level
        public let text: String
        public enum Level: Sendable { case info, good, warn, bad }
    }

    // Internals
    private let flags = RunFlags()
    private var worker: Thread?
    private var thermalObserver: NSObjectProtocol?

    public init() {
        devices = MetalEngine.availableDevices()
        selectedDeviceID = devices.first?.id
        thermalState = ProcessInfo.processInfo.thermalState
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.thermalState = ProcessInfo.processInfo.thermalState
            }
        SessionLog.start()
        refreshTargets()
        do { _ = try currentKeyRange() } catch { keyRangeError = error.localizedDescription }
        results = ResultStore.load()
        note("VanityMetal online. \(devices.count) Metal device\(devices.count == 1 ? "" : "s") detected.", .info)
        for d in devices { note("· \(d.name) — \(d.summary)", .info) }
        if devices.isEmpty { note("No GPU found; GPU-only search is unavailable.", .warn) }
    }

    deinit {
        flags.stop = true
        if let o = thermalObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Targets

    public func refreshTargets() {
        var parsed: [SearchTarget] = []
        var firstError: String? = nil
        for raw in targetInputs where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            do {
                var t = try TargetParser.parse(raw, forceKind: forcedKind, caseSensitive: caseSensitive)
                if searchUncompressed && t.kind == .p2pkhCompressed {
                    let extra = try TargetParser.parse(raw, forceKind: .p2pkhUncompressed,
                                                       caseSensitive: caseSensitive)
                    t.ranges.append(contentsOf: extra.ranges.map {
                        HashRange(lo: $0.lo, hi: $0.hi, kind: .p2pkhUncompressed)
                    })
                    t.difficulty = TargetParser.difficulty(of: t.ranges)
                }
                parsed.append(t)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        parsedTargets = parsed
        parseError = firstError
    }

    public var bitcoinPuzzles: [BitcoinPuzzle] { BitcoinPuzzleCatalog.puzzles }

    public func selectBitcoinPuzzle(_ puzzleID: Int?) {
        guard state == .idle else { return }
        selectedBitcoinPuzzleID = puzzleID
        guard let puzzleID,
              let puzzle = BitcoinPuzzleCatalog.puzzles.first(where: { $0.number == puzzleID }) else {
            return
        }
        targetInputs = [puzzle.address]
        keyMinimumHex = puzzle.minimumKeyHex
        keyMaximumHex = puzzle.maximumKeyHex
        keyMinimumStepText = "1"
        keyMaximumStepText = "1"
        forcedKind = nil
        keyRangeError = nil
        let progress = try? PuzzleChunkCoordinator(
            puzzleID: puzzleID,
            minimum: U256(hex: puzzle.minimumKeyHex)!,
            maximum: U256(hex: puzzle.maximumKeyHex)!,
            chunkSize: currentPuzzleChunkSize())
        puzzleProgressText = progress?.progressSummary
        puzzleChunkProgress = progress?.activeChunkProgress ?? 0
        refreshTargets()
        note("Loaded Bitcoin Puzzle #\(puzzle.number) (catalog status: \(puzzle.status)).", .info)
    }

    public func currentPuzzleChunkSize() throws -> UInt64 {
        let text = puzzleChunkSizeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = UInt64(text), size > 0 else { throw PuzzleChunkError.invalidConfiguration }
        return size
    }

    public func resetSelectedPuzzleProgress() {
        guard let puzzleID = selectedBitcoinPuzzleID else { return }
        PuzzleChunkCoordinator.resetProgress(puzzleID: puzzleID)
        puzzleProgressText = "No saved progress"
        puzzleChunkProgress = 0
        note("Saved chunks for Bitcoin Puzzle #\(puzzleID) were reset.", .warn)
    }

    /// Combined difficulty when several prefixes are hunted at once.
    public var combinedDifficulty: Double {
        guard !parsedTargets.isEmpty else { return .infinity }
        let inverse = parsedTargets.reduce(0.0) { $0 + 1.0 / $1.difficulty }
        return inverse > 0 ? 1.0 / inverse : .infinity
    }

    public var probabilitySoFar: Double {
        let d = combinedDifficulty
        guard d.isFinite, d > 0 else { return 0 }
        return 1 - exp(-Double(keysScanned) / d)
    }

    /// Mean time to a hit at the current rate.
    public var expectedSeconds: Double {
        let d = combinedDifficulty
        guard d.isFinite, rate > 0 else { return .infinity }
        return d / rate
    }

    /// The 50% point — the number people actually want to see.
    /// (Spelled out rather than `log(2)` because this class has a `log`
    /// property, which shadows the global function.)
    public var fiftyPercentSeconds: Double { expectedSeconds * 0.693_147_180_559_945_3 }

    // MARK: Control

    public func start() {
        if state == .paused {
            flags.pause = false
            state = .running
            note("Resumed.", .good)
            return
        }
        guard state == .idle else { return }

        refreshTargets()
        let keyRange: KeySearchRange
        let puzzleID = selectedBitcoinPuzzleID
        let chunkSize: UInt64?
        do {
            keyRange = try currentKeyRange()
            chunkSize = puzzleID == nil ? nil : try currentPuzzleChunkSize()
            keyRangeError = nil
        } catch {
            keyRangeError = error.localizedDescription
            note(error.localizedDescription, .bad)
            return
        }
        guard !parsedTargets.isEmpty else {
            note(parseError ?? "Nothing to search for — add a valid prefix first.", .bad)
            return
        }

        flags.stop = false
        flags.pause = false
        flags.thermalGuard = thermalGuard
        flags.fixedIterations = batchIterations
        flags.dispatchSeconds = max(0.005, dispatchWindowMs / 1000.0)

        keysScanned = 0
        elapsed = 0
        rate = 0
        peakRate = 0
        history = []
        state = .preparing

        let ranges = parsedTargets.flatMap(\.ranges)
        let deviceID = selectedDeviceID
        let gpuThreads = gpuThreadCount

        let t = Thread { [weak self] in
            self?.runLoop(ranges: ranges, keyRange: keyRange, deviceID: deviceID,
                          gpuThreads: gpuThreads, puzzleID: puzzleID,
                          chunkSize: chunkSize)
        }
        t.name = "VanityMetal.search"
        t.qualityOfService = .userInitiated
        t.stackSize = 8 << 20
        worker = t
        t.start()
    }

    public func currentKeyRange() throws -> KeySearchRange {
        try KeySearchRange.parse(minimum: keyMinimumHex, maximum: keyMaximumHex,
                                 minimumStep: keyMinimumStepText,
                                 maximumStep: keyMaximumStepText)
    }

    public func pause() {
        guard state == .running else { return }
        flags.pause = true
        state = .paused
        note("Paused — the walk keeps its place.", .warn)
    }

    public func toggle() {
        switch state {
        case .idle: start()
        case .running: pause()
        case .paused: start()
        default: break
        }
    }

    public func stop() {
        guard state != .idle else { return }
        flags.stop = true
        flags.pause = false
        state = .stopping
    }

    public func reseed() {
        note("Re-seeding with fresh randomness…", .info)
        let wasRunning = (state == .running || state == .paused)
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            if wasRunning { self.start() }
        }
    }

    public func clearResults() {
        results.removeAll()
        ResultStore.clear()
        note("Results cleared.", .info)
    }

    /// Re-runs the GPU known-answer tests on demand.
    public func runSelfTestOnly() {
        guard state == .idle else {
            note("Stop the run first.", .warn)
            return
        }
        let deviceID = selectedDeviceID
        note("Running GPU known-answer tests…", .info)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let dev = MetalEngine.device(matching: deviceID) else {
                self.post { $0.note("No Metal device to test.", .bad) }
                return
            }
            do {
                let e = try MetalEngine(device: dev)
                try e.runSelfTest()
                self.post {
                    $0.gpuSelfTestPassed = true
                    $0.note("Self-test passed on \(dev.name): field arithmetic, modular inverse, SHA-256, RIPEMD-160 and Keccak-256 all match the reference vectors.", .good)
                }
            } catch {
                self.post {
                    $0.gpuSelfTestPassed = false
                    $0.note(error.localizedDescription, .bad)
                }
            }
        }
    }

    /// Times the engine against a target that can essentially never be hit, so
    /// the number reported is pure throughput.
    public func runBenchmark(seconds: Double = 6) {
        guard state == .idle else {
            note("Stop the current run before benchmarking.", .warn)
            return
        }
        var lo = [UInt8](repeating: 0, count: 20)
        for i in 0..<20 { lo[i] = UInt8.random(in: 0...255) }
        let range = HashRange(lo: lo, hi: lo, kind: .p2pkhCompressed)

        flags.stop = false
        flags.pause = false
        flags.thermalGuard = false
        flags.fixedIterations = 0
        flags.deadline = Date().addingTimeInterval(seconds)

        keysScanned = 0; elapsed = 0; rate = 0; peakRate = 0; history = []
        state = .preparing
        note("Benchmarking for \(Int(seconds))s — thermal guard off, no targets.", .info)

        let deviceID = selectedDeviceID
        let gpuThreads = gpuThreadCount
        let t = Thread { [weak self] in
            guard let engine = self else { return }
            let keyRange = try! KeySearchRange(minimum: .one, maximum: U256.subb(Fn.n, .one).0, step: 1)
            engine.runLoop(ranges: [range], keyRange: keyRange, deviceID: deviceID,
                           gpuThreads: gpuThreads)
            engine.post { c in
                c.flags.deadline = nil
                c.flags.thermalGuard = c.thermalGuard
                c.note("Benchmark: peak \(c.formatRate(c.peakRate)), "
                       + "\(c.formatCount(c.keysScanned)) keys in \(Int(seconds))s.", .good)
            }
        }
        t.name = "VanityMetal.benchmark"
        t.qualityOfService = .userInitiated
        t.stackSize = 8 << 20
        worker = t
        t.start()
    }

    // MARK: The loop (runs off the main thread)

    private func runLoop(ranges: [HashRange], keyRange: KeySearchRange, deviceID: UInt64?,
                         gpuThreads: Int, puzzleID: Int? = nil, chunkSize: UInt64? = nil) {
        // Keep App Nap and idle system sleep from suspending an active search
        // when the app is in the background. The display may still sleep.
        let processInfo = ProcessInfo.processInfo
        func beginSearchActivity() -> NSObjectProtocol {
            processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                      reason: "Running the requested GPU search")
        }
        var searchActivity: NSObjectProtocol? = beginSearchActivity()
        defer {
            if let searchActivity { processInfo.endActivity(searchActivity) }
        }

        var metalEngine: MetalEngine?
        var chunkCoordinator: PuzzleChunkCoordinator?

        if let dev = MetalEngine.device(matching: deviceID) {
                post { $0.note("Compiling Metal kernels for \(dev.name)…", .info) }
                do {
                    let e = try MetalEngine(device: dev)
                    try e.runSelfTest()
                    post {
                        $0.gpuSelfTestPassed = true
                        $0.note("GPU self-test passed on \(dev.name).", .good)
                        $0.activeDeviceName = dev.name
                    }
                    let threads = gpuThreads > 0 ? gpuThreads : e.suggestedThreadCount
                    let initialRange: KeySearchRange
                    if let puzzleID, let chunkSize {
                        let coordinator = try PuzzleChunkCoordinator(
                            puzzleID: puzzleID, minimum: keyRange.minimum,
                            maximum: keyRange.maximum, chunkSize: chunkSize)
                        guard let firstChunk = try coordinator.nextRange() else {
                            post {
                                $0.puzzleProgressText = coordinator.progressSummary
                                $0.puzzleChunkProgress = coordinator.activeChunkProgress
                                $0.note("All chunks for Bitcoin Puzzle #\(puzzleID) are complete.", .good)
                                $0.state = .idle
                            }
                            return
                        }
                        chunkCoordinator = coordinator
                        initialRange = firstChunk
                        post {
                            $0.puzzleProgressText = coordinator.progressSummary
                            $0.puzzleChunkProgress = coordinator.activeChunkProgress
                        }
                    } else {
                        initialRange = keyRange
                    }
                    try e.prepare(targets: ranges, threadCount: threads, keyRange: initialRange)
                    let actual = e.threadCount
                    post {
                        $0.activeWalkers = actual
                        $0.note("GPU armed: \(actual) walkers × \(KernelConstants.groupSize) keys per step.", .info)
                    }
                    metalEngine = e
                } catch {
                    post {
                        $0.gpuSelfTestPassed = false
                        $0.note(error.localizedDescription, .bad)
                    }
                }
        } else {
            post { $0.note("No Metal device available.", .bad) }
        }

        guard metalEngine != nil else {
            post { $0.note("GPU engine could not be started; GPU-only mode does not fall back to CPU.", .bad); $0.state = .idle }
            return
        }

        post { $0.state = .running }
        var activeKeyRange = keyRange
        if let chunkCoordinator {
            SessionLog.write("Puzzle #\(chunkCoordinator.puzzleID) chunk scan: size=\(chunkCoordinator.chunkSize), \(chunkCoordinator.progressSummary)")
            post { $0.note("Puzzle #\(chunkCoordinator.puzzleID): resuming random chunk scan (\(chunkCoordinator.progressSummary)).", .info) }
        } else {
            SessionLog.write("GPU run loop entered; key count=\(keyRange.keyCount.hexString); step=\(keyRange.step)")
            post { $0.note("First cycle selected step \(keyRange.step).", .info) }
        }

        var dispatchCount = 0
        var totalScanned: UInt64 = 0
        let started = Date()
        var lastPublish = Date()
        var scannedSinceTick: UInt64 = 0

        while !flags.stop {
            if let deadline = flags.deadline, Date() >= deadline { break }
            if flags.pause {
                if let activity = searchActivity {
                    processInfo.endActivity(activity)
                    searchActivity = nil
                }
                Thread.sleep(forTimeInterval: 0.15)
                if !flags.pause, !flags.stop { searchActivity = beginSearchActivity() }
                continue
            }

            // Fanless MacBooks otherwise clock themselves into the floor.
            if flags.thermalGuard {
                switch ProcessInfo.processInfo.thermalState {
                case .critical: Thread.sleep(forTimeInterval: 0.5)
                case .serious:  Thread.sleep(forTimeInterval: 0.12)
                default: break
                }
            }

            var scanned: UInt64 = 0

            if let e = metalEngine {
                e.targetDispatchSeconds = flags.dispatchSeconds
                // The engine sizes its own batch from throughput it has actually
                // measured on this GPU. A manual override is honoured, but still
                // bounded so one slip of the slider cannot lock the display up.
                let manual = flags.fixedIterations
                let perStep = Double(max(1, e.threadCount * KernelConstants.groupSize))
                let twoSecondsWorth = max(1, Int((e.measuredKeyRate > 0
                                                  ? e.measuredKeyRate * 2.0
                                                  : 2_000_000) / perStep))
                let iters = manual > 0 ? max(1, min(manual, twoSecondsWorth))
                                       : e.maxIterationsPerDispatch
                do {
                    let dispatchStart = Date()
                    let r = try e.run(iterations: iters)
                    let took = Date().timeIntervalSince(dispatchStart)
                    if dispatchCount < 6 || dispatchCount % 40 == 0 {
                        SessionLog.write(String(format:
                            "dispatch #%d: %d steps, %llu keys, %.3fs, measured %.2f Mkey/s",
                            dispatchCount, iters, r.keysScanned, took, e.measuredKeyRate / 1e6))
                    }
                    dispatchCount += 1
                    scanned &+= r.keysScanned
                    verify(r.hits, engine: .metal(e), totalScanned: totalScanned &+ scanned)
                } catch {
                    post { $0.note("GPU dispatch failed: \(error.localizedDescription).", .bad) }
                    metalEngine = nil
                    flags.stop = true
                }
            }
            if let e = metalEngine, let coordinator = chunkCoordinator {
                do {
                    _ = try coordinator.recordScanned(scanned)
                    let progress = coordinator.progressSummary
                    let chunkProgress = coordinator.activeChunkProgress
                    post {
                        $0.puzzleProgressText = progress
                        $0.puzzleChunkProgress = chunkProgress
                    }
                    if e.isExhausted, !flags.stop {
                        if let nextChunk = try coordinator.nextRange() {
                            try e.prepareNextRange(nextChunk)
                            SessionLog.write("Puzzle #\(coordinator.puzzleID): started another random chunk; \(progress)")
                            post { $0.note("Chunk complete. Selected another random uncompleted chunk. \(progress)", .info) }
                        } else {
                            flags.stop = true
                            post {
                                $0.note("All chunks for Bitcoin Puzzle #\(coordinator.puzzleID) are complete.", .good)
                            }
                        }
                    }
                } catch {
                    post { $0.note("Puzzle progress could not be saved: \(error.localizedDescription).", .bad) }
                    flags.stop = true
                }
            } else if let e = metalEngine, e.isExhausted, !flags.stop {
                let nextRange = activeKeyRange.nextCycle()
                do {
                    try e.prepare(targets: ranges, threadCount: e.threadCount,
                                  keyRange: nextRange)
                    activeKeyRange = nextRange
                    SessionLog.write("Key range exhausted; restarting from minimum with step=\(nextRange.step)")
                    post { $0.note("Range complete. Restarted at minimum with random step \(nextRange.step).", .info) }
                } catch {
                    post { $0.note("Could not restart key-range cycle: \(error.localizedDescription).", .bad) }
                    flags.stop = true
                }
            }

            totalScanned &+= scanned
            scannedSinceTick &+= scanned

            // Hand the GPU back for a moment. Without this the compositor can
            // be starved by back-to-back compute kernels and the whole app
            // stops drawing, which looks exactly like a hang.
            if metalEngine != nil { Thread.sleep(forTimeInterval: 0.004) }

            let now = Date()
            if now.timeIntervalSince(lastPublish) >= 0.25 {
                let window = now.timeIntervalSince(lastPublish)
                let r = window > 0 ? Double(scannedSinceTick) / window : 0
                let total = totalScanned
                let el = now.timeIntervalSince(started)
                post {
                    $0.keysScanned = total
                    $0.rate = r
                    $0.peakRate = max($0.peakRate, r)
                    $0.elapsed = el
                    $0.history.append(r)
                    if $0.history.count > 300 { $0.history.removeFirst($0.history.count - 300) }
                }
                lastPublish = now
                scannedSinceTick = 0
            }
        }

        if let chunkCoordinator {
            do { try chunkCoordinator.flushProgress() }
            catch { post { $0.note("Final puzzle progress checkpoint failed: \(error.localizedDescription)", .bad) } }
        }

        let total = totalScanned
        post {
            $0.keysScanned = total
            $0.rate = 0
            $0.state = .idle
            $0.note("Stopped after \($0.formatCount(total)) keys.", .info)
        }
    }

    private enum EngineRef { case metal(MetalEngine) }

    /// Every reported hit is re-derived from scratch and the address rebuilt
    /// and string-compared. Nothing reaches the UI unverified — a bug in the
    /// GPU filter can cost throughput, never correctness.
    private func verify(_ hits: [RawHit], engine: EngineRef, totalScanned: UInt64) {
        guard !hits.isEmpty else { return }
        for hit in hits {
            let key: U256?
            switch engine {
            case .metal(let e): key = e.privateKey(for: hit)
            }
            guard let key, !key.isZero else {
                post { $0.note("A hit could not be traced back to a key — ignored.", .warn) }
                continue
            }
            let point = Secp256k1.multiplyG(key)
            guard let built = Self.address(for: point, kind: hit.kind) else { continue }

            post { c in
                guard let target = c.parsedTargets.first(where: {
                    c.matches(address: built.address, target: $0, kind: hit.kind)
                }) else {
                    c.note("Flagged \(built.address) but no prefix actually matches — discarded.", .warn)
                    return
                }
                let found = FoundKey(address: built.address,
                                     kindRaw: hit.kind.rawValue,
                                     privateKeyHex: key.hexString,
                                     wif: WIF.encode(key, compressed: hit.kind != .p2pkhUncompressed),
                                     publicKeyHex: built.pubkey.hexString,
                                     targetText: target.text,
                                     foundAt: Date(),
                                     keysScannedWhenFound: totalScanned)
                if c.results.contains(where: { $0.privateKeyHex == found.privateKeyHex
                                            && $0.address == found.address }) { return }
                c.results.insert(found, at: 0)
                c.note("FOUND  \(built.address)", .good)
                if c.autoSaveResults { ResultStore.append(found) }
                if c.stopOnFirstHit { c.stop() }
            }
        }
    }

    /// Builds the canonical address string for a point. Public so the
    /// verification target can use it without `@testable`.
    public static func address(for point: ECPoint, kind: AddressKind) -> (address: String, pubkey: [UInt8])? {
        switch kind {
        case .p2pkhCompressed:
            let pk = Secp256k1.compressedPubkey(point)
            return (Base58.checkEncode(version: 0x00, payload: Hash.hash160(pk)), pk)
        case .p2pkhUncompressed:
            let pk = Secp256k1.uncompressedPubkey(point)
            return (Base58.checkEncode(version: 0x00, payload: Hash.hash160(pk)), pk)
        case .p2sh:
            let pk = Secp256k1.compressedPubkey(point)
            let redeem: [UInt8] = [0x00, 0x14] + Hash.hash160(pk)
            return (Base58.checkEncode(version: 0x05, payload: Hash.hash160(redeem)), pk)
        case .bech32:
            let pk = Secp256k1.compressedPubkey(point)
            guard let a = Bech32.encodeSegwit(hrp: "bc", witnessVersion: 0,
                                              program: Hash.hash160(pk)) else { return nil }
            return (a, pk)
        case .eth:
            let pk = Secp256k1.rawPubkey(point)
            return (EIP55.encode(Array(Hash.keccak256(pk)[12...])), pk)
        }
    }

    func matches(address: String, target: SearchTarget, kind: AddressKind) -> Bool {
        let kindOK = target.kind == kind
            || (target.kind == .p2pkhCompressed && kind == .p2pkhUncompressed)
        guard kindOK else { return false }
        if target.caseSensitive && kind != .eth {
            return address.hasPrefix(target.text)
        }
        return address.lowercased().hasPrefix(target.text.lowercased())
    }

    // MARK: cross-thread plumbing

    private func post(_ body: @escaping (SearchController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            body(self)
        }
    }

    public func note(_ text: String, _ level: LogLine.Level = .info) {
        SessionLog.write(text)
        log.append(LogLine(time: Date(), level: level, text: text))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    // MARK: formatting helpers used by the UI

    public func formatCount(_ v: UInt64) -> String {
        let d = Double(v)
        switch d {
        case ..<1_000: return "\(v)"
        case ..<1_000_000: return String(format: "%.2f K", d / 1e3)
        case ..<1_000_000_000: return String(format: "%.2f M", d / 1e6)
        case ..<1_000_000_000_000: return String(format: "%.2f G", d / 1e9)
        default: return String(format: "%.2f T", d / 1e12)
        }
    }

    public func formatRate(_ v: Double) -> String {
        switch v {
        case ..<1_000: return String(format: "%.0f key/s", v)
        case ..<1_000_000: return String(format: "%.1f Kkey/s", v / 1e3)
        case ..<1_000_000_000: return String(format: "%.2f Mkey/s", v / 1e6)
        default: return String(format: "%.2f Gkey/s", v / 1e9)
        }
    }

    public func formatDuration(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "∞" }
        if s < 1 { return "<1s" }
        if s < 60 { return String(format: "%.0fs", s) }
        if s < 3600 {
            return String(format: "%.0fm %02.0fs", (s / 60).rounded(.down),
                          s.truncatingRemainder(dividingBy: 60))
        }
        if s < 86_400 {
            return String(format: "%.0fh %02.0fm", (s / 3600).rounded(.down),
                          (s / 60).truncatingRemainder(dividingBy: 60))
        }
        let days = s / 86_400
        if days < 365 { return String(format: "%.1f days", days) }
        let years = days / 365.25
        if years < 1_000 { return String(format: "%.1f years", years) }
        return String(format: "%.2e years", years)
    }

    public func formatDifficulty(_ d: Double) -> String {
        guard d.isFinite else { return "—" }
        if d < 1_000 { return String(format: "%.0f", d) }
        if d < 1e15 { return String(format: "%.4g", d) }
        return String(format: "%.3e", d)
    }
}
