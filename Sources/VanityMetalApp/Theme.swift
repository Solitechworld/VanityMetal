//
//  Theme.swift
//  VanityMetal
//
//  The visual language: a dark cyberspace palette, glow treatments, and the
//  reusable neon controls the panels are built from.
//

import SwiftUI
import VanityMetalCore

enum Neon {
    static let void      = Color(red: 0.016, green: 0.024, blue: 0.051)   // #04060D
    static let deep      = Color(red: 0.035, green: 0.055, blue: 0.110)   // #090E1C
    static let panel     = Color(red: 0.055, green: 0.082, blue: 0.145)   // #0E1525
    static let hairline  = Color(red: 0.145, green: 0.235, blue: 0.353)

    static let cyan      = Color(red: 0.133, green: 0.910, blue: 1.000)   // #22E8FF
    static let magenta   = Color(red: 1.000, green: 0.239, blue: 0.796)   // #FF3DCB
    static let lime      = Color(red: 0.486, green: 1.000, blue: 0.310)   // #7CFF4F
    static let amber     = Color(red: 1.000, green: 0.757, blue: 0.302)   // #FFC14D
    static let rose      = Color(red: 1.000, green: 0.302, blue: 0.427)   // #FF4D6D
    static let violet    = Color(red: 0.616, green: 0.435, blue: 1.000)   // #9D6FFF

    static let text      = Color(red: 0.788, green: 0.969, blue: 1.000)
    static let textDim   = Color(red: 0.427, green: 0.561, blue: 0.651)
    static let textFaint = Color(red: 0.286, green: 0.384, blue: 0.463)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Glow

extension View {
    /// A double-shadow neon bloom.
    func glow(_ color: Color, radius: CGFloat = 8, intensity: Double = 0.9) -> some View {
        self
            .shadow(color: color.opacity(0.65 * intensity), radius: radius * 0.4)
            .shadow(color: color.opacity(0.35 * intensity), radius: radius)
    }

    func neonBorder(_ color: Color, radius: CGFloat = 14, width: CGFloat = 1) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [color.opacity(0.85), color.opacity(0.18)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: width)
        )
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    let title: String
    var accent: Color = Neon.cyan
    var systemImage: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 3, height: 13)
                    .glow(accent, radius: 6)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(accent)
                }
                Text(title.uppercased())
                    .font(Neon.mono(10.5, .bold))
                    .kerning(1.9)
                    .foregroundColor(accent.opacity(0.92))
                Spacer(minLength: 6)
                if let trailing { trailing }
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 9)

            Rectangle()
                .fill(LinearGradient(colors: [accent.opacity(0.45), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)

            content()
                .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Neon.panel.opacity(0.72))
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial).opacity(0.35)
                )
        )
        .neonBorder(accent.opacity(0.55))
        .shadow(color: accent.opacity(0.13), radius: 18, y: 4)
    }
}

// MARK: - Buttons

struct NeonButtonStyle: ButtonStyle {
    var accent: Color = Neon.cyan
    var filled: Bool = false
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Neon.mono(compact ? 10.5 : 11.5, .bold))
            .foregroundColor(filled ? Neon.void : accent)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 6 : 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(filled
                          ? AnyShapeStyle(LinearGradient(colors: [accent, accent.opacity(0.72)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(accent.opacity(configuration.isPressed ? 0.26 : 0.10)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(accent.opacity(filled ? 0.0 : 0.65), lineWidth: 1)
            )
            .glow(accent, radius: filled ? 12 : 6, intensity: configuration.isPressed ? 1.3 : 0.7)
            .scaleEffect(configuration.isPressed ? 0.975 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconChip: View {
    let system: String
    let label: String
    var accent: Color = Neon.cyan
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: system).font(.system(size: 10, weight: .bold))
                Text(label)
            }
        }
        .buttonStyle(NeonButtonStyle(accent: accent, compact: true))
    }
}

// MARK: - Toggle & slider

struct NeonToggle: View {
    let label: String
    var accent: Color = Neon.cyan
    var hint: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(accent.opacity(isOn ? 0.95 : 0.35), lineWidth: 1)
                        .frame(width: 14, height: 14)
                    if isOn {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(accent)
                            .frame(width: 7, height: 7)
                            .glow(accent, radius: 6)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(Neon.mono(11))
                        .foregroundColor(isOn ? Neon.text : Neon.textDim)
                    if let hint {
                        Text(hint).font(Neon.mono(9)).foregroundColor(Neon.textFaint)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct NeonSlider: View {
    let label: String
    let range: ClosedRange<Double>
    var step: Double = 1
    var accent: Color = Neon.cyan
    var format: (Double) -> String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label.uppercased())
                    .font(Neon.mono(9.5, .semibold)).kerning(1.1)
                    .foregroundColor(Neon.textDim)
                Spacer()
                Text(format(value))
                    .font(Neon.mono(10.5, .bold))
                    .foregroundColor(accent)
            }
            Slider(value: $value, in: range, step: step)
                .controlSize(.mini)
                .tint(accent)
        }
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let label: String
    let value: String
    var sub: String? = nil
    var accent: Color = Neon.cyan
    var wide: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Neon.mono(8.5, .semibold)).kerning(1.3)
                .foregroundColor(Neon.textFaint)
            Text(value)
                .font(Neon.mono(wide ? 20 : 15, .bold))
                .foregroundColor(accent)
                .glow(accent, radius: 7, intensity: 0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let sub {
                Text(sub).font(Neon.mono(9)).foregroundColor(Neon.textDim).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent.opacity(0.28), lineWidth: 1)
        )
    }
}

// MARK: - Small pieces

struct StatusBadge: View {
    let state: RunState

    var color: Color {
        switch state {
        case .idle: return Neon.textDim
        case .preparing: return Neon.amber
        case .running: return Neon.lime
        case .paused: return Neon.amber
        case .stopping: return Neon.rose
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).glow(color, radius: 7)
            Text(state.label)
                .font(Neon.mono(10, .bold)).kerning(1.6)
                .foregroundColor(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
    }
}

struct Pill: View {
    let text: String
    var accent: Color = Neon.violet
    var body: some View {
        Text(text)
            .font(Neon.mono(9, .bold)).kerning(0.8)
            .foregroundColor(accent)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(accent.opacity(0.14)))
            .overlay(Capsule().strokeBorder(accent.opacity(0.4), lineWidth: 0.8))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Neon.mono(9, .semibold)).kerning(1.4)
            .foregroundColor(Neon.textFaint)
    }
}
