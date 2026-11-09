import AppKit
import CoreText
import SwiftUI

/// The look of cpc2027.vercel.app: cream mist, frosted glass cards, Geist in one weight, Geist Pixel
/// for numbers, with green where CPC uses orange. The colours come from a `Palette` (below), which starts as a
/// negative and develops into the positive as the roll converts.
enum Theme {
    /// Registers the bundled Geist and Geist Pixel fonts for this process.
    static func registerFonts() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }

    /// Geist, falling back to the system font if it didn't load.
    static func font(_ size: CGFloat) -> Font {
        NSFont(name: "Geist-Regular", size: size) != nil ? .custom("Geist-Regular", size: size) : .system(size: size)
    }

    /// Geist Pixel, for numbers.
    static func pixel(_ size: CGFloat) -> Font {
        NSFont(name: "GeistPixel-Regular", size: size) != nil
            ? .custom("GeistPixel-Regular", size: size) : .system(size: size, design: .monospaced)
    }

    static let s = font(12)
    static let m = font(14)
    static let l = font(24)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - Palette

/// An RGBA colour that can be mixed with another.
struct RGBA {
    var r, g, b, a: Double

    init(_ hex: UInt32, _ a: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255; g = Double((hex >> 8) & 0xFF) / 255; b = Double(hex & 0xFF) / 255
        self.a = a
    }

    func mix(_ other: RGBA, _ t: Double) -> RGBA {
        var c = self
        c.r += (other.r - r) * t; c.g += (other.g - g) * t; c.b += (other.b - b) * t; c.a += (other.a - a) * t
        return c
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// Every colour the window uses. `negative` is the CPC look as it would sit on a strip of colour
/// negative film: the orange mask, dense rust where the page is light, light orange where the ink is,
/// and the green turned magenta. `positive` is the CPC look in green.
struct Palette {
    var bg, mist1, mist2, mist3, surface, paper, highlight: RGBA
    var text, dim, faint, accent, accentText, line, error: RGBA
    var dotRest, dotNext, dotRing: RGBA

    static let positive = Palette(
        bg: RGBA(0xEEEDE9), mist1: RGBA(0xDDE3E8), mist2: RGBA(0xE2EBDA), mist3: RGBA(0xE2E5DB),
        surface: RGBA(0xDFDCD3, 0.55), paper: RGBA(0xFFFFFF), highlight: RGBA(0xFFFFFF, 0.6),
        text: RGBA(0x1D1D1B), dim: RGBA(0x85827A), faint: RGBA(0xB4B1A9),
        accent: RGBA(0x3E9A5C), accentText: RGBA(0x2B7343), line: RGBA(0x1D1D1B, 0.09), error: RGBA(0xC0392B),
        dotRest: RGBA(0xDCD7CD), dotNext: RGBA(0xB9DDBF), dotRing: RGBA(0xCFCAC0))

    static let negative = Palette(
        bg: RGBA(0x3B2216), mist1: RGBA(0x45291B), mist2: RGBA(0x2C1F1C), mist3: RGBA(0x3F2A17),
        surface: RGBA(0x4E2F1F, 0.55), paper: RGBA(0x24140C), highlight: RGBA(0xF2B07A, 0.14),
        text: RGBA(0xF4B784), dim: RGBA(0xB98262), faint: RGBA(0x87593E),
        accent: RGBA(0xB8466E), accentText: RGBA(0xE88AA6), line: RGBA(0xF4B784, 0.12), error: RGBA(0x5FD0D8),
        dotRest: RGBA(0x5C3A27), dotNext: RGBA(0x73304A), dotRing: RGBA(0x6E4A35))

    /// `t` 0 is the negative, 1 the positive.
    static func developed(_ t: Double) -> Palette {
        let n = negative, p = positive, t = max(0, min(1, t))
        func m(_ k: KeyPath<Palette, RGBA>) -> RGBA { n[keyPath: k].mix(p[keyPath: k], t) }
        return Palette(bg: m(\.bg), mist1: m(\.mist1), mist2: m(\.mist2), mist3: m(\.mist3), surface: m(\.surface),
                       paper: m(\.paper), highlight: m(\.highlight), text: m(\.text), dim: m(\.dim), faint: m(\.faint),
                       accent: m(\.accent), accentText: m(\.accentText), line: m(\.line), error: m(\.error),
                       dotRest: m(\.dotRest), dotNext: m(\.dotNext), dotRing: m(\.dotRing))
    }
}

/// The palette as colours, for the views.
struct Colors {
    let base: Palette
    var bg: Color { base.bg.color }
    var surface: Color { base.surface.color }
    var paper: Color { base.paper.color }
    var highlight: Color { base.highlight.color }
    var text: Color { base.text.color }
    var dim: Color { base.dim.color }
    var faint: Color { base.faint.color }
    var accent: Color { base.accent.color }
    var accentText: Color { base.accentText.color }
    var line: Color { base.line.color }
    var error: Color { base.error.color }
    var dotRest: Color { base.dotRest.color }
    var dotNext: Color { base.dotNext.color }
    var dotRing: Color { base.dotRing.color }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Colors(base: .positive)
}

extension EnvironmentValues {
    var palette: Colors {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Sets the palette `developed` of the way from negative to positive, and animates in between.
struct Develop: ViewModifier, Animatable {
    var developed: Double
    var animatableData: Double {
        get { developed }
        set { developed = newValue }
    }

    func body(content: Content) -> some View {
        let colors = Colors(base: .developed(developed))
        return content
            .foregroundStyle(colors.text)
            .tint(colors.accent)
            .environment(\.palette, colors)
    }
}

// MARK: - Background and cards

/// Soft mist behind everything: cool grey top left, a hint of sunset peach on the right, sage below.
struct MistBackground: View {
    @Environment(\.palette) private var p

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                p.bg
                RadialGradient(colors: [p.base.mist1.color, p.base.mist1.color.opacity(0)],
                               center: UnitPoint(x: 0.1, y: 0), startRadius: 0, endRadius: max(size.width, size.height) * 0.7)
                RadialGradient(colors: [p.base.mist2.color, p.base.mist2.color.opacity(0)],
                               center: UnitPoint(x: 1, y: 0.55), startRadius: 0, endRadius: max(size.width, size.height) * 0.55)
                RadialGradient(colors: [p.base.mist3.color, p.base.mist3.color.opacity(0)],
                               center: UnitPoint(x: 0, y: 1), startRadius: 0, endRadius: max(size.width, size.height) * 0.6)
            }
        }
        .ignoresSafeArea()
    }
}

struct Glass: ViewModifier {
    /// How much of the palette's paper the card is; nil for the plain surface.
    var paper: Double?
    var radius: CGFloat = 24
    @Environment(\.palette) private var p

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(paper.map { p.paper.opacity($0) } ?? p.surface)
                    .shadow(color: Color(red: 60 / 255, green: 55 / 255, blue: 40 / 255).opacity(0.06), radius: 15, y: 10)
            )
            .overlay(
                // The inset highlight along the top edge.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [p.highlight, p.highlight.opacity(0)],
                                                 startPoint: .top, endPoint: .center), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func glass(paper: Double? = nil, radius: CGFloat = 24) -> some View {
        modifier(Glass(paper: paper, radius: radius))
    }
}

// MARK: - Buttons

/// The CPC chip: a 40-point pill. `primary` is orange; `on` is ink, for a chosen option.
struct ChipStyle: ButtonStyle {
    enum Kind { case plain, on, primary }
    var kind: Kind = .plain
    var height: CGFloat = 40
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.palette) private var p

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(height >= 52 ? 16 : 14))
            .foregroundStyle(kind == .plain ? p.text : p.paper)
            .padding(.horizontal, height >= 52 ? 28 : 16)
            .frame(height: height)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }

    private var background: Color {
        switch kind {
        case .plain: p.paper.opacity(0.6)
        case .on: p.text
        case .primary: p.accent
        }
    }
}

extension ButtonStyle where Self == ChipStyle {
    static func chip(_ kind: ChipStyle.Kind, height: CGFloat = 40) -> ChipStyle { ChipStyle(kind: kind, height: height) }
}

/// A chip that turns ink when on: for options you pick.
struct ChoiceChip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action).buttonStyle(.chip(on ? .on : .plain, height: 32))
    }
}

/// A switch in the accent colour.
struct AccentToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.palette) private var p

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            Capsule()
                .fill(configuration.isOn ? p.accent : p.dotRest)
                .frame(width: 40, height: 24)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(p.paper).padding(3).shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}
