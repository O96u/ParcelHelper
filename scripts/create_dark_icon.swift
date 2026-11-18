#!/usr/bin/env swift
import AppKit
import Foundation

// This command-line build helper runs on macOS, not in the iOS app.
let folder = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let source = folder.appendingPathComponent("AppIcon.png")
let destination = folder.appendingPathComponent("AppIcon-Dark.png")

guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: source)) else {
    fatalError("Cannot read AppIcon.png")
}
let palette: [[UInt8]: [UInt8]] = [
    [23, 104, 204]: [14, 21, 37],
    [255, 255, 255]: [223, 234, 251],
    [255, 225, 122]: [96, 165, 250]
]

for y in 0..<bitmap.pixelsHigh {
    for x in 0..<bitmap.pixelsWide {
        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let rgb: [UInt8] = [c.redComponent, c.greenComponent, c.blueComponent].map {
            UInt8(max(0, min(255, Int(($0 * 255).rounded()))))
        }
        guard let new = palette[rgb] else { continue }
        bitmap.setColor(NSColor(deviceRed: CGFloat(new[0]) / 255,
                                green: CGFloat(new[1]) / 255,
                                blue: CGFloat(new[2]) / 255,
                                alpha: c.alphaComponent), atX: x, y: y)
    }
}
guard let imageData = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode dark icon")
}
try imageData.write(to: destination, options: .atomic)
print("Generated dark appearance icon with Swift")
