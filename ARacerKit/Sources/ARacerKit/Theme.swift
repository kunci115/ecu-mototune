import SwiftUI

/// MotoTune design system — a dark, data-dense "telemetry" aesthetic.
/// One signature accent (cyan), near-black surfaces, subtle borders over heavy shadows,
/// Space Grotesk for display, monospaced digits for data.
public enum Theme {
    public enum Palette {
        public static let bg        = Color(hex: 0x0A0C0F)
        public static let surface   = Color(hex: 0x14181E)
        public static let surfaceHi = Color(hex: 0x1C222B)
        public static let border    = Color.white.opacity(0.07)
        public static let borderHi  = Color.white.opacity(0.12)
        public static let text      = Color(hex: 0xEDF1F5)
        public static let textDim   = Color(hex: 0x8A93A0)
        public static let textFaint = Color(hex: 0x5A626E)
        public static let accent    = Color(hex: 0x25E0D0)   // signature telemetry cyan
        public static let good      = Color(hex: 0x34D399)
        public static let warn      = Color(hex: 0xFBBF24)
        public static let bad       = Color(hex: 0xF87171)
    }
    public enum Space { public static let xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0 }
    public enum Radius { public static let sm = 10.0, md = 14.0, lg = 20.0 }

    /// Space Grotesk if bundled (iOS app), else the system rounded font.
    public static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .custom("Space Grotesk", size: size).weight(weight)
    }

    /// Tuning heat scale on the dark theme: deep teal (low) → signature cyan → amber → coral (high).
    /// `f` in 0…1. Dark enough at the ends for white text, saturated enough to read as a map.
    public static func heat(_ f: Double) -> Color {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (0x0F, 0x4A, 0x4A)), (0.35, (0x14, 0x8A, 0x84)), (0.60, (0x8A, 0x7A, 0x1E)),
            (0.80, (0xC2, 0x5A, 0x22)), (1.00, (0xC8, 0x3A, 0x3A)),
        ]
        let x = Swift.min(1, Swift.max(0, f))
        for i in 1..<stops.count where x <= stops[i].0 {
            let (a, ca) = stops[i - 1], (b, cb) = stops[i]
            let t = (x - a) / (b - a)
            return Color(.sRGB, red: (ca.0 + (cb.0 - ca.0) * t) / 255, green: (ca.1 + (cb.1 - ca.1) * t) / 255, blue: (ca.2 + (cb.2 - ca.2) * t) / 255, opacity: 1)
        }
        return Color(hex: 0xC83A3A)
    }
    public static func confidenceColor(_ c: String) -> Color {
        switch c { case "strong": Palette.good; case "medium": Palette.accent; case "low": Palette.warn; default: Palette.textFaint }
    }
}

public extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Elevated card: surface fill, hairline border, consistent radius and padding.
struct CardStyle: ViewModifier {
    var padding: CGFloat = Theme.Space.lg
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.Palette.surface, in: .rect(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Palette.border, lineWidth: 1))
    }
}

/// A small uppercase tracked section/label caption.
struct Eyebrow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Theme.Palette.textDim)
    }
}

public extension View {
    func card(padding: CGFloat = Theme.Space.lg) -> some View { modifier(CardStyle(padding: padding)) }
    func eyebrow() -> some View { modifier(Eyebrow()) }
}
