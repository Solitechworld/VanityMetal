//
//  CyberBackground.swift
//  VanityMetal
//
//  The animated cyberspace backdrop: drifting nebula glows, a perspective
//  floor grid receding to a vanishing point, a drifting star field, a scan
//  sweep and a vignette. Capped at 30 fps and fully switchable, because the
//  GPU's day job is finding keys, not drawing wallpaper.
//

import SwiftUI

struct CyberBackground: View {
    var animated: Bool = true
    var intensity: Double = 1.0
    /// Dropped while a search is running: the compute kernels and the window
    /// server share one GPU, and a full-rate animated backdrop is the fastest
    /// way to make a busy app look frozen.
    var fps: Double = 30

    var body: some View {
        ZStack {
            LinearGradient(colors: [Neon.void, Neon.deep, Neon.void],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            if animated {
                TimelineView(.animation(minimumInterval: 1.0 / max(fps, 1), paused: false)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    canvas(time: t)
                }
            } else {
                canvas(time: 0)
            }
        }
        // Deliberately no .drawingGroup(): it forces an offscreen Metal pass
        // every frame, which then queues behind the search kernels.
    }

    private func canvas(time t: TimeInterval) -> some View {
        Canvas(rendersAsynchronously: true) { ctx, size in
            drawNebula(ctx: &ctx, size: size, t: t)
            drawStars(ctx: &ctx, size: size, t: t)
            drawGrid(ctx: &ctx, size: size, t: t)
            drawScanlines(ctx: &ctx, size: size, t: t)
            drawVignette(ctx: &ctx, size: size)
        }
        .ignoresSafeArea()
        .opacity(intensity)
    }

    // MARK: layers

    private func drawNebula(ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let blobs: [(Color, CGFloat, CGFloat, Double, Double)] = [
            (Neon.cyan,    0.22, 0.18, 0.031, 0.9),
            (Neon.magenta, 0.82, 0.30, 0.023, 0.75),
            (Neon.violet,  0.55, 0.86, 0.017, 0.6)
        ]
        for (color, bx, by, speed, alpha) in blobs {
            let dx = CGFloat(sin(t * speed * 2.1)) * size.width * 0.08
            let dy = CGFloat(cos(t * speed * 1.6)) * size.height * 0.07
            let cx = size.width * bx + dx
            let cy = size.height * by + dy
            let r = min(size.width, size.height) * 0.62
            let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect),
                     with: .radialGradient(
                        Gradient(colors: [color.opacity(0.16 * alpha), .clear]),
                        center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r))
        }
    }

    private func drawStars(ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        var rng = SplitMix(seed: 0xC0FFEE)
        let horizon = size.height * 0.52
        for i in 0..<130 {
            let x = CGFloat(rng.nextUnit()) * size.width
            let y = CGFloat(rng.nextUnit()) * horizon
            let base = rng.nextUnit()
            let twinkle = 0.35 + 0.65 * abs(sin(t * (0.5 + base) + Double(i)))
            let r: CGFloat = base > 0.93 ? 1.6 : 0.9
            let color = base > 0.85 ? Neon.cyan : (base > 0.7 ? Neon.magenta : Neon.text)
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                     with: .color(color.opacity(0.12 + 0.28 * twinkle)))
        }
    }

    /// A grid on a floor plane receding to a vanishing point on the horizon.
    private func drawGrid(ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let horizon = size.height * 0.54
        let vpx = size.width * 0.5
        let depth = size.height - horizon
        guard depth > 1 else { return }

        // Receding horizontal lines: z scrolls, screen y = horizon + depth / z
        var horizontals = Path()
        let scroll = t.truncatingRemainder(dividingBy: 1.0)
        for i in 0..<26 {
            let z = Double(i) + 1.0 - scroll
            let y = horizon + depth / z
            guard y < size.height + 2 else { continue }
            horizontals.move(to: CGPoint(x: 0, y: y))
            horizontals.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(horizontals,
                   with: .linearGradient(
                    Gradient(colors: [Neon.cyan.opacity(0.02), Neon.cyan.opacity(0.20)]),
                    startPoint: CGPoint(x: 0, y: horizon),
                    endPoint: CGPoint(x: 0, y: size.height)),
                   lineWidth: 1)

        // Converging verticals.
        var verticals = Path()
        for i in -14...14 {
            let spread = CGFloat(i) * size.width * 0.16
            verticals.move(to: CGPoint(x: vpx, y: horizon))
            verticals.addLine(to: CGPoint(x: vpx + spread, y: size.height))
        }
        ctx.stroke(verticals,
                   with: .linearGradient(
                    Gradient(colors: [.clear, Neon.cyan.opacity(0.16)]),
                    startPoint: CGPoint(x: 0, y: horizon),
                    endPoint: CGPoint(x: 0, y: size.height)),
                   lineWidth: 1)

        // Horizon bloom.
        let glowRect = CGRect(x: 0, y: horizon - 26, width: size.width, height: 52)
        ctx.fill(Path(glowRect),
                 with: .linearGradient(
                    Gradient(colors: [.clear, Neon.cyan.opacity(0.11), .clear]),
                    startPoint: CGPoint(x: 0, y: horizon - 26),
                    endPoint: CGPoint(x: 0, y: horizon + 26)))
    }

    private func drawScanlines(ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        var lines = Path()
        var y: CGFloat = 0
        while y < size.height {
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
            y += 3
        }
        ctx.stroke(lines, with: .color(.black.opacity(0.17)), lineWidth: 1)

        // One bright sweep travelling down the screen.
        let period = 7.0
        let phase = (t.truncatingRemainder(dividingBy: period)) / period
        let sy = CGFloat(phase) * (size.height + 160) - 80
        let band = CGRect(x: 0, y: sy - 40, width: size.width, height: 80)
        ctx.fill(Path(band),
                 with: .linearGradient(
                    Gradient(colors: [.clear, Neon.cyan.opacity(0.045), .clear]),
                    startPoint: CGPoint(x: 0, y: sy - 40),
                    endPoint: CGPoint(x: 0, y: sy + 40)))
    }

    private func drawVignette(ctx: inout GraphicsContext, size: CGSize) {
        let r = max(size.width, size.height) * 0.78
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .radialGradient(
                    Gradient(colors: [.clear, .black.opacity(0.55)]),
                    center: c, startRadius: r * 0.35, endRadius: r))
    }
}

/// Tiny deterministic PRNG so the star field never shimmers between frames.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
