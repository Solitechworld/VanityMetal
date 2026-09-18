//
//  ResultsPanel.swift
//  VanityMetal
//
//  Found keys. Private material stays masked until you ask for it, and the
//  export buttons hand you the whole set as text, CSV or JSON.
//

import SwiftUI
import AppKit
import VanityMetalCore

struct ResultsCard: View {
    @ObservedObject var c: SearchController
    @State private var revealed: Set<UUID> = []

    var body: some View {
        Card(title: "Found keys", accent: Neon.lime, systemImage: "key.fill",
             trailing: AnyView(
                HStack(spacing: 6) {
                    Pill(text: "\(c.results.count)", accent: Neon.lime)
                    if !c.results.isEmpty {
                        IconChip(system: "square.and.arrow.up", label: "EXPORT",
                                 accent: Neon.lime) { export() }
                            .fixedSize()
                        IconChip(system: "trash", label: "CLEAR", accent: Neon.rose) {
                            c.clearResults(); revealed.removeAll()
                        }
                        .fixedSize()
                    }
                }
             )) {
            if c.results.isEmpty {
                EmptyResults()
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(c.results) { key in
                            ResultRow(key: key,
                                      revealed: revealed.contains(key.id),
                                      toggleReveal: {
                                          if revealed.contains(key.id) { revealed.remove(key.id) }
                                          else { revealed.insert(key.id) }
                                      })
                        }
                    }
                    .padding(.bottom, 2)
                }
                .frame(maxHeight: 320)
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export found keys"
        panel.nameFieldStringValue = "vanitymetal-keys.txt"
        panel.message = "These files contain private keys. Store them the way you would store a wallet."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            let body: String
            switch ext {
            case "csv": body = ResultStore.csv(c.results)
            case "json":
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted]
                enc.dateEncodingStrategy = .iso8601
                body = (try? enc.encode(c.results)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            default: body = ResultStore.plainText(c.results)
            }
            try? body.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
            c.note("Exported \(c.results.count) key(s) to \(url.lastPathComponent).", .good)
        }
    }
}

private struct EmptyResults: View {
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "scope")
                .font(.system(size: 26, weight: .thin))
                .foregroundColor(Neon.cyan.opacity(0.5))
                .glow(Neon.cyan, radius: 12, intensity: 0.4)
            Text("No keys yet")
                .font(Neon.mono(12, .bold)).foregroundColor(Neon.textDim)
            Text("Every hit is re-derived and the address rebuilt on the CPU\nbefore it appears here.")
                .font(Neon.mono(9.5))
                .multilineTextAlignment(.center)
                .foregroundColor(Neon.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

private struct ResultRow: View {
    let key: FoundKey
    let revealed: Bool
    let toggleReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Pill(text: key.kind.shortTitle, accent: Neon.cyan)
                Text(key.address)
                    .font(Neon.mono(12, .bold))
                    .foregroundColor(Neon.lime)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                CopyChip(text: key.address, label: "ADDR")
            }

            HStack(spacing: 8) {
                Text("matched")
                    .font(Neon.mono(9)).foregroundColor(Neon.textFaint)
                Text(key.targetText)
                    .font(Neon.mono(9.5, .bold)).foregroundColor(Neon.magenta)
                Spacer()
                Text(key.foundAt, style: .time)
                    .font(Neon.mono(9)).foregroundColor(Neon.textFaint)
            }

            VStack(alignment: .leading, spacing: 5) {
                SecretLine(label: "WIF", value: key.wif, revealed: revealed)
                SecretLine(label: "HEX", value: key.privateKeyHex, revealed: revealed)
            }

            HStack(spacing: 6) {
                Button(action: toggleReveal) {
                    HStack(spacing: 5) {
                        Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(revealed ? "HIDE" : "REVEAL")
                    }
                }
                .buttonStyle(NeonButtonStyle(accent: Neon.amber, compact: true))

                CopyChip(text: key.wif, label: "COPY WIF", accent: Neon.amber)
                CopyChip(text: key.privateKeyHex, label: "COPY HEX", accent: Neon.amber)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11).fill(Neon.lime.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Neon.lime.opacity(0.28), lineWidth: 1))
    }
}

private struct SecretLine: View {
    let label: String
    let value: String
    let revealed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(Neon.mono(8.5, .bold)).kerning(1.0)
                .foregroundColor(Neon.textFaint)
                .frame(width: 30, alignment: .leading)
            Text(revealed ? value : String(repeating: "•", count: min(value.count, 52)))
                .font(Neon.mono(10))
                .foregroundColor(revealed ? Neon.amber : Neon.textFaint)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct CopyChip: View {
    let text: String
    let label: String
    var accent: Color = Neon.cyan
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .bold))
                Text(copied ? "COPIED" : label)
            }
        }
        .buttonStyle(NeonButtonStyle(accent: copied ? Neon.lime : accent, compact: true))
        .fixedSize()
    }
}

// MARK: - Console

struct ConsoleCard: View {
    @ObservedObject var c: SearchController

    var body: some View {
        Card(title: "Console", accent: Neon.violet, systemImage: "terminal") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(c.log) { line in
                            HStack(alignment: .top, spacing: 7) {
                                Text(Self.stamp.string(from: line.time))
                                    .font(Neon.mono(9))
                                    .foregroundColor(Neon.textFaint)
                                Text(line.text)
                                    .font(Neon.mono(9.5))
                                    .foregroundColor(color(line.level))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .id(line.id)
                        }
                    }
                }
                .frame(height: 132)
                .onChange(of: c.log.count) { _ in
                    if let last = c.log.last {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func color(_ l: SearchController.LogLine.Level) -> Color {
        switch l {
        case .info: return Neon.textDim
        case .good: return Neon.lime
        case .warn: return Neon.amber
        case .bad:  return Neon.rose
        }
    }
}
