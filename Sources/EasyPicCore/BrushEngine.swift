import Foundation
import CoreGraphics
import CoreImage

public enum BrushTool: String, Codable, CaseIterable {
    case eraser, clone, repair, pixelate, blur, solid
    public var title: String {
        switch self { case .eraser: return "擦除"; case .clone: return "取样克隆"; case .repair: return "消除"; case .pixelate: return "像素马赛克"; case .blur: return "模糊"; case .solid: return "纯色遮盖" }
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
    public var isValid: Bool {
        let numbers = [diameter, hardness, opacity, strength, color.red, color.green, color.blue, color.alpha]
        return !points.isEmpty && points.allSatisfy { $0.x.isFinite && $0.y.isFinite } && numbers.allSatisfy(\.isFinite)
            && (1...10000).contains(diameter) && (0...1).contains(hardness) && (0...1).contains(opacity) && (1...1000).contains(strength)
            && [color.red,color.green,color.blue,color.alpha].allSatisfy { (0...1).contains($0) }
            && (source.map { $0.x.isFinite && $0.y.isFinite } ?? true)
            && (rectangle.map { $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width>=0 && $0.height>=0 } ?? true)
    }
    public init(tool: BrushTool, points: [CGPoint], diameter: Double = 40, hardness: Double = 1, opacity: Double = 1, strength: Double = 16, color: TextColor = TextColor(0,0,0), source: CGPoint? = nil, rectangle: CGRect? = nil) {
        self.tool = tool; self.points = points; self.diameter = diameter; self.hardness = hardness; self.opacity = opacity; self.strength = strength; self.color = color; self.source = source; self.rectangle = rectangle
    }
}
public enum BrushEngine {
    private static let ci = CIContext(options: [.cacheIntermediates: false])
    public static func apply(_ stroke: BrushStroke, to image: CGImage) throws -> CGImage {
        guard stroke.isValid else { throw ImageFailure.renderFailed }
        let width = image.width, height = image.height
        func context() throws -> CGContext {
            guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageFailure.renderFailed }; return c
        }
        let output = try context(); output.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let radius = stroke.diameter / 2
        let extent: CGRect
        if let rectangle = stroke.rectangle { extent = rectangle }
        else {
            let minX = stroke.points.map(\.x).min()! - radius, minY = stroke.points.map(\.y).min()! - radius
            extent = CGRect(x:minX,y:minY,width:stroke.points.map(\.x).max()! + radius - minX,height:stroke.points.map(\.y).max()! + radius - minY)
        }
        let region = extent.intersection(CGRect(x:0,y:0,width:width,height:height)).integral
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
        if let rect = stroke.rectangle {
            guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { throw ImageFailure.invalidCrop }
            let clipped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            if !clipped.isNull { for y in Int(clipped.minY)..<Int(clipped.maxY) { for x in Int(clipped.minX)..<Int(clipped.maxX) { mask[maskIndex(x,y)] = Float(stroke.opacity) } } }
        } else {
            stamp(stroke.points[0])
            for i in 1..<stroke.points.count {
                let a = stroke.points[i-1], b = stroke.points[i]
                let steps = max(1, Int(ceil(hypot(b.x-a.x, b.y-a.y) / max(0.5, stroke.diameter / 8))))
                for j in 1...steps { let t = Double(j) / Double(steps); stamp(CGPoint(x: a.x + (b.x-a.x)*t, y: a.y + (b.y-a.y)*t)) }
            }
        }
        let destination = output.data!.assumingMemoryBound(to: UInt8.self)
        let sourceBytes = Array(UnsafeBufferPointer(start: destination, count: width * height * 4))
        var filtered = sourceBytes
        if stroke.tool == .pixelate || stroke.tool == .blur {
            let input = CIImage(cgImage: image)
            let result = input.clampedToExtent().applyingFilter(stroke.tool == .pixelate ? "CIPixellate" : "CIGaussianBlur", parameters: [stroke.tool == .pixelate ? kCIInputScaleKey : kCIInputRadiusKey: stroke.strength]).cropped(to: input.extent)
            guard let bitmap = ci.createCGImage(result, from: input.extent) else { throw ImageFailure.renderFailed }
            let c = try context(); c.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
            filtered = Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: sourceBytes.count))
        }
        if stroke.tool == .repair {
            // Fill from the known boundary inward. Previously filled pixels become
            // samples for the next frontier, avoiding repeated copies of a single patch.
            var known = [Bool](repeating: false, count: mask.count)
            var frontier: [(Int, Int)] = []
            for y in top..<bottom { for x in left..<right {
                if maskValue(x,y) == 0 { known[maskIndex(x,y)] = true }
                else if [(x-1,y),(x+1,y),(x,y-1),(x,y+1)].contains(where: { px,py in px>=0 && py>=0 && px<width && py<height && maskValue(px,py)==0 }) { frontier.append((x,y)) }
            } }
            var cursor = 0
            while cursor < frontier.count {
                let (x,y) = frontier[cursor]; cursor += 1
                if known[maskIndex(x,y)] { continue }
                var values = [Double](repeating:0,count:4), total = 0.0
                for dy in -2...2 { for dx in -2...2 where dx != 0 || dy != 0 {
                    let sx=x+dx, sy=y+dy
                    guard sx>=0,sy>=0,sx<width,sy<height else { continue }
                    let valid = maskValue(sx,sy)==0 || (sx>=left && sx<right && sy>=top && sy<bottom && known[maskIndex(sx,sy)])
                    guard valid else { continue }
                    let weight = 1 / Double(dx*dx+dy*dy)
                    for c in 0..<4 { values[c] += Double(filtered[(sy*width+sx)*4+c])*weight }; total += weight
                } }
                guard total > 0 else { continue }
                for c in 0..<4 { filtered[(y*width+x)*4+c] = UInt8((values[c]/total).rounded()) }
                known[maskIndex(x,y)] = true
                for (sx,sy) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where sx>=left && sx<right && sy>=top && sy<bottom {
                    if !known[maskIndex(sx,sy)] { frontier.append((sx,sy)) }
                }
            }
        }
        for y in top..<bottom { for x in left..<right {
            let a = Double(maskValue(x,y)); guard a > 0 else { continue }
            let index = (y * width + x) * 4
            var replacement = Array(filtered[index..<index+4])
            if stroke.tool == .eraser { replacement = [0,0,0,0] }
            if stroke.tool == .solid { replacement = [UInt8(stroke.color.red*stroke.color.alpha*255), UInt8(stroke.color.green*stroke.color.alpha*255), UInt8(stroke.color.blue*stroke.color.alpha*255), UInt8(stroke.color.alpha*255)] }
            if stroke.tool == .clone {
                guard let source = stroke.source else { throw ImageFailure.renderFailed }
                let sx = Int((Double(x) + source.x - stroke.points[0].x).rounded()), sy = Int((Double(y) + source.y - stroke.points[0].y).rounded())
                guard sx>=0,sy>=0,sx<width,sy<height else { continue }
                replacement = Array(sourceBytes[(sy*width+sx)*4..<(sy*width+sx)*4+4])
            }
            for c in 0..<4 { destination[index+c] = UInt8(min(255,max(0,(Double(sourceBytes[index+c])*(1-a)+Double(replacement[c])*a).rounded()))) }
        } }
        guard let result=output.makeImage() else { throw ImageFailure.renderFailed }; return result
    }
}
