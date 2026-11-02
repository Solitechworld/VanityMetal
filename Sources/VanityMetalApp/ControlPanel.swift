//
//  ControlPanel.swift
//  VanityMetal
//
//  Everything you can turn, type or toggle before and during a run.
//

import SwiftUI
import VanityMetalCore

struct TargetsCard: View {
    @ObservedObject var c: SearchController
    @State private var newTarget: String = ""

    private var puzzleTargetLocked: Bool {
        c.selectedBitcoinPuzzleID != nil && c.state != .idle
    }

    var body: some View {
        Card(title: "Targets", accent: Neon.magenta, systemImage: "target",
             trailing: AnyView(Pill(text: "\(c.parsedTargets.count) ACTIVE", accent: Neon.magenta))) {
            VStack(alignment: .leading, spacing: 11) {

                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "BITCOIN PUZZLE PRESET")
                    Picker("Bitcoin Puzzle", selection: Binding(
                        get: { c.selectedBitcoinPuzzleID },
                        set: { c.selectBitcoinPuzzle($0) })) {
                        Text("Manual target / range").tag(Int?.none)
                        ForEach(c.bitcoinPuzzles) { puzzle in
                            Text("#\(puzzle.number) · \(puzzle.status.capitalized)")
                                .tag(Int?.some(puzzle.number))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(Neon.mono(11))
                    .tint(Neon.magenta)
                    .disabled(c.state != .idle || c.bitcoinPuzzles.isEmpty)
                    Text("Loads the published address and inclusive hex key range. Status is from the bundled catalog snapshot.")
                        .font(Neon.mono(9)).foregroundColor(Neon.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(c.targetInputs.enumerated()), id: \.offset) { pair in
                    TargetRow(c: c, index: pair.offset)
                }

                HStack(spacing: 7) {
                    TextField("address or prefix…", text: $newTarget)
                        .textFieldStyle(.plain)
                        .font(Neon.mono(12))
                        .foregroundColor(Neon.text)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Neon.hairline.opacity(0.7), lineWidth: 1))
                        .onSubmit(addTarget)
                        .disabled(puzzleTargetLocked)

                    Button(action: addTarget) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(NeonButtonStyle(accent: Neon.magenta, compact: true))
                    .frame(width: 44)
                    .disabled(puzzleTargetLocked
                              || newTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let err = c.parseError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text(err).font(Neon.mono(10))
                    }
                    .foregroundColor(Neon.rose)
                }

                Divider().overlay(Neon.hairline.opacity(0.4))

                VStack(alignment: .leading, spacing: 7) {
                    SectionLabel(text: "Match rules")
                    NeonToggle(label: "Case sensitive",
                               accent: Neon.magenta,
                               hint: "off is far easier to hit",
                               isOn: Binding(get: { c.caseSensitive },
                                             set: { c.caseSensitive = $0; c.refreshTargets() }))
                    NeonToggle(label: "Also search uncompressed keys",
                               accent: Neon.magenta,
                               hint: "doubles the work per key",
                               isOn: Binding(get: { c.searchUncompressed },
                                             set: { c.searchUncompressed = $0; c.refreshTargets() }))
                }

                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "Force address type")
                    Picker("", selection: Binding(get: { c.forcedKind },
                                                  set: { c.forcedKind = $0; c.refreshTargets() })) {
                        Text("Auto-detect").tag(AddressKind?.none)
                        ForEach(AddressKind.allCases) { k in
                            Text(k.shortTitle).tag(AddressKind?.some(k))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(Neon.mono(11))
                    .tint(Neon.magenta)
                }

                DifficultySummary(c: c)
            }
        }
    }

    private func addTarget() {
        guard !puzzleTargetLocked else { return }
        let t = newTarget.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        c.selectBitcoinPuzzle(nil)
        c.targetInputs.append(t)
        newTarget = ""
        c.refreshTargets()
    }
}

struct KeyRangeCard: View {
    @ObservedObject var c: SearchController
    @State private var showingResetConfirmation = false

    var body: some View {
        Card(title: "Private key range", accent: Neon.amber, systemImage: "arrow.left.and.right") {
            VStack(alignment: .leading, spacing: 9) {
                rangeField("Minimum key (hex)", text: $c.keyMinimumHex,
                           disabled: c.selectedBitcoinPuzzleID != nil)
                rangeField("Maximum key (hex)", text: $c.keyMaximumHex,
                           disabled: c.selectedBitcoinPuzzleID != nil)
                if c.selectedBitcoinPuzzleID != nil {
                    chunkSizeField
                    Text("GPU checks every key in each chunk (step 1). Chunks are picked randomly and progress is saved after each dispatch.")
                        .font(Neon.mono(9)).foregroundColor(Neon.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    if let progress = c.puzzleProgressText {
                        Text(progress).font(Neon.mono(9)).foregroundColor(Neon.lime)
                    }
                    HStack(spacing: 7) {
                        Text("CURRENT CHUNK")
                            .font(Neon.mono(8)).foregroundColor(Neon.textFaint)
                        Spacer(minLength: 4)
                        Text("\(Int(c.puzzleChunkProgress * 100))%")
                            .font(Neon.mono(9, .semibold)).foregroundColor(Neon.lime)
                    }
                    ProgressView(value: c.puzzleChunkProgress)
                        .tint(Neon.lime)
                    Button("Reset saved puzzle progress") {
                        showingResetConfirmation = true
                    }
                        .buttonStyle(NeonButtonStyle(accent: Neon.rose, compact: true))
                        .disabled(c.state != .idle)
                        .confirmationDialog(
                            "Reset saved puzzle progress?",
                            isPresented: $showingResetConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Reset Progress", role: .destructive) {
                                c.resetSelectedPuzzleProgress()
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("This clears the saved chunks for the selected Bitcoin Puzzle. This cannot be undone.")
                        }
                } else {
                    rangeField("Minimum step", text: $c.keyMinimumStepText)
                    rangeField("Maximum step", text: $c.keyMaximumStepText)
                    Text("Each pass starts at min, uses one random step in the limits above, and stops at max. Then it returns to min and chooses a new step.")
                        .font(Neon.mono(9)).foregroundColor(Neon.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = c.keyRangeError {
                    Text(error).font(Neon.mono(9)).foregroundColor(Neon.rose)
                }
            }
        }
    }

    private var chunkSizeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Chunk size (keys, decimal)")
            TextField("100000000", text: $c.puzzleChunkSizeText)
                .textFieldStyle(.plain)
                .font(Neon.mono(10))
                .foregroundColor(Neon.text)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Neon.hairline.opacity(0.7), lineWidth: 1))
                .disabled(c.state != .idle)
                .onChange(of: c.puzzleChunkSizeText) { _ in
                    do { _ = try c.currentPuzzleChunkSize(); c.keyRangeError = nil }
                    catch { c.keyRangeError = error.localizedDescription }
                }
        }
    }

    private func rangeField(_ title: String, text: Binding<String>, disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: title)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .font(Neon.mono(10))
                .foregroundColor(Neon.text)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Neon.hairline.opacity(0.7), lineWidth: 1))
                .disabled(c.state != .idle || disabled)
                .onChange(of: text.wrappedValue) { _ in
                    do { _ = try c.currentKeyRange(); c.keyRangeError = nil }
                    catch { c.keyRangeError = error.localizedDescription }
                }
        }
    }
}

private struct TargetRow: View {
    @ObservedObject var c: SearchController
    let index: Int

    private var puzzleTargetLocked: Bool {
        c.selectedBitcoinPuzzleID != nil && c.state != .idle
    }

    var parsed: SearchTarget? {
        guard index < c.targetInputs.count else { return nil }
        return c.parsedTargets.first { $0.text == c.targetInputs[index] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                TextField("address or prefix", text: Binding(
                    get: { index < c.targetInputs.count ? c.targetInputs[index] : "" },
                    set: {
                        if !puzzleTargetLocked, index < c.targetInputs.count {
                            c.selectBitcoinPuzzle(nil)
                            c.targetInputs[index] = $0
                            c.refreshTargets()
                        }
                    }))
                    .textFieldStyle(.plain)
                    .font(Neon.mono(12.5, .semibold))
                    .foregroundColor(parsed == nil ? Neon.rose : Neon.lime)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder((parsed == nil ? Neon.rose : Neon.lime).opacity(0.5), lineWidth: 1))
                    .disabled(puzzleTargetLocked)

                Button {
                    guard !puzzleTargetLocked, index < c.targetInputs.count else { return }
                    c.selectBitcoinPuzzle(nil)
                    c.targetInputs.remove(at: index)
                    c.refreshTargets()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(NeonButtonStyle(accent: Neon.rose, compact: true))
                .frame(width: 34)
                .disabled(puzzleTargetLocked)
            }
            if let p = parsed {
                HStack(spacing: 6) {
                    Pill(text: p.kind.shortTitle, accent: Neon.cyan)
                    Text("1 in \(c.formatDifficulty(p.difficulty))")
                        .font(Neon.mono(9.5))
                        .foregroundColor(Neon.textDim)
                    if p.ranges.count > 1 {
                        Text("· \(p.ranges.count) ranges")
                            .font(Neon.mono(9)).foregroundColor(Neon.textFaint)
                    }
                }
            }
        }
    }
}

private struct DifficultySummary: View {
    @ObservedObject var c: SearchController

    var body: some View {
        let d = c.combinedDifficulty
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(text: "Combined")
            HStack(spacing: 8) {
                Text("1 in \(c.formatDifficulty(d))")
                    .font(Neon.mono(13, .bold))
                    .foregroundColor(Neon.amber)
                    .glow(Neon.amber, radius: 6, intensity: 0.5)
                Spacer()
                if c.rate > 0 {
                    Text("50% in \(c.formatDuration(c.fiftyPercentSeconds))")
                        .font(Neon.mono(10))
                        .foregroundColor(Neon.textDim)
                }
            }
            Text("Base58 prefixes are not uniform — VanityMetal computes the true range, so this figure is exact rather than the usual 58ⁿ guess.")
                .font(Neon.mono(9))
                .foregroundColor(Neon.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Neon.amber.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Neon.amber.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Engine card

struct EngineCard: View {
    @ObservedObject var c: SearchController

    var body: some View {
        Card(title: "Engine", accent: Neon.cyan, systemImage: "cpu",
             trailing: AnyView(ThermalPip(state: c.thermalState))) {
            VStack(alignment: .leading, spacing: 12) {

                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "Compute")
                    Text("GPU only")
                        .font(Neon.mono(11, .semibold)).foregroundColor(Neon.cyan)
                }

                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "GPU device")
                    Picker("", selection: $c.selectedDeviceID) {
                        ForEach(c.devices) { d in
                            Text(d.name).tag(UInt64?.some(d.id))
                        }
                        if c.devices.isEmpty { Text("none").tag(UInt64?.none) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(Neon.mono(11))
                    .tint(Neon.cyan)
                    .disabled(c.state != .idle || c.devices.isEmpty)

                    if let d = c.devices.first(where: { $0.id == c.selectedDeviceID }) {
                        Text(d.summary).font(Neon.mono(9)).foregroundColor(Neon.textFaint)
                    }
                }

                NeonSlider(label: "GPU walkers",
                           range: 0...65536, step: 256,
                           accent: Neon.cyan,
                           format: { $0 == 0 ? "AUTO" : "\(Int($0))" },
                           value: Binding(get: { Double(c.gpuThreadCount) },
                                          set: { c.gpuThreadCount = Int($0) }))
                    .disabled(c.state != .idle)

                NeonSlider(label: "Dispatch window",
                           range: 10...500, step: 5,
                           accent: Neon.amber,
                           format: { String(format: "%.0f ms", $0) },
                           value: $c.dispatchWindowMs)
                Text("How long the GPU may run uninterrupted per submission. This caps latency, not speed — the engine measures your GPU and fits as many keys into the window as it can. Longer is marginally faster and makes the desktop choppier.")
                    .font(Neon.mono(9))
                    .foregroundColor(Neon.textFaint)
                    .fixedSize(horizontal: false, vertical: true)

                NeonSlider(label: "Steps per dispatch (override)",
                           range: 0...512, step: 8,
                           accent: Neon.amber,
                           format: { $0 == 0 ? "AUTO" : "\(Int($0))" },
                           value: Binding(get: { Double(c.batchIterations) },
                                          set: { c.batchIterations = Int($0) }))

                Divider().overlay(Neon.hairline.opacity(0.4))

                VStack(alignment: .leading, spacing: 7) {
                    SectionLabel(text: "Behaviour")
                    NeonToggle(label: "Thermal guard", accent: Neon.amber,
                               hint: "eases off when the Mac gets hot",
                               isOn: $c.thermalGuard)
                    NeonToggle(label: "Stop on first hit", accent: Neon.lime,
                               isOn: $c.stopOnFirstHit)
                    NeonToggle(label: "Auto-save found keys", accent: Neon.lime,
                               hint: "written to Application Support, 0600",
                               isOn: $c.autoSaveResults)
                }

                if let ok = c.gpuSelfTestPassed {
                    HStack(spacing: 6) {
                        Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .font(.system(size: 10))
                        Text(ok ? "GPU self-test passed" : "GPU self-test failed — using CPU")
                            .font(Neon.mono(9.5))
                    }
                    .foregroundColor(ok ? Neon.lime : Neon.rose)
                }
            }
        }
    }
}

private struct ThermalPip: View {
    let state: ProcessInfo.ThermalState

    var color: Color {
        switch state {
        case .nominal: return Neon.lime
        case .fair: return Neon.cyan
        case .serious: return Neon.amber
        case .critical: return Neon.rose
        @unknown default: return Neon.textDim
        }
    }
    var label: String {
        switch state {
        case .nominal: return "COOL"
        case .fair: return "WARM"
        case .serious: return "HOT"
        case .critical: return "THROTTLED"
        @unknown default: return "—"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "thermometer").font(.system(size: 9, weight: .bold))
            Text(label).font(Neon.mono(8.5, .bold)).kerning(1.1)
        }
        .foregroundColor(color)
    }
}
