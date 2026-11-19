import AppKit
import SwiftUI

// Design by Proxy tokens (System by Proxy 0.15.1), mapped to SwiftUI.
// Source of truth: designbyproxy.com/system. When this file and /system disagree, fix this file.

enum DBP {

    // MARK: Color

    // Ground: page background (never #000); elevation steps ground → surface → raised.
    static let ground  = Color(hex: 0x0a0a0a)
    static let surface = Color(hex: 0x1a1917)
    static let raised  = Color(hex: 0x23211f)

    // Neutral ramp along cream's hue. Ink (100) holds everything at rest; light (50)
    // marks reach only (hover, press). No opacity on text: pick a step instead.
    static let light   = Color(hex: 0xf5f0e8)  // n-50
    static let ink     = Color(hex: 0xece4d3)  // n-100
    static let inkSoft = Color(hex: 0xd1cab9)  // n-200
    static let text2   = Color(hex: 0xb8b1a2)  // n-300
    static let meta    = Color(hex: 0x979286)  // n-400
    static let muted   = Color(hex: 0x7c7971)  // n-500, ground only
    static let inert   = Color(hex: 0x5a5852)  // n-600, never carries information
    static let ruleHover  = Color(hex: 0x3f3d38)  // n-700
    static let ruleStrong = Color(hex: 0x2d2b28)  // n-800, hairline on surfaces
    static let rule       = Color(hex: 0x23211f)  // n-850, hairline on the ground

    static let nsGround = NSColor(hex: 0x0a0a0a)

    // MARK: Radius

    static let radiusXS: CGFloat = 2  // tags, chips, bars
    static let radiusSM: CGFloat = 4  // buttons, inputs

    // MARK: Springs

    static let press  = Animation.spring(response: 0.16, dampingFraction: 1.0)   // buttons, color shifts
    static let settle = Animation.spring(response: 0.38, dampingFraction: 0.72)  // hover lift
    static let carry  = Animation.spring(response: 0.60, dampingFraction: 0.88)  // reveals, panels, blocks
    static let reducedMotion = Animation.linear(duration: 0.15)

    /// The carry spring sampled as a curve (0 → 1, settles at ~1.003), for animations driven frame
    /// by frame rather than by SwiftUI. Same values as the CSS `--e-carry` linear().
    static func carryCurve(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        let x = t * Double(carryPoints.count - 1)
        let i = Int(x)
        return carryPoints[i] + (carryPoints[i + 1] - carryPoints[i]) * (x - Double(i))
    }

    private static let carryPoints: [Double] = [
        0, 0.017, 0.062, 0.125, 0.198, 0.276, 0.355, 0.432, 0.505, 0.573, 0.635, 0.691, 0.741, 0.784,
        0.822, 0.855, 0.882, 0.906, 0.926, 0.942, 0.955, 0.966, 0.975, 0.982, 0.988, 0.992, 0.996, 0.998,
        1, 1.001, 1.002, 1.003, 1.003, 1.003, 1.003, 1.003, 1.003, 1.002, 1.002, 1,
    ]
}

// MARK: - Type

// Big Shoulders = the claim. Harmattan = the evidence (labels, numbers). Cabin = the explanation.
// font-size-adjust has no SwiftUI equivalent, so each family's pair is applied by scaling the
// point size from the font's own metrics: Harmattan to cap-height 0.75, Cabin to ex-height 0.523.
enum DBPFont {

    /// Big Shoulders at 700 / 800 / 900. Nothing below 700. Optical size is left to CoreText.
    /// `tabular` turns on equal-width figures (for counts and countdowns). Don't use SwiftUI's
    /// `.monospacedDigit()` on these fonts: it rebuilds the font and drops the weight axis.
    static func display(_ size: CGFloat, weight: CGFloat = 700, tabular: Bool = false) -> Font {
        Font(displayNSFont(size, weight: weight, tabular: tabular))
    }

    /// The AppKit font behind `display(_:)`, for metrics and glyph outlines.
    static func displayNSFont(_ size: CGFloat, weight: CGFloat = 700, tabular: Bool = false) -> NSFont {
        variable("Big Shoulders", size: size, weight: max(weight, 700), tabular: tabular)
            ?? .systemFont(ofSize: size, weight: .bold)
    }

    /// Harmattan 400 / 500, adjusted to cap-height 0.75.
    static func mono(_ size: CGFloat, medium: Bool = false) -> Font {
        let name = medium ? "Harmattan-Medium" : "Harmattan-Regular"
        guard let base = NSFont(name: name, size: size), base.capHeight > 0 else {
            return .system(size: size, weight: medium ? .medium : .regular)
        }
        let adjusted = size * 0.75 / (base.capHeight / size)
        return Font(NSFont(name: name, size: adjusted) ?? base)
    }

    /// Cabin 400 / 500, adjusted to ex-height 0.523.
    static func body(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        guard let base = variable("Cabin", size: size, weight: weight), base.xHeight > 0 else {
            return .system(size: size)
        }
        let adjusted = size * 0.523 / (base.xHeight / size)
        return Font(variable("Cabin", size: adjusted, weight: weight) ?? base)
    }

    private static let weightAxis = NSNumber(value: 0x77676874)  // 'wght'

    private static func variable(_ family: String, size: CGFloat, weight: CGFloat,
                                 tabular: Bool = false) -> NSFont? {
        guard let base = NSFont(name: family, size: size) else { return nil }
        var attributes: [NSFontDescriptor.AttributeName: Any] = [
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String):
                [weightAxis: NSNumber(value: Double(weight))]
        ]
        if tabular {
            attributes[NSFontDescriptor.AttributeName(rawValue: kCTFontFeatureSettingsAttribute as String)] = [
                [kCTFontOpenTypeFeatureTag: "tnum", kCTFontOpenTypeFeatureValue: 1]
            ]
        }
        return NSFont(descriptor: base.fontDescriptor.addingAttributes(attributes), size: size)
    }
}

// MARK: - Buttons

/// Primary action: solid ink fill, ground text, pill shape (matches the site's "Get in contact"). Brightens to light and lifts
/// 2pt on hover, compresses to 0.97 on press.
struct DBPPrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 56
    var fontSize: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration, height: height, fontSize: fontSize)
    }

    private struct PrimaryButton: View {
        let configuration: Configuration
        let height: CGFloat
        let fontSize: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var reaching: Bool { isEnabled && (hovering || configuration.isPressed) }

        var body: some View {
            configuration.label
                .font(DBPFont.display(fontSize, weight: 700))
                .tracking(fontSize * 0.04)
                .textCase(.uppercase)
                // Disabled still carries information (e.g. "Stretching…"), so meta, not inert.
                .foregroundStyle(isEnabled ? DBP.ground : DBP.meta)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: height / 2, style: .circular)
                        .fill(isEnabled ? (reaching ? DBP.light : DBP.ink) : DBP.raised)
                )
                .contentShape(RoundedRectangle(cornerRadius: height / 2, style: .circular))
                .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.97 : 1)
                .offset(y: hovering && isEnabled && !reduceMotion ? -2 : 0)
                .animation(reduceMotion ? DBP.reducedMotion : DBP.press, value: configuration.isPressed)
                .animation(reduceMotion ? DBP.reducedMotion : DBP.settle, value: hovering)
                .animation(reduceMotion ? DBP.reducedMotion : DBP.press, value: isEnabled)
                .onHover { hovering = $0 }
        }
    }
}

/// Secondary action: borderless, ink at rest, light on hover.
struct DBPGhostButtonStyle: ButtonStyle {
    var height: CGFloat = 44
    var fontSize: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        GhostButton(configuration: configuration, height: height, fontSize: fontSize)
    }

    private struct GhostButton: View {
        let configuration: Configuration
        let height: CGFloat
        let fontSize: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(DBPFont.display(fontSize, weight: 700))
                .tracking(fontSize * 0.04)
                .textCase(.uppercase)
                .foregroundStyle(hovering || configuration.isPressed ? DBP.light : DBP.ink)
                .frame(minHeight: height)
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? DBP.reducedMotion : DBP.press, value: configuration.isPressed)
                .animation(reduceMotion ? DBP.reducedMotion : DBP.press, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// Outline pill: transparent fill with a 1.5pt border. On the ground it's ink and brightens to
/// light on hover; `onLight` flips it for use on a cream surface (ground border and text, fills
/// with ground on hover).
struct DBPOutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 56
    var fontSize: CGFloat = 20
    var onLight = false

    func makeBody(configuration: Configuration) -> some View {
        OutlineButton(configuration: configuration, height: height, fontSize: fontSize, onLight: onLight)
    }

    private struct OutlineButton: View {
        let configuration: Configuration
        let height: CGFloat
        let fontSize: CGFloat
        let onLight: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var reaching: Bool { hovering || configuration.isPressed }
        private var pill: RoundedRectangle { RoundedRectangle(cornerRadius: height / 2, style: .circular) }

        var body: some View {
            let stroke = onLight ? DBP.ground : (reaching ? DBP.light : DBP.ink)
            let text = onLight ? (reaching ? DBP.ink : DBP.ground) : stroke
            configuration.label
                .font(DBPFont.display(fontSize, weight: 700))
                .tracking(fontSize * 0.04)
                .textCase(.uppercase)
                .foregroundStyle(text)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(pill.fill(onLight && reaching ? DBP.ground : Color.clear))
                .overlay(pill.inset(by: 0.75).stroke(stroke, lineWidth: 1.5))
                .contentShape(pill)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .offset(y: hovering && !onLight && !reduceMotion ? -2 : 0)
                .animation(reduceMotion ? DBP.reducedMotion : DBP.press, value: configuration.isPressed)
                .animation(reduceMotion ? DBP.reducedMotion : DBP.settle, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Cap-trimmed display text

/// Big Shoulders text whose frame is trimmed to the cap box: the top edge is the cap height and the
/// bottom edge is the baseline (CSS `text-box: trim-both cap alphabetic`). That lets display lines,
/// heroes and companions align exactly on a grid by their tops and baselines.
struct CapText: View {
    let text: String
    let size: CGFloat
    var weight: CGFloat = 700
    var tracking: CGFloat = 0.01
    var color: Color = DBP.ink

    var body: some View {
        let font = DBPFont.displayNSFont(size, weight: weight)
        Text(text)
            .font(Font(font))
            .tracking(size * tracking)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.top, -(font.ascender - font.capHeight))
            .padding(.bottom, -(-font.descender + font.leading))
    }
}

// MARK: - Hex helpers

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue:  Double(hex & 0xff) / 255)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green:   CGFloat((hex >> 8) & 0xff) / 255,
                  blue:    CGFloat(hex & 0xff) / 255,
                  alpha:   1)
    }
}
