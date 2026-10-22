import Foundation
import CoreGraphics
import CoreImage

public enum BrushTool: String, Codable, CaseIterable {
    case eraser, clone, repair, pixelate, blur, solid
    public var title: String {
        switch self { case .eraser: return L10n.text("擦除"); case .clone: return L10n.text("取样克隆"); case .repair: return L10n.text("消除"); case .pixelate: return L10n.text("像素马赛克"); case .blur: return L10n.text("模糊"); case .solid: return L10n.text("纯色画笔") }
    }
}
public struct BrushStroke: Codable, Equatable {
    public var tool: BrushTool
    public var points: [CGPoint]
    public var diameter: Double
    public var hardness: Double
    public var opacity: Double
    public var strength: Double
    public var color: TextColor
    public var source: CGPoint?
    public var rectangle: CGRect?
    public var shape: BrushShape?
    public var cornerRadius: Double?
    public var constrainCircle: Bool?
    public var isValid: Bool {
        let numbers = [diameter, hardness, opacity, strength, color.red, color.green, color.blue, color.alpha]
        return !points.isEmpty && points.allSatisfy { $0.x.isFinite && $0.y.isFinite } && numbers.allSatisfy(\.isFinite)
            && (1...10000).contains(diameter) && (0...1).contains(hardness) && (0...1).contains(opacity) && (1...1000).contains(strength)
            && [color.red,color.green,color.blue,color.alpha].allSatisfy { (0...1).contains($0) }
            && (source.map { $0.x.isFinite && $0.y.isFinite } ?? true)
            && (rectangle.map { $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width>=0 && $0.height>=0 } ?? true)
            && (cornerRadius.map { $0.isFinite && $0 >= 0 && $0 <= 10000 } ?? true)
            && (shape == nil || shape == .freehand || (tool == .solid && points.count >= 2))
    }
    public init(tool: BrushTool, points: [CGPoint], diameter: Double = 40, hardness: Double = 1, opacity: Double = 1, strength: Double = 16, color: TextColor = TextColor(0,0,0), source: CGPoint? = nil, rectangle: CGRect? = nil, shape: BrushShape? = nil, cornerRadius: Double? = nil, constrainCircle: Bool? = nil) {
        self.tool = tool; self.points = points; self.diameter = diameter; self.hardness = hardness; self.opacity = opacity; self.strength = strength; self.color = color; self.source = source; self.rectangle = rectangle
        self.shape = shape; self.cornerRadius = cornerRadius; self.constrainCircle = constrainCircle
    }
}
public enum BrushEngine {
    private static let ci = CIContext(options: [.cacheIntermediates: false])
    private static func bounds(_ stroke: BrushStroke, size: CGSize) -> CGRect {
        let radius = stroke.diameter / 2
        let extent: CGRect
        if let shape = stroke.shape, shape != .freehand {
            guard let path = BrushShapeGeometry.path(for: stroke) else { return .null }
            extent = path.boundingBoxOfPath.insetBy(dx: -radius - 1, dy: -radius - 1)
        }
        else if let rectangle = stroke.rectangle { extent = rectangle }
        else {
            let left = stroke.points.map(\.x).min()! - radius, top = stroke.points.map(\.y).min()! - radius
            extent = CGRect(x: left, y: top, width: stroke.points.map(\.x).max()! + radius - left,
                            height: stroke.points.map(\.y).max()! + radius - top)
        }
        return extent.intersection(CGRect(origin: .zero, size: size)).integral
    }
    /// A solid brush stroke is stored as a small transparent patch, rather than a full canvas.
    public static func paintLayer(_ stroke: BrushStroke, canvasSize: CGSize) throws -> (image: CGImage, rect: CGRect)? {
        guard stroke.isValid, stroke.tool == .solid else { throw ImageFailure.renderFailed }
        let region = bounds(stroke, size: canvasSize)
        guard !region.isNull, region.width > 0, region.height > 0 else { return nil }
        guard let clear = CGContext(data: nil, width: Int(region.width), height: Int(region.height), bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() else { throw ImageFailure.renderFailed }
        var mapped = stroke
        mapped.points = stroke.points.map { CGPoint(x: $0.x - region.minX, y: $0.y - region.minY) }
        mapped.rectangle = stroke.rectangle?.offsetBy(dx: -region.minX, dy: -region.minY)
        return (try apply(mapped, to: clear), region)
    }
    public static func apply(_ stroke: BrushStroke, to image: CGImage) throws -> CGImage {
        guard stroke.isValid else { throw ImageFailure.renderFailed }
        let width = image.width, height = image.height
        let region = bounds(stroke, size: CGSize(width: width, height: height))
        guard !region.isNull, region.width > 0, region.height > 0 else { return image }
        let left = Int(region.minX), top = Int(region.minY), right = Int(region.maxX), bottom = Int(region.maxY), maskWidth = Int(region.width)
        var mask = [Float](repeating: 0, count: Int(region.width * region.height))
        func maskIndex(_ x:Int,_ y:Int)->Int { (y-top)*maskWidth+x-left }
        func maskValue(_ x:Int,_ y:Int)->Float { x>=left && y>=top && x<right && y<bottom ? mask[maskIndex(x,y)] : 0 }
        func stamp(_ p: CGPoint) {
            let r = stroke.diameter / 2
            let minX = max(left, Int(floor(p.x - r))), maxX = min(right - 1, Int(ceil(p.x + r)))
            let minY = max(top, Int(floor(p.y - r))), maxY = min(bottom - 1, Int(ceil(p.y + r)))
            guard minX <= maxX, minY <= maxY else { return }
            for y in minY...maxY { for x in minX...maxX {
                let distance = hypot(Double(x) + 0.5 - p.x, Double(y) + 0.5 - p.y) / r
                let alpha = distance <= stroke.hardness ? 1 : max(0, (1 - distance) / max(0.001, 1 - stroke.hardness))
                mask[maskIndex(x,y)] = max(mask[maskIndex(x,y)], Float(alpha * stroke.opacity))
            } }
        }
        if let path = BrushShapeGeometry.path(for: stroke) {
            guard let context = CGContext(data: nil, width: maskWidth, height: Int(region.height), bitsPerComponent: 8,
                                          bytesPerRow: maskWidth, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ImageFailure.renderFailed }
            context.translateBy(x: -region.minX, y: -region.minY)
            context.setLineCap(.round); context.setLineJoin(.round); context.setBlendMode(.copy)
            let softness = 1 - stroke.hardness, bands = softness > 0 ? 20 : 1
            for band in 1...bands {
                try Task.checkCancellation()
                let strength = Double(band) / Double(bands)
                context.setStrokeColor(gray: strength, alpha: 1)
                context.setLineWidth(stroke.diameter * max(0.01, 1 - softness * strength))
                context.addPath(path); context.strokePath()
            }
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            for i in mask.indices { mask[i] = Float(bytes[i]) / 255 * Float(stroke.opacity) }
        } else if let rect = stroke.rectangle {
            guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { throw ImageFailure.invalidCrop }
            let clipped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            if !clipped.isNull { for y in Int(clipped.minY)..<Int(clipped.maxY) { for x in Int(clipped.minX)..<Int(clipped.maxX) { mask[maskIndex(x,y)] = Float(stroke.opacity) } } }
        } else {
            stamp(stroke.points[0])
            for i in 1..<stroke.points.count {
                try Task.checkCancellation()
                let a = stroke.points[i-1], b = stroke.points[i]
                let steps = max(1, Int(ceil(hypot(b.x-a.x, b.y-a.y) / max(0.5, stroke.diameter / 8))))
                for j in 1...steps { let t = Double(j) / Double(steps); stamp(CGPoint(x: a.x + (b.x-a.x)*t, y: a.y + (b.y-a.y)*t)) }
            }
        }
        try Task.checkCancellation()
        // Only repair needs neighboring pixels outside the mask. Core Image receives
        // the original extent below so Gaussian halos and the pixel grid stay global.
        let sample = (stroke.tool == .repair ? region.insetBy(dx: -max(16, min(96, stroke.diameter * 1.5)), dy: -max(16, min(96, stroke.diameter * 1.5))) : region)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        let sampleLeft = Int(sample.minX), sampleTop = Int(sample.minY), sampleWidth = Int(sample.width)
        func index(_ x: Int, _ y: Int) -> Int { ((y - sampleTop) * sampleWidth + x - sampleLeft) * 4 }
        func patchContext() throws -> CGContext {
            guard let context = CGContext(data: nil, width: sampleWidth, height: Int(sample.height),
                                          bitsPerComponent: 8, bytesPerRow: sampleWidth * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageFailure.renderFailed }
            return context
        }
        guard let cropped = image.cropping(to: sample) else { throw ImageFailure.renderFailed }
        let patch = try patchContext()
        patch.draw(cropped, in: CGRect(origin: .zero, size: sample.size))
        let destination = patch.data!.assumingMemoryBound(to: UInt8.self)
        let sourceBytes = Array(UnsafeBufferPointer(start: destination, count: sampleWidth * Int(sample.height) * 4))
        var filtered = sourceBytes
        if stroke.tool == .pixelate || stroke.tool == .blur {
            let input = CIImage(cgImage: image)
            let result = input.clampedToExtent().applyingFilter(stroke.tool == .pixelate ? "CIPixellate" : "CIGaussianBlur", parameters: [stroke.tool == .pixelate ? kCIInputScaleKey : kCIInputRadiusKey: stroke.strength]).cropped(to: input.extent)
            let area = CGRect(x: sample.minX, y: CGFloat(height) - sample.maxY, width: sample.width, height: sample.height)
            // Align the output origin to the full image's downsampling grid. Gaussian
            // implementations may internally use several resolutions even with a full input.
            let tile: CGFloat = 256
            let aligned = CGRect(x: floor(area.minX / tile) * tile, y: floor(area.minY / tile) * tile,
                                 width: ceil(area.maxX / tile) * tile - floor(area.minX / tile) * tile,
                                 height: ceil(area.maxY / tile) * tile - floor(area.minY / tile) * tile).intersection(input.extent)
            guard let rendered = ci.createCGImage(result, from: aligned),
                  let bitmap = rendered.cropping(to: CGRect(x: area.minX - aligned.minX, y: aligned.maxY - area.maxY,
                                                           width: area.width, height: area.height)) else { throw ImageFailure.renderFailed }
            let context = try patchContext()
            context.draw(bitmap, in: CGRect(origin: .zero, size: sample.size))
            filtered = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: sourceBytes.count))
        }
        var cloneBytes: [UInt8] = [], cloneArea = CGRect.null
        if stroke.tool == .clone {
            guard let source = stroke.source else { throw ImageFailure.renderFailed }
            let dx = source.x - stroke.points[0].x, dy = source.y - stroke.points[0].y
            let x0 = (Double(left) + dx).rounded(), y0 = (Double(top) + dy).rounded()
            let x1 = (Double(right - 1) + dx).rounded() + 1, y1 = (Double(bottom - 1) + dy).rounded() + 1
            cloneArea = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            if !cloneArea.isNull, cloneArea.width > 0, cloneArea.height > 0, let cropped = image.cropping(to: cloneArea),
               let context = CGContext(data: nil, width: Int(cloneArea.width), height: Int(cloneArea.height), bitsPerComponent: 8,
                                       bytesPerRow: Int(cloneArea.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(cropped, in: CGRect(origin: .zero, size: cloneArea.size))
                cloneBytes = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: Int(cloneArea.width * cloneArea.height) * 4))
            }
        }
        if stroke.tool == .repair {
            var localMask = [Float](repeating: 0, count: sampleWidth * Int(sample.height))
            for y in top..<bottom { for x in left..<right {
                localMask[(y - sampleTop) * sampleWidth + x - sampleLeft] = maskValue(x, y)
            } }
            filtered = try ContentAwareFill.fill(bytes: sourceBytes, width: sampleWidth, height: Int(sample.height), mask: localMask)
        }
        for y in top..<bottom { for x in left..<right {
            let a = Double(maskValue(x,y)); guard a > 0 else { continue }
            let index = index(x, y)
            var replacement = Array(filtered[index..<index+4])
            if stroke.tool == .eraser { replacement = [0,0,0,0] }
            if stroke.tool == .solid { replacement = [UInt8(stroke.color.red*stroke.color.alpha*255), UInt8(stroke.color.green*stroke.color.alpha*255), UInt8(stroke.color.blue*stroke.color.alpha*255), UInt8(stroke.color.alpha*255)] }
            if stroke.tool == .clone {
                guard let source = stroke.source else { throw ImageFailure.renderFailed }
                let sx = Int((Double(x) + source.x - stroke.points[0].x).rounded()), sy = Int((Double(y) + source.y - stroke.points[0].y).rounded())
                guard sx>=0,sy>=0,sx<width,sy<height else { continue }
                guard !cloneBytes.isEmpty, cloneArea.contains(CGPoint(x: sx, y: sy)) else { continue }
                let sourceIndex = ((sy - Int(cloneArea.minY)) * Int(cloneArea.width) + sx - Int(cloneArea.minX)) * 4
                replacement = Array(cloneBytes[sourceIndex..<sourceIndex+4])
            }
            for c in 0..<4 { destination[index+c] = UInt8(min(255,max(0,(Double(sourceBytes[index+c])*(1-a)+Double(replacement[c])*a).rounded()))) }
        } }
        try Task.checkCancellation()
        guard let updated = patch.makeImage(),
              let output = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageFailure.renderFailed }
        output.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        output.setBlendMode(.copy)
        output.draw(updated, in: CGRect(x: sample.minX, y: CGFloat(height) - sample.maxY, width: sample.width, height: sample.height))
        guard let result = output.makeImage() else { throw ImageFailure.renderFailed }
        return result
    }
}
