import Foundation
import CoreText
import CoreGraphics

@main struct FontChecks {
    static func pixels(_ text: TextLayer) -> [UInt8] {
        let c = CGContext(data: nil, width: 320, height: 160, bitsPerComponent: 8, bytesPerRow: 1280,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0, y: 160); c.scaleBy(x: 1, y: -1); c.translateBy(x: 160, y: 80)
        TextRenderer.draw(text, size: CGSize(width: 320, height: 160), in: c)
        return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: 320 * 160 * 4))
    }
    static func main() {
        let fonts = TextFontCatalog.fonts
        precondition((25...32).contains(fonts.count), "Too few usable common fonts")
        for entry in fonts {
            var text = TextLayer(); text.fontName = entry.postScriptName; text.fontSize = 30; text.content = "中文字体測試"
            let normal = pixels(text)
            precondition(normal.contains { $0 > 0 }, "Chinese did not render")
            text.bold = true
            let bold = pixels(text)
            precondition(normal != bold, "Bold had no effect on Chinese: " + entry.name)
            text.bold = false; text.italic = true
            let italic = pixels(text)
            precondition(normal != italic, "Italic had no effect on Chinese: " + entry.name)
            text.bold = true
            precondition(pixels(text) != italic && pixels(text) != bold, "Combined B/I did not render")
            let line = CTLineCreateWithAttributedString(text.attributedContent("Font 中文字体測試"))
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                precondition(!glyphs.contains(0), "Missing Chinese or Latin glyph")
            }
        }
        print("PASS · \(fonts.count) common fonts render Chinese/Latin with actual Bold, Italic and combined B/I")
    }
}
