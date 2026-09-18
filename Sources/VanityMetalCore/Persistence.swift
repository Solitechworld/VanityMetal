//
//  Persistence.swift
//  VanityMetal
//
//  Found keys are written to disk the moment they are verified, so a crash,
//  a closed lid or a stray Cmd-Q can never lose one.
//

import Foundation

public enum ResultStore {

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("VanityMetal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    public static var fileURL: URL { directory.appendingPathComponent("found-keys.json") }

    /// On disk the list is oldest-first; the UI wants newest-first.
    private static func loadRaw() -> [FoundKey] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([FoundKey].self, from: data)) ?? []
    }

    public static func load() -> [FoundKey] {
        Array(loadRaw().reversed())
    }

    public static func append(_ key: FoundKey) {
        var all = loadRaw()
        guard !all.contains(where: { $0.privateKeyHex == key.privateKeyHex && $0.address == key.address })
        else { return }
        all.append(key)
        write(all)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func write(_ keys: [FoundKey]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(keys) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // Private keys: owner-only, always.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: Export

    public static func plainText(_ keys: [FoundKey]) -> String {
        let header = """
        VanityMetal — found keys
        Exported \(ISO8601DateFormatter().string(from: Date()))
        Treat this file as you would a wallet: anyone holding these private
        keys controls the corresponding addresses.

        """
        return header + "\n" + keys.map(\.exportLine).joined(separator: "\n\n" + String(repeating: "─", count: 60) + "\n\n")
    }

    public static func csv(_ keys: [FoundKey]) -> String {
        var out = "address,type,private_key_hex,wif,public_key_hex,matched_prefix,found_at\n"
        for k in keys {
            let fields = [k.address, k.kind.shortTitle, k.privateKeyHex, k.wif,
                          k.publicKeyHex, k.targetText,
                          ISO8601DateFormatter().string(from: k.foundAt)]
            out += fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                         .joined(separator: ",") + "\n"
        }
        return out
    }
}

/// A plain-text log written next to the app bundle. Invaluable when the UI
/// itself is the thing misbehaving and you cannot read the on-screen console.
public enum SessionLog {
    private static let queue = DispatchQueue(label: "vanitymetal.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static let url: URL = {
        // Prefer sitting beside the .app so it is easy to find; fall back to
        // Application Support if that directory is not writable.
        let beside = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("session.log")
        if FileManager.default.isWritableFile(atPath: beside.deletingLastPathComponent().path) {
            return beside
        }
        return ResultStore.directory.appendingPathComponent("session.log")
    }()

    public static func start() {
        queue.async {
            let header = "\n===== VanityMetal session \(ISO8601DateFormatter().string(from: Date())) =====\n"
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public static func write(_ line: String) {
        queue.async {
            let stamped = "[\(formatter.string(from: Date()))] \(line)\n"
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? stamped.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Session settings that survive relaunch

public enum Prefs {
    private static let d = UserDefaults.standard

    public static var targets: [String] {
        get { d.stringArray(forKey: "vm.targets") ?? ["1Neo"] }
        set { d.set(newValue, forKey: "vm.targets") }
    }
    public static var engineMode: String {
        get { d.string(forKey: "vm.engineMode") ?? EngineMode.gpu.rawValue }
        set { d.set(newValue, forKey: "vm.engineMode") }
    }
    public static var caseSensitive: Bool {
        get { d.object(forKey: "vm.caseSensitive") as? Bool ?? true }
        set { d.set(newValue, forKey: "vm.caseSensitive") }
    }
    public static var thermalGuard: Bool {
        get { d.object(forKey: "vm.thermalGuard") as? Bool ?? true }
        set { d.set(newValue, forKey: "vm.thermalGuard") }
    }
    public static var autoSave: Bool {
        get { d.object(forKey: "vm.autoSave") as? Bool ?? true }
        set { d.set(newValue, forKey: "vm.autoSave") }
    }
    public static var gpuThreads: Int {
        get { d.integer(forKey: "vm.gpuThreads") }
        set { d.set(newValue, forKey: "vm.gpuThreads") }
    }
    public static var cpuThreads: Int {
        get { d.integer(forKey: "vm.cpuThreads") }
        set { d.set(newValue, forKey: "vm.cpuThreads") }
    }
}
