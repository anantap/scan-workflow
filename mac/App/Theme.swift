import AppKit
import CoreText
import SwiftUI

/// The look of cpc2027.vercel.app: cream mist, frosted glass cards, Geist in one weight, Geist Pixel
/// for numbers, and the soft orange blob.
enum Theme {
    static let bg = Color(hex: 0xEEEDE9)
    static let surface = Color(hex: 0xDFDCD3).opacity(0.55)
    static let text = Color(hex: 0x1D1D1B)
    static let dim = Color(hex: 0x85827A)
    static let faint = Color(hex: 0xB4B1A9)
    static let accent = Color(hex: 0xEF7D3C)
    static let accentText = Color(hex: 0xC25E27)
    static let accentSoft = Color(hex: 0xEF7D3C).opacity(0.12)
    static let line = Color(hex: 0x1D1D1B).opacity(0.09)
    static let error = Color(hex: 0xC0392B)
    static let dotRest = Color(hex: 0xDCD7CD)
    static let dotNext = Color(hex: 0xF7C4A2)
    static let dotRing = Color(hex: 0xCFCAC0)

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

// MARK: - Background and cards

/// Soft mist behind everything: cool grey top left, a hint of sunset peach on the right, sage below.
struct MistBackground: View {
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Theme.bg
                RadialGradient(colors: [Color(hex: 0xDDE3E8), Color(hex: 0xDDE3E8).opacity(0)],
                               center: UnitPoint(x: 0.1, y: 0), startRadius: 0, endRadius: max(size.width, size.height) * 0.7)
                RadialGradient(colors: [Color(hex: 0xF3E3D6), Color(hex: 0xF3E3D6).opacity(0)],
                               center: UnitPoint(x: 1, y: 0.55), startRadius: 0, endRadius: max(size.width, size.height) * 0.55)
                RadialGradient(colors: [Color(hex: 0xE2E5DB), Color(hex: 0xE2E5DB).opacity(0)],
                               center: UnitPoint(x: 0, y: 1), startRadius: 0, endRadius: max(size.width, size.height) * 0.6)
            }
        }
        .ignoresSafeArea()
    }
}

struct Glass: ViewModifier {
    var fill: Color = Theme.surface
    var radius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .shadow(color: Color(red: 60 / 255, green: 55 / 255, blue: 40 / 255).opacity(0.06), radius: 15, y: 10)
            )
            .overlay(
                // The inset highlight along the top edge.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0)],
                                                 startPoint: .top, endPoint: .center), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func glass(_ fill: Color = Theme.surface, radius: CGFloat = 24) -> some View {
        modifier(Glass(fill: fill, radius: radius))
    }
}

/// The living blob: two soft shapes that drift and change shape slowly.
struct Blob: View {
    var size: CGFloat = 320
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Ellipse()
                .fill(LinearGradient(colors: [Color(hex: 0xF4733F), Color(hex: 0xF39A78), Color(hex: 0xE8A9BD)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.84, height: size * 0.76)
                .scaleEffect(x: phase ? 1.1 : 1, y: phase ? 0.88 : 1)
                .rotationEffect(.degrees(phase ? 25 : 0))
                .offset(x: size * 0.04, y: -size * 0.04)
            Ellipse()
                .fill(LinearGradient(colors: [Color(hex: 0xC4A6D6), Color(hex: 0xEF8A62)],
                                     startPoint: .topTrailing, endPoint: .bottomLeading))
                .opacity(0.85)
                .frame(width: size * 0.64, height: size * 0.6)
                .scaleEffect(phase ? 1.15 : 0.9)
                .offset(x: phase ? -size * 0.06 : -size * 0.18, y: phase ? size * 0.08 : size * 0.2)
        }
        .frame(width: size, height: size)
        .blur(radius: size / 10)
        .rotationEffect(.degrees(phase ? -20 : 10))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) { phase = true }
        }
    }
}

// MARK: - Buttons

/// The CPC chip: a 40-point pill. `primary` is orange; `on` is ink, for a chosen option.
struct ChipStyle: ButtonStyle {
    enum Kind { case plain, on, primary }
    var kind: Kind = .plain
    var height: CGFloat = 40
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(height >= 52 ? 16 : 14))
            .foregroundStyle(kind == .plain ? Theme.text : .white)
            .padding(.horizontal, height >= 52 ? 28 : 16)
            .frame(height: height)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }

    private var background: Color {
        switch kind {
        case .plain: .white.opacity(0.6)
        case .on: Theme.text
        case .primary: Theme.accent
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

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            Capsule()
                .fill(configuration.isOn ? Theme.accent : Theme.dotRest)
                .frame(width: 40, height: 24)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).padding(3).shadow(color: .black.opacity(0.12), radius: 1, y: 1)
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
