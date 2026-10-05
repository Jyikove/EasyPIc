import AppKit
import ImageIO
import UniformTypeIdentifiers

// User-approved local silhouette extraction; no interior repainting or color keying.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Cannot read icon") }
let width = image.width, height = image.height
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.current = context
let cg = context.cgContext
cg.setAllowsAntialiasing(true); cg.setShouldAntialias(true)
// Coordinates traced along the supplied 1254 px tile. Top-left origin converted here.
let sx = CGFloat(width) / 1254, sy = CGFloat(height) / 1254
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: (1254 - y) * sy) }
let outline = CGMutablePath()
outline.move(to: point(400, 52))
outline.addCurve(to: point(852, 52), control1: point(530, 49), control2: point(724, 49))
outline.addCurve(to: point(1192, 365), control1: point(1086, 52), control2: point(1192, 153))
outline.addLine(to: point(1192, 850))
outline.addCurve(to: point(852, 1164), control1: point(1192, 1066), control2: point(1082, 1164))
outline.addCurve(to: point(400, 1164), control1: point(718, 1167), control2: point(534, 1167))
outline.addCurve(to: point(62, 850), control1: point(169, 1164), control2: point(62, 1065))
outline.addLine(to: point(62, 365))
outline.addCurve(to: point(400, 52), control1: point(62, 161), control2: point(167, 52))
outline.closeSubpath()
cg.addPath(outline); cg.clip()
cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print(output.path)
