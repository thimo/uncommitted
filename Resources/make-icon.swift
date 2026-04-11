#!/usr/bin/env swift
// Generates an .iconset directory with all sizes macOS expects for iconutil.
// Drawing: rounded-square gradient background (blue → purple) with a custom
// "git branch graph" glyph in white — three stroked circles connected by a
// vertical spine and a curving branch line, the shape the git logo uses and
// the one most developers recognize at a glance.

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

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.225 // macOS Big Sur-style rounded square
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Gradient background: top-left light blue → bottom-right deep indigo.
    let colors = [
        NSColor(srgbRed: 0.38, green: 0.73, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 0.43, green: 0.30, blue: 0.95, alpha: 1).cgColor,
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )

    // Subtle inner highlight along the top edge.
    let highlightColors = [
        NSColor.white.withAlphaComponent(0.22).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ]
    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: highlightColors as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        highlight,
        start: CGPoint(x: size / 2, y: size),
        end: CGPoint(x: size / 2, y: size * 0.55),
        options: []
    )

    ctx.restoreGState()

    // Custom git-branch glyph: three stroked circles connected by a
    // vertical spine (between two left-column dots) and a curving branch
    // line out to a right-column dot. All in white with a soft drop
    // shadow. Geometry is normalized against `size` so it scales cleanly.
    drawBranchGlyph(in: ctx, size: size)

    return image
}

/// Draws the branch graph glyph centered in the canvas.
/// Coordinate system is Core Graphics: origin bottom-left, Y goes up.
func drawBranchGlyph(in ctx: CGContext, size: CGFloat) {
    ctx.saveGState()
    defer { ctx.restoreGState() }

    // Normalized geometry. Kept tighter than a typical Lucide-style
    // git-branch icon — left column nearly hugs the right column so the
    // glyph doesn't feel wide.
    let dotRadius = size * 0.085
    let strokeWidth = size * 0.055

    // Dot centers in 0..1 space, then scaled to pixel space.
    // CG origin is bottom-left; "top" visually = larger Y.
    let bottomDot = CGPoint(x: size * 0.34, y: size * 0.25)
    let topDot    = CGPoint(x: size * 0.34, y: size * 0.75)
    let rightDot  = CGPoint(x: size * 0.70, y: size * 0.75)

    // Soft drop shadow on everything we draw.
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.shadowBlurRadius = size * 0.04
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.set()

    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // --- Spine: vertical line between top edge of bottom dot and bottom
    // edge of top dot.
    ctx.move(to: CGPoint(x: bottomDot.x, y: bottomDot.y + dotRadius))
    ctx.addLine(to: CGPoint(x: topDot.x,    y: topDot.y - dotRadius))
    ctx.strokePath()

    // --- Branch: curves from the spine out to the left edge of the right
    // dot. Start the branch roughly at the same height as the top dot so
    // the curve arcs gracefully up-and-right.
    let branchStart = CGPoint(x: topDot.x, y: topDot.y - dotRadius * 0.2)
    let branchEnd   = CGPoint(x: rightDot.x - dotRadius, y: rightDot.y)
    // Control point forces a smooth right-then-up curve.
    let control     = CGPoint(x: rightDot.x - dotRadius, y: branchStart.y)

    ctx.move(to: branchStart)
    ctx.addQuadCurve(to: branchEnd, control: control)
    ctx.strokePath()

    // --- Three dots. Draw as stroked rings (hollow), matching the
    // reference image's outlined-circle style.
    let innerRadius = dotRadius - strokeWidth / 2
    for dot in [bottomDot, topDot, rightDot] {
        // Punch a hole so the spine/branch lines visibly enter the
        // circles: first fill background color to clear anything behind,
        // then stroke the ring.
        let outerRect = CGRect(
            x: dot.x - dotRadius,
            y: dot.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        // Solid fill inside the ring to hide line endings that would
        // otherwise show through. Use the gradient background color by
        // clipping — but simpler: just draw a stroked ring and let the
        // line caps round off cleanly at the dot edges.
        ctx.strokeEllipse(in: outerRect)
        _ = innerRadius
    }
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
