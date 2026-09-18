//
//  ContentView.swift
//  VanityMetal
//

import SwiftUI
import AppKit
import VanityMetalCore

struct ContentView: View {
    @ObservedObject var c: SearchController
    @AppStorage("vm.animatedBackground") private var animatedBackground = true
    @AppStorage("vm.backgroundIntensity") private var backgroundIntensity = 1.0
    @State private var showAbout = false

    var body: some View {
        ZStack {
            CyberBackground(animated: animatedBackground,
                            intensity: backgroundIntensity,
                            fps: (c.state == .running || c.state == .preparing) ? 8 : 30)

            VStack(spacing: 0) {
                HeaderBar(c: c, showAbout: $showAbout,
                          animatedBackground: $animatedBackground)

                HStack(alignment: .top, spacing: 14) {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            TargetsCard(c: c)
                            EngineCard(c: c)
                            VisualsCard(animated: $animatedBackground,
                                        intensity: $backgroundIntensity)
                        }
                        .padding(.bottom, 14)
                    }
                    .frame(width: 350)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            StatsCard(c: c)
                            ResultsCard(c: c)
                            ConsoleCard(c: c)
                        }
                        .padding(.bottom, 14)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                ActionBar(c: c, showAbout: $showAbout)
            }
        }
        .frame(minWidth: 1080, minHeight: 720)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAbout) { AboutSheet(isPresented: $showAbout) }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @ObservedObject var c: SearchController
    @Binding var showAbout: Bool
    @Binding var animatedBackground: Bool

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Neon.cyan.opacity(0.35), Neon.magenta.opacity(0.3)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 34, height: 34)
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Neon.cyan)
                }
                .glow(Neon.cyan, radius: 12, intensity: 0.8)

                VStack(alignment: .leading, spacing: 0) {
                    Text("VANITYMETAL")
                        .font(Neon.mono(17, .black)).kerning(3.4)
                        .foregroundColor(Neon.text)
                        .glow(Neon.cyan, radius: 10, intensity: 0.5)
                    Text("GPU vanity address engine · Metal · Apple Silicon & T2")
                        .font(Neon.mono(8.5)).kerning(0.6)
                        .foregroundColor(Neon.textFaint)
                }
            }

            Spacer()

            HStack(spacing: 9) {
                if c.state == .running || c.state == .paused {
                    Text(c.formatRate(c.rate))
                        .font(Neon.mono(12, .bold))
                        .foregroundColor(Neon.lime)
                        .glow(Neon.lime, radius: 8, intensity: 0.5)
                }
                Pill(text: c.activeDeviceName, accent: Neon.cyan)
                StatusBadge(state: c.state)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(LinearGradient(colors: [Neon.cyan.opacity(0.55), Neon.magenta.opacity(0.45)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 1)
                }
        )
    }
}

// MARK: - Visual settings

private struct VisualsCard: View {
    @Binding var animated: Bool
    @Binding var intensity: Double

    var body: some View {
        Card(title: "Visuals", accent: Neon.violet, systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                NeonToggle(label: "Animated cyberspace", accent: Neon.violet,
                           hint: "turn off to give every cycle to the search",
                           isOn: $animated)
                NeonSlider(label: "Backdrop intensity", range: 0...1, step: 0.05,
                           accent: Neon.violet,
                           format: { String(format: "%.0f%%", $0 * 100) },
                           value: $intensity)
            }
        }
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @ObservedObject var c: SearchController
    @Binding var showAbout: Bool

    private var primaryLabel: String {
        switch c.state {
        case .running: return "PAUSE"
        case .paused: return "RESUME"
        case .preparing: return "ARMING…"
        case .stopping: return "STOPPING…"
        case .idle: return "START SCAN"
        }
    }
    private var primaryIcon: String {
        switch c.state {
        case .running: return "pause.fill"
        case .paused: return "play.fill"
        default: return "play.fill"
        }
    }
    private var primaryAccent: Color {
        switch c.state {
        case .running: return Neon.amber
        case .paused: return Neon.lime
        default: return Neon.lime
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Button { c.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: primaryIcon).font(.system(size: 12, weight: .black))
                    Text(primaryLabel)
                }
            }
            .buttonStyle(NeonButtonStyle(accent: primaryAccent, filled: true))
            .frame(width: 190)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(c.state == .preparing || c.state == .stopping)

            Button { c.stop() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                    Text("STOP")
                }
            }
            .buttonStyle(NeonButtonStyle(accent: Neon.rose))
            .frame(width: 110)
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(c.state == .idle)

            Divider().frame(height: 24).overlay(Neon.hairline)

            IconChip(system: "dice", label: "RESEED", accent: Neon.violet) { c.reseed() }
            IconChip(system: "speedometer", label: "BENCHMARK", accent: Neon.cyan) { c.runBenchmark() }
            IconChip(system: "checkmark.shield", label: "SELF-TEST", accent: Neon.cyan) { c.runSelfTestOnly() }
            IconChip(system: "folder", label: "DATA FOLDER", accent: Neon.textDim) {
                NSWorkspace.shared.activateFileViewerSelecting([ResultStore.fileURL])
            }
            IconChip(system: "questionmark.circle", label: "ABOUT", accent: Neon.magenta) {
                showAbout = true
            }

            Spacer(minLength: 8)

            Text("\(c.formatCount(c.keysScanned)) keys · \(c.formatDuration(c.elapsed))")
                .font(Neon.mono(10))
                .foregroundColor(Neon.textDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            Rectangle()
                .fill(Color.black.opacity(0.42))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(LinearGradient(colors: [Neon.magenta.opacity(0.45), Neon.cyan.opacity(0.5)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 1)
                }
        )
    }
}

// MARK: - About

private struct AboutSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Neon.void, Neon.deep], startPoint: .top, endPoint: .bottom)
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 26)).foregroundColor(Neon.cyan)
                            .glow(Neon.cyan, radius: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("VANITYMETAL").font(Neon.mono(17, .black)).kerning(3)
                                .foregroundColor(Neon.text)
                            Text("version 1.0 · standalone").font(Neon.mono(9))
                                .foregroundColor(Neon.textFaint)
                        }
                    }

                    section("What it is", Neon.cyan, """
                    A GPU vanity-address generator written from scratch for Apple hardware. \
                    Where VanitySearch uses CUDA, VanityMetal uses Metal compute — so it runs on \
                    Apple Silicon and on the Intel and AMD GPUs in T2 Macs, with no CUDA, no \
                    Homebrew, no Python and no external scripts.
                    """)

                    section("How the search works", Neon.violet, """
                    Each GPU thread holds a point on secp256k1 and walks it forward. For every \
                    step it generates 129 public keys at once — the centre point plus 64 on each \
                    side — and a Montgomery batch inversion turns what would be 129 modular \
                    inverses into one. All the field arithmetic, SHA-256, RIPEMD-160 and \
                    Keccak-256 run on the GPU; the CPU only handles what the GPU flags.
                    """)

                    section("Why the difficulty looks different", Neon.amber, """
                    Most tools quote 58ⁿ for an n-character Base58 prefix. That is wrong, because \
                    Base58 digits do not line up with the 160-bit hash and the leading characters \
                    are not uniformly distributed. VanityMetal converts your prefix into exact \
                    inclusive ranges over the hash, so the difficulty shown is the real one — \
                    often several times easier than the naïve figure.
                    """)

                    section("Trust, but verify", Neon.lime, """
                    The GPU is treated as a filter, never as an oracle. Every hit it reports is \
                    re-derived on the CPU from the private key, the address is rebuilt and \
                    string-compared, and only then does it appear. A numerical bug on the GPU \
                    could cost throughput; it cannot hand you a wrong key. The shader also runs \
                    known-answer tests at launch, and falls back to the CPU engine if they fail.
                    """)

                    section("Keep your keys safe", Neon.rose, """
                    Anything found here is a real private key. Found keys are saved to \
                    Application Support with owner-only permissions, and exports are written the \
                    same way. Anyone who obtains one of these keys controls the address — treat \
                    the files exactly as you would treat a wallet, and move funds to a vanity \
                    address only once you are happy with how you are storing it.
                    """)

                    Button("CLOSE") { isPresented = false }
                        .buttonStyle(NeonButtonStyle(accent: Neon.cyan, filled: true))
                        .frame(width: 160)
                        .padding(.top, 4)
                }
                .padding(26)
            }
        }
        .frame(width: 620, height: 640)
    }

    private func section(_ title: String, _ accent: Color, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Rectangle().fill(accent).frame(width: 3, height: 12).glow(accent, radius: 5)
                Text(title.uppercased()).font(Neon.mono(10, .bold)).kerning(1.7)
                    .foregroundColor(accent)
            }
            Text(body)
                .font(Neon.mono(10.5))
                .foregroundColor(Neon.textDim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
