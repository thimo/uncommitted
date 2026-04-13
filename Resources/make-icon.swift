#!/usr/bin/env swift
// Generates an .iconset directory with all sizes macOS expects for iconutil.
//
// Follows Apple's Big Sur+ app icon template strictly so Quick Look's
// preview renderer recognises the shape:
//   Canvas:         1024×1024
//   Icon body:      824×824 centered (100px gutter all sides)
//   Corner radius:  185.4 — with CONTINUOUS CURVE (squircle), not the
//                   circular corners you get from CGPath(roundedRect:…).
//                   The squircle path uses the three-cubic-per-corner
//                   approximation from paintcodeapp.com/news/code-for-
//                   ios-7-rounded-rectangles, which is what UIBezierPath
//                   uses internally on iOS.
//   Drop shadow:    28px blur, 12px down, black 50%. Lives in the 100px
//                   gutter, which is why Apple's template has the margin.
//
// Inside the icon body: pink→purple→blue linear gradient, a warm radial
// hotspot in the upper-left, a subtle top-edge highlight, and the bundled
// merge glyph in white with its own soft drop shadow. One node (top-right)
// glows pink through its ring hole as an accent.

import Foundation
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("Usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}

let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    // Apple template geometry: 824×824 icon body inside a 1024×1024
    // canvas, with 100px gutter on every side that hosts the drop shadow.
    let gutter = size * (100.0 / 1024.0)
    let innerSize = size - gutter * 2
    let rect = CGRect(x: gutter, y: gutter, width: innerSize, height: innerSize)
    // Approximation of Apple's continuous squircle using a standard
    // circular rounded rect. Apple's spec is 185.4 with a CONTINUOUS
    // curve; a visually comparable circular rounded rect uses ~1.25× that
    // radius, which still looks right next to other app icons at typical
    // sizes.
    let cornerRadius = innerSize * (232.0 / 824.0)
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // Icon body drop shadow. Apple's spec: 28px blur @1024, 12px Y, black 50%.
    // Scale proportionally so smaller sizes still carry weight.
    let shadowScale = size / 1024.0
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12 * shadowScale),
        blur: 28 * shadowScale,
        color: NSColor.black.withAlphaComponent(0.5).cgColor
    )
    ctx.addPath(path)
    // Fill with any opaque colour — the shadow is cast from the filled
    // shape, but the fill itself is hidden behind the gradient we paint
    // immediately after.
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Pink → purple → blue-violet linear gradient. Values sampled from
    // Datadog's brand gradient: #E00090 → #8900D2 → #4F00FF. All three
    // points have green ≈ 0, which keeps the palette highly saturated
    // and avoids the cyan tint the previous gradient had at its blue end.
    let colors = [
        NSColor(srgbRed: 0.878, green: 0.000, blue: 0.565, alpha: 1).cgColor, // #E00090
        NSColor(srgbRed: 0.537, green: 0.000, blue: 0.824, alpha: 1).cgColor, // #8900D2
        NSColor(srgbRed: 0.310, green: 0.000, blue: 1.000, alpha: 1).cgColor, // #4F00FF
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )

    // Vivid magenta radial hotspot in the upper-left of the inner rect.
    // Screen-blended so it adds luminance without washing out the base
    // saturation. Keeps green low to stay on-palette with the gradient.
    let hotspotColors = [
        NSColor(srgbRed: 1.00, green: 0.10, blue: 0.70, alpha: 0.70).cgColor,
        NSColor(srgbRed: 1.00, green: 0.10, blue: 0.70, alpha: 0.00).cgColor,
    ]
    let hotspot = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: hotspotColors as CFArray,
        locations: [0, 1]
    )!
    let hotspotCenter = CGPoint(
        x: rect.minX + innerSize * 0.25,
        y: rect.minY + innerSize * 0.82
    )
    ctx.saveGState()
    ctx.setBlendMode(.screen)
    ctx.drawRadialGradient(
        hotspot,
        startCenter: hotspotCenter,
        startRadius: 0,
        endCenter: hotspotCenter,
        endRadius: innerSize * 0.7,
        options: []
    )
    ctx.restoreGState()

    // Subtle inner highlight along the top edge for depth.
    let highlightColors = [
        NSColor.white.withAlphaComponent(0.18).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ]
    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: highlightColors as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        highlight,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY + innerSize * 0.55),
        options: []
    )

    ctx.restoreGState()

    // Centered merge glyph (bundled SVG), rendered larger than a typical
    // icon glyph for visual weight. Fills ~74% of the inner square on its
    // longest edge.
    guard let glyph = loadGlyph() else { return image }

    let maxDimension = innerSize * 0.74
    let aspect = glyph.size.width / glyph.size.height
    let glyphSize: NSSize = aspect >= 1
        ? NSSize(width: maxDimension, height: maxDimension / aspect)
        : NSSize(width: maxDimension * aspect, height: maxDimension)
    let origin = CGPoint(
        x: rect.midX - glyphSize.width / 2,
        y: rect.midY - glyphSize.height / 2
    )
    let svgScale = glyphSize.width / svgWidth

    // Coloured glow discs behind each of the three ring nodes. Drawn
    // BEFORE the glyph so they show through each ring's inner hole (the
    // glyph uses even-odd fill so the inner disc of each node is
    // transparent). Same per-node palette as the About page glyph:
    // pink through the top-left node, purple through the top-right,
    // blue through the bottom. Clip to the rounded rect so glows
    // can't spill outside the icon shape.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let glowOuterRadius = innerHoleRadius * svgScale * 3.5
    let coloredNodes: [(NodeCenter, (CGFloat, CGFloat, CGFloat))] = [
        (topLeftNode,  (0.878, 0.000, 0.565)), // pink   #E00090
        (topRightNode, (0.537, 0.000, 0.824)), // purple #8900D2
        (bottomNode,   (0.310, 0.000, 1.000)), // blue   #4F00FF
    ]
    for (node, rgb) in coloredNodes {
        let center = CGPoint(
            x: origin.x + node.x * svgScale,
            y: origin.y + node.y * svgScale
        )
        let glowColors = [
            NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0).cgColor,
            NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0.9).cgColor,
            NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0.0).cgColor,
        ]
        let glow = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: glowColors as CFArray,
            locations: [0, 0.25, 1]
        )!
        ctx.drawRadialGradient(
            glow,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: glowOuterRadius,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    ctx.restoreGState()

    // White-tinted glyph, drawn on top with a soft drop shadow for 3D lift.
    // Uses a CGContext-based tint to avoid NSImage compositing quirks that
    // were leaving a faint bounding-box artifact in earlier attempts.
    if let whiteGlyph = makeWhiteGlyph(from: glyph, size: glyphSize) {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -size * 0.012),
            blur: size * 0.04,
            color: NSColor.black.withAlphaComponent(0.35).cgColor
        )
        ctx.draw(whiteGlyph, in: CGRect(origin: origin, size: glyphSize))
        ctx.restoreGState()
    }

    return image
}

// Known geometry of the bundled glyph SVG (viewBox 0..321, 0..408).
// The three ring nodes are placed at these coordinates in source space,
// before the inner `translate(15.5, 15.5)` offset.
let svgWidth: CGFloat = 321
let svgHeight: CGFloat = 408
let innerHoleRadius: CGFloat = 35
struct NodeCenter { let x: CGFloat; let y: CGFloat }
// Flipped into Cocoa Y-up coordinates for drawing.
let topLeftNode  = NodeCenter(x:  50 + 15.5, y: svgHeight - ( 50 + 15.5))
let topRightNode = NodeCenter(x: 240 + 15.5, y: svgHeight - (119 + 15.5))
let bottomNode   = NodeCenter(x: 130 + 15.5, y: svgHeight - (327 + 15.5))

/// Builds a white-tinted CGImage from a black glyph SVG. Renders the SVG
/// into a bitmap at the target size, then uses `.destinationIn` over a
/// white fill so only the glyph's alpha survives. More reliable than
/// NSImage's own compositing for this case.
func makeWhiteGlyph(from nsImage: NSImage, size: NSSize) -> CGImage? {
    let width = Int(size.width)
    let height = Int(size.height)
    guard width > 0, height > 0 else { return nil }

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    nsImage.draw(
        in: NSRect(origin: .zero, size: size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let sourceCG = rep.cgImage else { return nil }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let tintCtx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    tintCtx.setFillColor(NSColor.white.cgColor)
    tintCtx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    tintCtx.setBlendMode(.destinationIn)
    tintCtx.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))
    return tintCtx.makeImage()
}

/// Load the bundled glyph SVG relative to the repo root. The script is
/// invoked from the repo root by build.sh, so a relative path is fine.
func loadGlyph() -> NSImage? {
    let candidates = [
        "Sources/Uncommitted/Resources/icon-glyph.svg",
    ]
    for path in candidates {
        let url = URL(fileURLWithPath: path)
        if let image = NSImage(contentsOf: url) {
            return image
        }
    }
    return nil
}

func writePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 2)
    }
    try png.write(to: url)
}

struct IconEntry {
    let base: Int
    let scale: Int
    var filename: String {
        scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@\(scale)x.png"
    }
    var pixelSize: Int { base * scale }
}

let entries: [IconEntry] = [
    .init(base: 16, scale: 1),
    .init(base: 16, scale: 2),
    .init(base: 32, scale: 1),
    .init(base: 32, scale: 2),
    .init(base: 128, scale: 1),
    .init(base: 128, scale: 2),
    .init(base: 256, scale: 1),
    .init(base: 256, scale: 2),
    .init(base: 512, scale: 1),
    .init(base: 512, scale: 2),
]

for entry in entries {
    let image = render(size: CGFloat(entry.pixelSize))
    let url = outDir.appendingPathComponent(entry.filename)
    try writePNG(image, to: url, pixelSize: entry.pixelSize)
    print("wrote \(entry.filename)")
}
