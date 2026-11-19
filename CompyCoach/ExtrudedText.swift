import AppKit
import CoreText
import SwiftUI

// The takeover's hero: Big Shoulders 900 extruded out of the ground like a block pushed toward the
// viewer. Each character's face is a crisp vector glyph; its side walls are painted behind it at a
// coarse cell size with noise dithering across four ramp tones, lit near the face and falling into
// the ground at the back. Light comes from the top left. On appear, the characters push out of the
// wall one after another on the carry spring.
//
// The view's layout frame is the text's cap box (top = cap height, bottom = baseline), so it lines up
// with CapText. The walls draw outside that frame, down and to the right.

struct ExtrudedText: View {
    let text: String
    let size: CGFloat
    var tabular = true
    /// Seconds after appearing before the first character starts to move.
    var delay: Double = 0.3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.distantFuture
    @State private var finished = false

    static let stagger = 0.07
    static let duration = 1.0

    var body: some View {
        let layout = ExtrusionLayout(text: text, size: size, tabular: tabular)
        Color.clear
            .frame(width: layout.width, height: layout.capHeight)
            .overlay(alignment: .topLeading) {
                TimelineView(.animation(paused: finished || reduceMotion)) { timeline in
                    let ks = amounts(at: timeline.date, count: layout.glyphs.count)
                    Canvas { context, _ in layout.draw(in: &context, ks: ks) }
                        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
                        .offset(x: -layout.pad, y: -layout.pad)
                }
                .allowsHitTesting(false)
            }
            .accessibilityElement()
            .accessibilityLabel(text)
            .onAppear {
                start = Date().addingTimeInterval(delay)
                let total = delay + Self.duration + Self.stagger * Double(max(layout.glyphs.count - 1, 0)) + 0.1
                DispatchQueue.main.asyncAfter(deadline: .now() + total) { finished = true }
            }
    }

    /// One extrusion amount per character: 0 = flush with the wall, 1 = fully out.
    private func amounts(at date: Date, count: Int) -> [CGFloat] {
        if reduceMotion { return Array(repeating: 1, count: count) }
        let elapsed: Double = date.timeIntervalSince(start)
        var result: [CGFloat] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let t: Double = (elapsed - Double(i) * Self.stagger) / Self.duration
            result.append(CGFloat(DBP.carryCurve(t)))
        }
        return result
    }
}

// MARK: - Layout and drawing

private struct ExtrusionLayout {
    struct Glyph {
        let path: CGPath  // font units flipped to y-down, baseline at 0
        let x: CGFloat
    }

    // Extrusion depth as a fraction of the font size (down-right, away from the light).
    static let depth = CGSize(width: 0.045, height: 0.065)
    static let layers = 40

    // Face goes from n-850 (flush with the wall) to n-100 (lit). Walls step n-600 → surface.
    static let faceFrom: [CGFloat] = [0x23, 0x21, 0x1f].map { $0 / 255 }
    static let faceTo: [CGFloat] = [0xec, 0xe4, 0xd3].map { $0 / 255 }
    static let tones: [[UInt8]] = [[0x5a, 0x58, 0x52], [0x3f, 0x3d, 0x38], [0x2d, 0x2b, 0x28], [0x1a, 0x19, 0x17]]

    let size: CGFloat
    let glyphs: [Glyph]
    let width: CGFloat
    let capHeight: CGFloat
    let pad: CGFloat

    var canvasSize: CGSize { CGSize(width: width + pad * 2, height: capHeight + pad * 2) }

    init(text: String, size: CGFloat, tabular: Bool) {
        self.size = size
        let font = DBPFont.displayNSFont(size, weight: 900, tabular: tabular)
        let attributed = NSAttributedString(string: text.uppercased(),
                                            attributes: [.font: font, .kern: -0.01 * size])
        let line = CTLineCreateWithAttributedString(attributed)
        width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        capHeight = font.capHeight
        pad = ceil(size * 0.1)

        var result: [Glyph] = []
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String] as! CTFont
            for j in 0..<count {
                var t = flip
                guard let path = CTFontCreatePathForGlyph(runFont, ids[j], &t) else { continue }
                result.append(Glyph(path: path, x: positions[j].x))
            }
        }
        glyphs = result
    }

    func draw(in context: inout GraphicsContext, ks: [CGFloat]) {
        if let walls = wallsImage(ks: ks) {
            let image = Image(decorative: walls.image, scale: 1).interpolation(.none)
            context.draw(image, in: CGRect(x: 0, y: 0, width: walls.pointSize.width, height: walls.pointSize.height))
        }

        let d = CGSize(width: Self.depth.width * size, height: Self.depth.height * size)
        let highlight = 0.004 * size
        for (i, glyph) in glyphs.enumerated() {
            let k = ks[i], kc = min(1, max(0, k))
            // The face rides out from the wall plane (offset by the full depth) toward the light.
            let x = pad + glyph.x + (1 - k) * d.width
            let y = pad + capHeight + (1 - k) * d.height
            let face = Path(glyph.path).offsetBy(dx: x, dy: y)
            context.fill(Path(glyph.path).offsetBy(dx: x - highlight * kc, dy: y - highlight * kc),
                         with: .color(DBP.light))
            context.fill(face, with: .color(Self.faceColor(kc)))
        }
    }

    static func faceColor(_ k: CGFloat) -> Color {
        Color(.sRGB,
              red: Double(faceFrom[0] + (faceTo[0] - faceFrom[0]) * k),
              green: Double(faceFrom[1] + (faceTo[1] - faceFrom[1]) * k),
              blue: Double(faceFrom[2] + (faceTo[2] - faceFrom[2]) * k))
    }

    /// Stable white-noise threshold per cell, so the grain is random but never shimmers.
    private static func noise(_ x: Int, _ y: Int) -> Double {
        let s = sin(Double(x) * 12.9898 + Double(y) * 78.233) * 43758.5453
        return s - floor(s)
    }

    /// Paint the walls at cell resolution. Every character is stamped `layers` times along its
    /// extrusion (far first, so nearer layers win), tagged with its layer index in red and its
    /// character index in green; each covered cell then maps its depth to a dithered ramp tone,
    /// blended toward the flush color by how far that character has pushed out.
    private func wallsImage(ks: [CGFloat]) -> (image: CGImage, pointSize: CGSize)? {
        let cell = max(1, (size / 190).rounded())
        let w = Int(ceil(canvasSize.width / cell)), h = Int(ceil(canvasSize.height / cell))
        guard w > 0, h > 0, ks.contains(where: { $0 > 0.03 }),
              let mask = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        mask.setShouldAntialias(false)
        mask.setAllowsAntialiasing(false)
        // Draw in y-down points to match the canvas.
        mask.translateBy(x: 0, y: CGFloat(h))
        mask.scaleBy(x: 1 / cell, y: -1 / cell)

        let d = CGSize(width: Self.depth.width * size, height: Self.depth.height * size)
        for layer in stride(from: Self.layers, through: 0, by: -1) {
            let t = CGFloat(layer) / CGFloat(Self.layers)
            for (i, glyph) in glyphs.enumerated() where ks[i] > 0.001 {
                let along = (1 - ks[i]) + ks[i] * t  // face at (1-k), base at 1, in units of full depth
                mask.setFillColor(red: CGFloat(layer) / 255, green: CGFloat(i) / 255, blue: 0, alpha: 1)
                mask.saveGState()
                mask.translateBy(x: pad + glyph.x + along * d.width, y: pad + capHeight + along * d.height)
                mask.addPath(glyph.path)
                mask.fillPath()
                mask.restoreGState()
            }
        }

        guard let raw = mask.data else { return nil }
        let src = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let steps = Double(Self.tones.count - 1)
        for y in 0..<h {
            for x in 0..<w {
                let p = (y * w + x) * 4
                guard src[p + 3] >= 128 else { continue }
                let ci = min(glyphs.count - 1, Int(src[p + 1]))
                let kc = Double(min(1, max(0, ks[ci])))
                guard kc > 0.03 else { continue }
                let tone = Double(max(1, Int(src[p]))) / Double(Self.layers) * steps
                var b = Int(tone)
                if Self.noise(x, y) < tone - Double(b) { b += 1 }
                let lit = Self.tones[min(b, Self.tones.count - 1)]
                for c in 0..<3 {
                    let from = Double(Self.faceFrom[c]) * 255
                    out[p + c] = UInt8(from + (Double(lit[c]) - from) * kc)
                }
                out[p + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return nil }
        return (image, CGSize(width: CGFloat(w) * cell, height: CGFloat(h) * cell))
    }
}
