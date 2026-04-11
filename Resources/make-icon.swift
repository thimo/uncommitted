#!/usr/bin/env swift
// Generates an .iconset directory with all sizes macOS expects for iconutil.
// Drawing: rounded-square gradient background (blue → purple), centered SF
// `arrow.triangle.branch` symbol in white with a subtle drop shadow.

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

    // Centered SF Symbol, white, bold-ish.
    let symbolPointSize = size * 0.54
    let symbolConfig = NSImage.SymbolConfiguration(
        pointSize: symbolPointSize,
        weight: .semibold
    ).applying(.init(paletteColors: [.white]))

    if let symbolBase = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil),
       let symbol = symbolBase.withSymbolConfiguration(symbolConfig) {
        let symbolSize = symbol.size
        let origin = CGPoint(
            x: (size - symbolSize.width) / 2,
            y: (size - symbolSize.height) / 2
        )

        // Soft drop shadow under the symbol.
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
        shadow.shadowBlurRadius = size * 0.035
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.set()

        symbol.draw(
            at: origin,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
    }

    return image
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
