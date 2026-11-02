//
//  VanityMetalApp.swift
//  VanityMetal
//
//  Entry point. Also nudges the activation policy so the app behaves like a
//  normal windowed app even when the binary is launched straight from a
//  terminal rather than from the .app bundle.
//

import SwiftUI
import AppKit
import VanityMetalCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusTimer: Timer?
    private weak var searchController: SearchController?
    private var stateMenuItem: NSMenuItem?
    private var speedMenuItem: NSMenuItem?
    private var scannedMenuItem: NSMenuItem?
    private var foundMenuItem: NSMenuItem?
    private var toggleMenuItem: NSMenuItem?
    private var stopMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func configureStatusItem(for controller: SearchController) {
        searchController = controller
        guard statusItem == nil else {
            refreshStatusItem()
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "VanityMetal")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.toolTip = "VanityMetal GPU search status"
        }

        let menu = NSMenu()
        stateMenuItem = menu.addItem(withTitle: "State: Idle", action: nil, keyEquivalent: "")
        speedMenuItem = menu.addItem(withTitle: "Speed: —", action: nil, keyEquivalent: "")
        scannedMenuItem = menu.addItem(withTitle: "Checked: 0", action: nil, keyEquivalent: "")
        foundMenuItem = menu.addItem(withTitle: "Found: 0", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        toggleMenuItem = menu.addItem(withTitle: "Start Search", action: #selector(toggleSearch), keyEquivalent: "")
        toggleMenuItem?.target = self
        stopMenuItem = menu.addItem(withTitle: "Stop Search", action: #selector(stopSearch), keyEquivalent: "")
        stopMenuItem?.target = self
        menu.addItem(.separator())

        let openItem = menu.addItem(withTitle: "Open VanityMetal", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        let quitItem = menu.addItem(withTitle: "Quit VanityMetal", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        item.menu = menu
        statusItem = item

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStatusItem()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        guard let controller = searchController else { return }
        let found = controller.results.count
        let rate = shortRate(controller.rate)
        let isActive = controller.state == .running || controller.state == .paused

        statusItem?.button?.title = "\(isActive ? rate : controller.state.label.capitalized) · \(found)"
        stateMenuItem?.title = "State: \(controller.state.label.capitalized)"
        speedMenuItem?.title = "Speed: \(controller.formatRate(controller.rate))"
        scannedMenuItem?.title = "Checked: \(controller.formatCount(controller.keysScanned)) keys"
        foundMenuItem?.title = "Found: \(found) keys"

        switch controller.state {
        case .idle:
            toggleMenuItem?.title = "Start Search"
            toggleMenuItem?.isEnabled = true
        case .running:
            toggleMenuItem?.title = "Pause Search"
            toggleMenuItem?.isEnabled = true
        case .paused:
            toggleMenuItem?.title = "Resume Search"
            toggleMenuItem?.isEnabled = true
        case .preparing, .stopping:
            toggleMenuItem?.title = controller.state == .preparing ? "Preparing…" : "Stopping…"
            toggleMenuItem?.isEnabled = false
        }
        stopMenuItem?.isEnabled = controller.state != .idle && controller.state != .stopping
    }

    private func shortRate(_ value: Double) -> String {
        switch value {
        case ..<1_000: return String(format: "%.0f/s", value)
        case ..<1_000_000: return String(format: "%.0f K/s", value / 1_000)
        case ..<1_000_000_000: return String(format: "%.1f M/s", value / 1_000_000)
        default: return String(format: "%.1f G/s", value / 1_000_000_000)
        }
    }

    @objc private func toggleSearch() { searchController?.toggle() }
    @objc private func stopSearch() { searchController?.stop() }

    @objc private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}

@main
struct VanityMetalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = SearchController()

    var body: some Scene {
        WindowGroup("VanityMetal") {
            ContentView(c: controller)
                .onAppear {
                    appDelegate.configureStatusItem(for: controller)
                    loadPrefs()
                }
                .onDisappear { savePrefs() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Search") {
                Button("Start / Pause") { controller.toggle() }
                    .keyboardShortcut(.return, modifiers: [.command])
                Button("Stop") { controller.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                Divider()
                Button("Re-seed key space") { controller.reseed() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Benchmark (6s)") { controller.runBenchmark() }
                    .keyboardShortcut("b", modifiers: [.command])
                Button("Run GPU self-test") { controller.runSelfTestOnly() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Clear results") { controller.clearResults() }
            }
        }
    }

    private func loadPrefs() {
        controller.targetInputs = Prefs.targets
        controller.engineMode = EngineMode(rawValue: Prefs.engineMode) ?? .gpu
        controller.caseSensitive = Prefs.caseSensitive
        controller.thermalGuard = Prefs.thermalGuard
        controller.autoSaveResults = Prefs.autoSave
        controller.gpuThreadCount = Prefs.gpuThreads
        controller.cpuThreadCount = Prefs.cpuThreads
        controller.refreshTargets()
    }

    private func savePrefs() {
        Prefs.targets = controller.targetInputs
        Prefs.engineMode = controller.engineMode.rawValue
        Prefs.caseSensitive = controller.caseSensitive
        Prefs.thermalGuard = controller.thermalGuard
        Prefs.autoSave = controller.autoSaveResults
        Prefs.gpuThreads = controller.gpuThreadCount
        Prefs.cpuThreads = controller.cpuThreadCount
    }
}
