import AppKit
import CoreGraphics

/// Retain native vectors and create bounded rasters for posters, OCR and visible-region detail.
public enum SVGImageRenderer {
    public static func render(_ url: URL, maxDimension: Int = 2048, allowUpscaling: Bool = false) throws -> (bitmap: CGImage, vector: NSImage) {
        guard maxDimension > 0, let vector = NSImage(contentsOf: url) else { throw ImageFailure.unreadable }
        let size = vector.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw ImageFailure.unreadable
        }
        vector.cacheMode = .never
        let requestedScale = CGFloat(min(maxDimension, 4096)) / max(size.width, size.height)
        let scale = allowUpscaling ? requestedScale : min(1, requestedScale)
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageFailure.renderFailed
        }
        try Task.checkCancellation()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        vector.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero,
                    operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        try Task.checkCancellation()
        guard let bitmap = context.makeImage() else { throw ImageFailure.renderFailed }
        return (bitmap, vector)
    }
    /// Render only the visible normalized rectangle, preserving detail at high zoom
    /// without allocating a bitmap for the entire enlarged vector document.
    public static func renderRegion(_ url: URL, region: CGRect, pixelSize: CGSize, quarterTurns: Int = 0) throws -> CGImage {
        try renderRegion(data: Data(contentsOf: url), region: region, pixelSize: pixelSize, quarterTurns: quarterTurns)
    }
    public static func draw(data: Data, in rect: CGRect, context: CGContext, opacity: Double = 1) throws {
        guard let vector = NSImage(data: data), vector.size.width > 0, vector.size.height > 0 else { throw ImageFailure.unreadable }
        vector.cacheMode = .never
        context.saveGState()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer(); context.restoreGState() }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        vector.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }
    public static func renderRegion(data: Data, region: CGRect, pixelSize: CGSize, quarterTurns: Int = 0) throws -> CGImage {
        guard region.minX.isFinite, region.minY.isFinite, region.width.isFinite, region.height.isFinite,
              region.width > 0, region.height > 0, CGRect(x: 0, y: 0, width: 1, height: 1).contains(region),
              pixelSize.width.isFinite, pixelSize.height.isFinite, pixelSize.width > 0, pixelSize.height > 0,
              let vector = NSImage(data: data), vector.size.width > 0, vector.size.height > 0 else { throw ImageFailure.unreadable }
        let factor = min(1, 4096 / max(pixelSize.width, pixelSize.height))
        let width = max(1, Int((pixelSize.width * factor).rounded())), height = max(1, Int((pixelSize.height * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageFailure.renderFailed }
        try Task.checkCancellation()
        let q = (quarterTurns % 4 + 4) % 4, original = vector.size
        let rotated = q % 2 == 0 ? original : CGSize(width: original.height, height: original.width)
        let fullWidth = CGFloat(width) / region.width, fullHeight = CGFloat(height) / region.height
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -region.minX * fullWidth, y: -region.minY * fullHeight)
        context.scaleBy(x: fullWidth / rotated.width, y: fullHeight / rotated.height)
        switch q {
        case 1: context.translateBy(x: 0, y: original.width); context.rotate(by: -.pi / 2)
        case 2: context.translateBy(x: original.width, y: original.height); context.rotate(by: .pi)
        case 3: context.translateBy(x: original.height, y: 0); context.rotate(by: .pi / 2)
        default: break
        }
        context.translateBy(x: 0, y: original.height); context.scaleBy(x: 1, y: -1)
        vector.cacheMode = .never
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        vector.draw(in: CGRect(origin: .zero, size: original), from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw ImageFailure.renderFailed }
        return image
    }
}
