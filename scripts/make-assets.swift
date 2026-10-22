import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent("build/EasyPic.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

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
