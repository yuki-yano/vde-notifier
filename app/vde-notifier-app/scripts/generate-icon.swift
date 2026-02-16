#!/usr/bin/env swift
import AppKit
import Foundation

// Generate a notification bell icon for VdeNotifierApp
// Modern macOS app icon style: rounded rect background with bell symbol

func createIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // --- Background: rounded rectangle with gradient ---
    let cornerRadius = size * 0.22
    let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.02, dy: size * 0.02),
                               xRadius: cornerRadius, yRadius: cornerRadius)

    // Gradient: deep blue to purple
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.18, green: 0.35, blue: 0.82, alpha: 1.0),
        NSColor(calibratedRed: 0.45, green: 0.25, blue: 0.85, alpha: 1.0),
        NSColor(calibratedRed: 0.55, green: 0.20, blue: 0.75, alpha: 1.0),
    ], atLocations: [0.0, 0.5, 1.0], colorSpace: .deviceRGB)!

    gradient.draw(in: bgPath, angle: -45)

    // Subtle inner shadow / border
    let borderPath = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.025, dy: size * 0.025),
                                   xRadius: cornerRadius * 0.98, yRadius: cornerRadius * 0.98)
    NSColor(white: 1.0, alpha: 0.15).setStroke()
    borderPath.lineWidth = size * 0.01
    borderPath.stroke()

    // --- Bell icon ---
    let bellColor = NSColor(white: 1.0, alpha: 0.95)
    bellColor.setFill()

    let cx = size * 0.5
    let cy = size * 0.52

    // Bell body dimensions
    let bellWidth = size * 0.38
    let bellHeight = size * 0.34
    let bellTop = cy + bellHeight * 0.45
    let bellBottom = cy - bellHeight * 0.55

    // Draw bell body using bezier curves
    let bellPath = NSBezierPath()

    // Start from bottom-left of bell
    let bottomY = bellBottom
    let bottomLeftX = cx - bellWidth * 0.55
    let bottomRightX = cx + bellWidth * 0.55

    bellPath.move(to: NSPoint(x: bottomLeftX, y: bottomY))

    // Left side curve up
    bellPath.curve(to: NSPoint(x: cx - bellWidth * 0.28, y: bellTop),
                   controlPoint1: NSPoint(x: bottomLeftX, y: cy - bellHeight * 0.1),
                   controlPoint2: NSPoint(x: cx - bellWidth * 0.28, y: cy + bellHeight * 0.1))

    // Top curve (dome)
    bellPath.curve(to: NSPoint(x: cx + bellWidth * 0.28, y: bellTop),
                   controlPoint1: NSPoint(x: cx - bellWidth * 0.28, y: bellTop + bellHeight * 0.28),
                   controlPoint2: NSPoint(x: cx + bellWidth * 0.28, y: bellTop + bellHeight * 0.28))

    // Right side curve down
    bellPath.curve(to: NSPoint(x: bottomRightX, y: bottomY),
                   controlPoint1: NSPoint(x: cx + bellWidth * 0.28, y: cy + bellHeight * 0.1),
                   controlPoint2: NSPoint(x: bottomRightX, y: cy - bellHeight * 0.1))

    // Bottom flat part with slight curve
    bellPath.line(to: NSPoint(x: bottomLeftX, y: bottomY))
    bellPath.close()
    bellPath.fill()

    // Bell bottom bar (the rim)
    let rimHeight = size * 0.035
    let rimRect = CGRect(x: cx - bellWidth * 0.6,
                         y: bottomY - rimHeight * 0.5,
                         width: bellWidth * 1.2,
                         height: rimHeight)
    let rimPath = NSBezierPath(roundedRect: rimRect, xRadius: rimHeight * 0.5, yRadius: rimHeight * 0.5)
    rimPath.fill()

    // Bell clapper (small circle at bottom)
    let clapperRadius = size * 0.045
    let clapperCenter = NSPoint(x: cx, y: bottomY - rimHeight - clapperRadius * 0.8)
    let clapperPath = NSBezierPath(ovalIn: CGRect(
        x: clapperCenter.x - clapperRadius,
        y: clapperCenter.y - clapperRadius,
        width: clapperRadius * 2,
        height: clapperRadius * 2
    ))
    clapperPath.fill()

    // Bell handle (small stem at top)
    let handleWidth = size * 0.03
    let handleHeight = size * 0.05
    let handleRect = CGRect(x: cx - handleWidth * 0.5,
                            y: bellTop + bellHeight * 0.18,
                            width: handleWidth,
                            height: handleHeight)
    let handlePath = NSBezierPath(roundedRect: handleRect, xRadius: handleWidth * 0.5, yRadius: handleWidth * 0.5)
    handlePath.fill()

    // --- Notification dot (orange/red circle at top-right) ---
    let dotRadius = size * 0.09
    let dotCenter = NSPoint(x: cx + bellWidth * 0.32, y: bellTop + bellHeight * 0.15)

    // Dot shadow
    NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.2).setFill()
    let dotShadow = NSBezierPath(ovalIn: CGRect(
        x: dotCenter.x - dotRadius - size * 0.005,
        y: dotCenter.y - dotRadius - size * 0.01,
        width: dotRadius * 2 + size * 0.01,
        height: dotRadius * 2 + size * 0.01
    ))
    dotShadow.fill()

    // Dot fill (orange-red)
    let dotGradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.25, alpha: 1.0),
        NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.2, alpha: 1.0),
    ])!
    let dotPath = NSBezierPath(ovalIn: CGRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    ))
    dotGradient.draw(in: dotPath, angle: -45)

    // Dot highlight
    NSColor(white: 1.0, alpha: 0.4).setFill()
    let highlightPath = NSBezierPath(ovalIn: CGRect(
        x: dotCenter.x - dotRadius * 0.4,
        y: dotCenter.y + dotRadius * 0.1,
        width: dotRadius * 0.7,
        height: dotRadius * 0.5
    ))
    highlightPath.fill()

    // --- Terminal cursor hint (small ">" in the bell) ---
    let cursorColor = NSColor(white: 1.0, alpha: 0.3)
    cursorColor.setStroke()
    let cursorPath = NSBezierPath()
    let cursorSize = size * 0.08
    let cursorX = cx - cursorSize * 0.4
    let cursorY = cy - size * 0.02
    cursorPath.move(to: NSPoint(x: cursorX, y: cursorY + cursorSize * 0.5))
    cursorPath.line(to: NSPoint(x: cursorX + cursorSize * 0.6, y: cursorY))
    cursorPath.line(to: NSPoint(x: cursorX, y: cursorY - cursorSize * 0.5))
    cursorPath.lineWidth = size * 0.02
    cursorPath.lineCapStyle = .round
    cursorPath.lineJoinStyle = .round
    cursorPath.stroke()

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String, size: Int) {
    let targetSize = NSSize(width: size, height: size)
    let resized = NSImage(size: targetSize)
    resized.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: targetSize),
               from: NSRect(origin: .zero, size: image.size),
               operation: .copy, fraction: 1.0)
    resized.unlockFocus()

    guard let tiffData = resized.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG for size \(size)")
        return
    }

    do {
        try pngData.write(to: URL(fileURLWithPath: path))
        print("Created: \(path)")
    } catch {
        print("Failed to write \(path): \(error)")
    }
}

// Main
let args = CommandLine.arguments
guard args.count > 1 else {
    print("Usage: generate-icon.swift <output-directory>")
    exit(1)
}

let outputDir = args[1]

// Generate base icon at high resolution
let baseImage = createIcon(size: 1024)

// macOS iconset sizes
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

// Create iconset directory
let iconsetDir = "\(outputDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for entry in sizes {
    savePNG(baseImage, to: "\(iconsetDir)/\(entry.name).png", size: entry.pixels)
}

print("Iconset created at: \(iconsetDir)")
print("Run: iconutil -c icns \(iconsetDir) -o <output>.icns")
