//
//  StatsPanel.swift
//  VanityMetal
//
//  The live dashboard: throughput readout, KPI tiles, a rolling hashrate
//  trace and the probability meter.
//

import SwiftUI
import VanityMetalCore

struct StatsCard: View {
    @ObservedObject var c: SearchController

    var body: some View {
        Card(title: "Telemetry", accent: Neon.lime, systemImage: "waveform.path.ecg",
             trailing: AnyView(
                Text(c.activeDeviceName)
                    .font(Neon.mono(9.5, .semibold))
                    .foregroundColor(Neon.textDim)
                    .lineLimit(1)
             )) {
            VStack(alignment: .leading, spacing: 13) {

                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(c.formatRate(c.rate))
                        .font(Neon.mono(31, .bold))
                        .foregroundColor(Neon.lime)
                        .glow(Neon.lime, radius: 14, intensity: 0.7)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("PEAK").font(Neon.mono(8, .semibold)).kerning(1.3)
                            .foregroundColor(Neon.textFaint)
                        Text(c.formatRate(c.peakRate))
                            .font(Neon.mono(11, .bold)).foregroundColor(Neon.cyan)
                    }
                }

                HashrateTrace(history: c.history, accent: Neon.lime)
                    .frame(height: 84)

                let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)]
                LazyVGrid(columns: cols, spacing: 8) {
                    StatTile(label: "Keys scanned", value: c.formatCount(c.keysScanned),
                             accent: Neon.cyan)
                    StatTile(label: "Elapsed", value: c.formatDuration(c.elapsed),
                             accent: Neon.cyan)
                    StatTile(label: "Walkers", value: "\(c.activeWalkers)",
                             sub: "\(KernelConstants.groupSize) keys/step", accent: Neon.violet)
                    StatTile(label: "Difficulty",
                             value: "1:\(c.formatDifficulty(c.combinedDifficulty))",
                             accent: Neon.amber)
                    StatTile(label: "50% chance in",
                             value: c.formatDuration(c.fiftyPercentSeconds),
                             accent: Neon.amber)
                    StatTile(label: "Mean time",
                             value: c.formatDuration(c.expectedSeconds),
                             accent: Neon.amber)
                }

                ProbabilityMeter(p: c.probabilitySoFar)
            }
        }
    }
}

// MARK: - Rolling hashrate trace

struct HashrateTrace: View {
    let history: [Double]
    var accent: Color = Neon.lime

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = max(history.max() ?? 1, 1)
            ZStack {
                // grid
                Canvas { ctx, size in
                    var grid = Path()
                    for i in 1..<4 {
                        let y = size.height * CGFloat(i) / 4
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    for i in 1..<8 {
                        let x = size.width * CGFloat(i) / 8
                        grid.move(to: CGPoint(x: x, y: 0))
                        grid.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    ctx.stroke(grid, with: .color(Neon.hairline.opacity(0.30)), lineWidth: 0.5)
                }

                if history.count > 1 {
                    Canvas { ctx, size in
                        let n = history.count
                        func point(_ i: Int) -> CGPoint {
                            let x = size.width * CGFloat(i) / CGFloat(max(n - 1, 1))
                            let y = size.height * (1 - CGFloat(history[i] / maxV))
                            return CGPoint(x: x, y: y * 0.94 + size.height * 0.03)
                        }
                        var line = Path()
                        line.move(to: point(0))
                        for i in 1..<n { line.addLine(to: point(i)) }

                        var fill = line
                        fill.addLine(to: CGPoint(x: size.width, y: size.height))
                        fill.addLine(to: CGPoint(x: 0, y: size.height))
                        fill.closeSubpath()

                        ctx.fill(fill, with: .linearGradient(
                            Gradient(colors: [accent.opacity(0.32), accent.opacity(0.0)]),
                            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                        ctx.stroke(line, with: .color(accent), lineWidth: 1.6)

                        // leading dot
                        let last = point(n - 1)
                        ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3,
                                                        width: 6, height: 6)),
                                 with: .color(accent))
                    }
                    .glow(accent, radius: 9, intensity: 0.55)
                } else {
                    Text("awaiting signal…")
                        .font(Neon.mono(10))
                        .foregroundColor(Neon.textFaint)
                        .frame(width: w, height: h)
                }

                VStack {
                    HStack {
                        Spacer()
                        Text(maxV > 1 ? shortRate(maxV) : "")
                            .font(Neon.mono(8.5))
                            .foregroundColor(Neon.textFaint)
                            .padding(4)
                    }
                    Spacer()
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.30)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Neon.hairline.opacity(0.5), lineWidth: 1))
    }

    private func shortRate(_ v: Double) -> String {
        if v > 1e9 { return String(format: "%.1fG", v / 1e9) }
        if v > 1e6 { return String(format: "%.1fM", v / 1e6) }
        if v > 1e3 { return String(format: "%.0fK", v / 1e3) }
        return String(format: "%.0f", v)
    }
}

// MARK: - Probability meter

struct ProbabilityMeter: View {
    let p: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SectionLabel(text: "Probability a hit has occurred by now")
                Spacer()
                Text(String(format: "%.2f%%", min(p, 1) * 100))
                    .font(Neon.mono(11, .bold))
                    .foregroundColor(Neon.magenta)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.45))
                    Capsule()
                        .fill(LinearGradient(colors: [Neon.cyan, Neon.magenta],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, geo.size.width * CGFloat(min(p, 1))))
                        .glow(Neon.magenta, radius: 8, intensity: 0.6)
                }
            }
            .frame(height: 8)
            .overlay(Capsule().strokeBorder(Neon.hairline.opacity(0.6), lineWidth: 1))
        }
    }
}
