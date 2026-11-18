#!/usr/bin/env swift
import AppKit
import Foundation

// Generates a visibly distinct iOS 18+ dark Home Screen icon on macOS.
// Run before xcodebuild/actool, never as an iPhoneOS target Build Phase.
let folder = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let source = folder.appendingPathComponent("AppIcon.png")
let destination = folder.appendingPathComponent("AppIcon-Dark.png")

guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: source)),
      bitmap.pixelsWide == 1024, bitmap.pixelsHigh == 1024 else {
    fatalError("AppIcon.png must be a readable 1024x1024 PNG")
}

typealias RGB = (r: Int, g: Int, b: Int)
let background: RGB = (23, 104, 204)
let darkBackground: RGB = (12, 21, 38)
let lightForeground: RGB = (231, 240, 255)
let yellow: RGB = (255, 225, 122)
let blueAccent: RGB = (116, 182, 255)

func distance(_ a: RGB, _ b: RGB) -> Int {
    abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
}
func blend(_ a: RGB, _ b: RGB, fraction: Double) -> RGB {
    let t = min(1, max(0, fraction))
    return (Int((Double(a.r) * (1-t) + Double(b.r) * t).rounded()),
            Int((Double(a.g) * (1-t) + Double(b.g) * t).rounded()),
            Int((Double(a.b) * (1-t) + Double(b.b) * t).rounded()))
}

var changedPixels = 0
var bluePixels = 0
var foregroundPixels = 0
for y in 0..<bitmap.pixelsHigh {
    for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let old: RGB = (Int((color.redComponent * 255).rounded()),
                        Int((color.greenComponent * 255).rounded()),
                        Int((color.blueComponent * 255).rounded()))
        let mapped: RGB
        if distance(old, yellow) < 110 ||
           (old.r >= 180 && old.g >= 130 && old.b < 160 && old.r > old.b + 50) {
            mapped = blueAccent
            foregroundPixels += 1
        } else if old.r >= 215 && old.g >= 215 && old.b >= 215 {
            mapped = lightForeground
            foregroundPixels += 1
        } else if distance(old, background) < 110 ||
                  (old.b >= 120 && old.b > old.r + 40 && old.b > old.g + 15) {
            // Recolor the cobalt background; smoothly blend antialiased white edges.
            let whiteness = min(1, max(0, Double(old.r - background.r) / 232.0))
            mapped = blend(darkBackground, lightForeground, fraction: whiteness)
            bluePixels += 1
        } else {
            // Keep small design details that are outside the original blue/white/yellow palette.
            continue
        }
        if distance(old, mapped) > 4 {
            changedPixels += 1
            bitmap.setColor(NSColor(deviceRed: CGFloat(mapped.r) / 255,
                                    green: CGFloat(mapped.g) / 255,
                                    blue: CGFloat(mapped.b) / 255,
                                    alpha: color.alphaComponent), atX: x, y: y)
        }
    }
}

let total = bitmap.pixelsWide * bitmap.pixelsHigh
guard changedPixels >= total / 20, bluePixels >= total / 30 else {
    fatalError("Dark icon did not change enough pixels (changed: \(changedPixels), blue: \(bluePixels)); check the icon palette")
}
guard let imageData = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode AppIcon-Dark.png")
}
try imageData.write(to: destination, options: .atomic)
print("Generated iOS dark icon: \(changedPixels)/\(total) pixels changed, \(bluePixels) background pixels, \(foregroundPixels) foreground pixels")
