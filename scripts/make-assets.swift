import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent("build/EasyPic.iconset")
let fixtures = root.appendingPathComponent("build/Fixtures")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)

func savePNG(_ image: NSImage, to url: URL) throws {
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
let sourceIcon = root.appendingPathComponent("Assets/EasyPicIcon.png")
guard let icon = NSImage(contentsOf: sourceIcon) else {
    fatalError("无法读取应用图标：\(sourceIcon.path)")
}
for size in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = size * factor
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        // The source PNG already supplies its rounded silhouette and transparent alpha.
        icon.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (factor == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
// Synthetic, labeled fixtures for inspecting crop/rotation; no user photos involved.
for (name, width, height, transparent) in [("Landscape.png", 1200, 800, false), ("Transparency.png", 640, 480, true)] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if !transparent {
        NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.42, blue: 0.57, alpha: 1), ending: NSColor(calibratedRed: 0.95, green: 0.67, blue: 0.4, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 65)
    }
    NSColor(calibratedRed: 1, green: 0.82, blue: 0.51, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: Double(width) * 0.72, y: Double(height) * 0.60, width: Double(height) * 0.14, height: Double(height) * 0.14)).fill()
    for (y, color) in [(0.18, NSColor(calibratedRed: 0.13, green: 0.34, blue: 0.36, alpha: 1)), (0.0, NSColor(calibratedRed: 0.07, green: 0.21, blue: 0.24, alpha: 1))] {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0)); path.line(to: NSPoint(x: 0, y: Double(height) * (y + 0.2)))
        path.curve(to: NSPoint(x: Double(width), y: Double(height) * (y + 0.2)), controlPoint1: NSPoint(x: Double(width) * 0.35, y: Double(height) * (y + 0.65)), controlPoint2: NSPoint(x: Double(width) * 0.60, y: Double(height) * y))
        path.line(to: NSPoint(x: width, y: 0)); path.close(); color.setFill(); path.fill()
    }
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32, weight: .light), .foregroundColor: NSColor.white.withAlphaComponent(0.9)]
    ("EasyPic / \(width) × \(height)" as NSString).draw(at: NSPoint(x: 45, y: 45), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: fixtures.appendingPathComponent(name))
}
