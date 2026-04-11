#!/usr/bin/env swift
// Generates an .iconset directory with all sizes macOS expects for iconutil.
// Pink → purple → blue gradient background with the hand-drawn branch
// glyph from Sources/Uncommitted/Resources/icon-glyph.svg composited on
// top, tinted white with a soft drop shadow.

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

// Path is relative to the repo root (build.sh cwd).
let glyphSVGURL = URL(fileURLWithPath: "Sources/Uncommitted/Resources/icon-glyph.svg")
guard let rawGlyph = NSImage(contentsOf: glyphSVGURL) else {
    FileHandle.standardError.write("make-icon: couldn't load \(glyphSVGURL.path)\n".data(using: .utf8)!)
    exit(1)
}

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.225
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Pink → purple → blue gradient. "Heavy" pink — the first stop holds
    // the top ~55% of the gradient space before transitioning.
    let colors = [
        NSColor(srgbRed: 1.00, green: 0.20, blue: 0.58, alpha: 1).cgColor, // hot pink
        NSColor(srgbRed: 0.55, green: 0.28, blue: 0.92, alpha: 1).cgColor, // purple
        NSColor(srgbRed: 0.22, green: 0.56, blue: 1.00, alpha: 1).cgColor, // blue
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),       // top-left: pink
        end: CGPoint(x: size, y: 0),         // bottom-right: blue
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

    // Composite the white-tinted SVG glyph centered over the gradient.
    let tinted = tintedImage(rawGlyph, color: .white)
    let glyphAspect = rawGlyph.size.width / rawGlyph.size.height
    let glyphHeight = size * 0.62
    let glyphWidth = glyphHeight * glyphAspect
    let glyphOrigin = CGPoint(
        x: (size - glyphWidth) / 2,
        y: (size - glyphHeight) / 2
    )
    let glyphRect = NSRect(x: glyphOrigin.x, y: glyphOrigin.y, width: glyphWidth, height: glyphHeight)

    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.045
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.set()

    tinted.draw(
        in: glyphRect,
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )

    return image
}

/// Returns a copy of `source` where every non-transparent pixel has been
/// replaced with `color`. Used to tint a black-stroked SVG white.
func tintedImage(_ source: NSImage, color: NSColor) -> NSImage {
    let rect = NSRect(origin: .zero, size: source.size)
    let result = NSImage(size: source.size)
    result.lockFocus()
    source.draw(in: rect)
    color.set()
    rect.fill(using: .sourceAtop)
    result.unlockFocus()
    return result
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
