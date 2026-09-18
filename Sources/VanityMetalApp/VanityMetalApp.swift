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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct VanityMetalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = SearchController()

    var body: some Scene {
        WindowGroup("VanityMetal") {
            ContentView(c: controller)
                .onAppear { loadPrefs() }
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
