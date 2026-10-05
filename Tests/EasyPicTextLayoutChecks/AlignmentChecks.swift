import Foundation
import CoreGraphics

@main
struct AlignmentChecks {
    static func bounds(_ text: TextLayer) -> CGRect {
        let width = 360, height = 260
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        TextRenderer.draw(text, size: CGSize(width: width, height: height), in: context)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        var result = CGRect.null
        for y in 0..<height {
            for x in 0..<width where data[(y * width + x) * 4 + 3] > 32 {
                result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return result
    }
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
    static func main() throws {
        var text = TextLayer()
        text.content = "EasyPic"; text.fontName = "Helvetica"; text.fontSize = 24; text.padding = 8
        for vertical in [false, true] {
            text.vertical = vertical; text.verticalAlignment = .top
            let horizontal = TextAlignment.allCases.map { alignment -> CGRect in
                text.alignment = alignment
                return bounds(text)
            }
            text.alignment = .left
            let positions = TextVerticalAlignment.allCases.map { alignment -> CGRect in
                text.verticalAlignment = alignment
                return bounds(text)
            }
            require((horizontal + positions).allSatisfy { !$0.isNull }, "Alignment hid the text")
            require(horizontal[0].midX < horizontal[1].midX && horizontal[1].midX < horizontal[2].midX,
                    "Horizontal alignment did not move text left / center / right")
            require(positions[0].midY < positions[1].midY && positions[1].midY < positions[2].midY,
                    "Vertical alignment did not move text top / center / bottom")
            require(horizontal.map(\.width).max()! - horizontal.map(\.width).min()! <= 2 &&
                    positions.map(\.height).max()! - positions.map(\.height).min()! <= 2,
                    "Alignment clipped the glyphs")
            print("PASS · Six alignment positions, \(vertical ? "vertical" : "horizontal") text")
        }
        var upright = TextLayer(); upright.content = "F"; upright.fontName = "Helvetica"; upright.fontSize = 32
        let normal = bounds(upright)
        upright.vertical = true
        let stacked = bounds(upright)
        require(abs(normal.width - stacked.width) <= 2 && abs(normal.height - stacked.height) <= 2,
                "Vertical Latin glyphs were rotated instead of kept upright")
        upright.content = "A中B🙂"
        require(upright.naturalSize.height > upright.naturalSize.width * 2, "Characters were not stacked vertically")
        upright.content = "e\u{301}"
        let combined = upright.naturalSize
        upright.content = "e"
        require(abs(combined.height - upright.naturalSize.height) < 8, "Combining marks were split into another row")
        print("PASS · Upright Latin/CJK/emoji rows and intact grapheme clusters")
        let data = try JSONEncoder().encode(text)
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "verticalAlignment")
        let restored = try JSONDecoder().decode(TextLayer.self, from: JSONSerialization.data(withJSONObject: legacy))
        require(restored.resolvedVerticalAlignment == .top, "Legacy project did not default to top alignment")
        require(try JSONDecoder().decode(TextLayer.self, from: data) == text, "Alignment was not preserved")
        print("PASS · Old text projects and new alignment persistence")
    }
}
