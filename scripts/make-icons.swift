// Regenerates every app icon and menu bar icon from logo.svg.
//
//   swift scripts/make-icons.swift        (run from the repo root)
//
// Outputs:
//   CompyCoach/Assets.xcassets/AppIcon.appiconset/icon_*.png   (16–1024 px)
//   AppIcon.iconset/icon_*.png + AppIcon.icns                   (via iconutil)
//   CompyCoach/Assets.xcassets/MenuBarIcon.imageset/menubaricon{,@2x}.png
//   menubaricon{,@2x}.png                                       (root copies)

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svgURL = root.appendingPathComponent("logo.svg")
guard let logo = NSImage(contentsOf: svgURL) else {
    fatalError("Couldn't load \(svgURL.path) — run from the repo root.")
}

// App icon: full-bleed dark square, glyph centered at 74% of the canvas.
let appBackground = NSColor(srgbRed: 13/255, green: 13/255, blue: 13/255, alpha: 1)  // #0D0D0D
let appGlyphFraction: CGFloat = 0.74

// Menu bar: template image (black + alpha; macOS tints it), glyph fills 40/44.
let menuGlyphFraction: CGFloat = 40.0 / 44.0

func render(px: Int, background: NSColor?, glyphFraction: CGFloat, tint: NSColor?) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let canvas = NSRect(x: 0, y: 0, width: px, height: px)
    if let bg = background {
        bg.setFill()
        canvas.fill()
    } else {
        NSColor.clear.setFill()
        canvas.fill(using: .copy)
    }

    let side = CGFloat(px) * glyphFraction
    let glyphRect = NSRect(x: (CGFloat(px) - side) / 2, y: (CGFloat(px) - side) / 2,
                           width: side, height: side)

    if let tint = tint {
        // Draw the glyph alone, then recolor it in place.
        let glyph = NSImage(size: canvas.size, flipped: false) { _ in
            logo.draw(in: glyphRect)
            tint.setFill()
            canvas.fill(using: .sourceIn)
            return true
        }
        glyph.draw(in: canvas)
    } else {
        logo.draw(in: glyphRect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) {
    let url = root.appendingPathComponent(path)
    try! data.write(to: url)
    print("wrote \(path)")
}

// App icon sizes (points × scale), named the way the asset catalog / iconset expect.
let appIconDir = "CompyCoach/Assets.xcassets/AppIcon.appiconset"
let iconsetDir = "AppIcon.iconset"
try? FileManager.default.createDirectory(at: root.appendingPathComponent(iconsetDir),
                                         withIntermediateDirectories: true)

for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        let png = render(px: pt * scale, background: appBackground,
                         glyphFraction: appGlyphFraction, tint: nil)
        write(png, "\(appIconDir)/\(name)")
        write(png, "\(iconsetDir)/\(name)")
    }
}

// Menu bar template icon: 22 pt at 1x and 2x.
let menuDir = "CompyCoach/Assets.xcassets/MenuBarIcon.imageset"
for (px, name) in [(22, "menubaricon.png"), (44, "menubaricon@2x.png")] {
    let png = render(px: px, background: nil, glyphFraction: menuGlyphFraction, tint: .black)
    write(png, "\(menuDir)/\(name)")
    write(png, name)
}

// .icns from the iconset.
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir, "-o", "AppIcon.icns"]
iconutil.currentDirectoryURL = root
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote AppIcon.icns" : "iconutil failed (\(iconutil.terminationStatus))")
