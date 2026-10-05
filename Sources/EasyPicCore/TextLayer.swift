import Foundation
import CoreText
import CoreGraphics

public struct TextColor: Codable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public var cgColor: CGColor { CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])! }
}
public enum TextAlignment: String, Codable, CaseIterable { case left, center, right }
public enum TextVerticalAlignment: String, Codable, CaseIterable { case top, center, bottom }
public struct TextLayer: Codable, Equatable {
    public static let defaultBackgroundCornerRadius: Double = 0
    public var content = L10n.text("双击编辑文字")
    public var fontName = "PingFangSC-Regular"
    public var fontSize: Double = 48
    public var color = TextColor(1, 1, 1)
    public var bold = false
    public var italic = false
    public var strokeColor = TextColor(0, 0, 0, 0)
    public var strokeWidth: Double = 0
    public var shadowColor = TextColor(0, 0, 0, 0)
    public var shadowX: Double = 0
    public var shadowY: Double = 0
    public var shadowBlur: Double = 0
    public var backgroundColor = TextColor(0, 0, 0, 0)
    public var padding: Double = 8
    public var cornerRadius: Double = Self.defaultBackgroundCornerRadius
    public var letterSpacing: Double = 0
    public var lineSpacing: Double = 0
    public var vertical = false
    public var alignment: TextAlignment = .left
    // Optional storage preserves projects saved before vertical alignment was available.
    public var verticalAlignment: TextVerticalAlignment?
    public var resolvedVerticalAlignment: TextVerticalAlignment { verticalAlignment ?? .top }
    public init() {}
    public mutating func scale(by factor: Double) {
        fontSize *= factor; padding *= factor; strokeWidth *= factor
        shadowX *= factor; shadowY *= factor; shadowBlur *= factor
        cornerRadius *= factor; letterSpacing *= factor; lineSpacing *= factor
    }
    public var naturalSize: CGSize {
        if vertical {
            let measured = VerticalTextLayout(self).size
            let inset = padding * 2 + strokeWidth * 2
            return CGSize(width: max(1, ceil(measured.width + inset)), height: max(1, ceil(measured.height + inset)))
        }
        let attributed = attributedContent(content.isEmpty ? " " : content)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let proposed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: 100000, height: 100000), nil)
        let width = max(1, ceil(proposed.width + padding * 2 + strokeWidth * 2))
        let height = max(1, ceil(proposed.height + padding * 2 + strokeWidth * 2))
        return CGSize(width: width, height: height)
    }
    public var font: CTFont {
        styledFont(CTFontCreateWithName(fontName as CFString, fontSize, nil))
    }
    private func styledFont(_ base: CTFont) -> CTFont {
        var result = base
        if bold, let copy = CTFontCreateCopyWithSymbolicTraits(result, fontSize, nil, .boldTrait, .boldTrait) { result = copy }
        if italic, let copy = CTFontCreateCopyWithSymbolicTraits(result, fontSize, nil, .italicTrait, .italicTrait) { result = copy }
        return result
    }
    // Font fallback and style synthesis also apply to Chinese runs in Latin families.
    func attributedContent(_ string: String, paragraph: CTParagraphStyle? = nil, spacing: Bool = true) -> NSAttributedString {
        let result = NSMutableAttributedString(string: string)
        let base = font
        var location = 0
        for character in string {
            let value = String(character), length = value.utf16.count
            var face = styledFont(CTFontCreateForString(base, value as CFString, CFRange(location: 0, length: length)))
            let traits = CTFontGetSymbolicTraits(face)
            if italic && !traits.contains(.italicTrait) {
                var matrix = CGAffineTransform(a: 1, b: 0, c: 0.22, d: 1, tx: 0, ty: 0)
                face = CTFontCreateCopyWithAttributes(face, fontSize, &matrix, nil)
            }
            let syntheticBold = bold && !traits.contains(.boldTrait) ? fontSize * 0.025 : 0
            var attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): face,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): (strokeWidth > 0 ? strokeColor : color).cgColor,
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -(strokeWidth + syntheticBold) / fontSize * 100
            ]
            if spacing { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = letterSpacing }
            if let paragraph { attrs[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = paragraph }
            result.addAttributes(attrs, range: NSRange(location: location, length: length))
            location += length
        }
        return result
    }
    public var unavailableTraits: Bool {
        let actual = CTFontGetSymbolicTraits(font)
        return (bold && !actual.contains(.boldTrait)) || (italic && !actual.contains(.italicTrait))
    }
    public var isValid: Bool {
        let numbers = [fontSize, strokeWidth, shadowX, shadowY, shadowBlur, padding, cornerRadius, letterSpacing, lineSpacing]
        let colors = [color, strokeColor, shadowColor, backgroundColor]
        return numbers.allSatisfy(\.isFinite) && fontSize >= 1 && fontSize <= 4096 && strokeWidth >= 0 && shadowBlur >= 0 && padding >= 0 && cornerRadius >= 0 && lineSpacing >= 0 && colors.allSatisfy { c in [c.red, c.green, c.blue, c.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    }
}

public enum TextRenderer {
    /// Context uses top-left image coordinates. Vertical text stacks upright grapheme clusters.
    public static func draw(_ text: TextLayer, size: CGSize, in context: CGContext) {
        let bounds = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        context.saveGState(); context.clip(to: bounds)
        context.setFillColor(text.backgroundColor.cgColor)
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: text.cornerRadius, cornerHeight: text.cornerRadius, transform: nil)); context.fillPath()
        let pad = min(text.padding, max(0, min(size.width, size.height) / 2 - 0.5))
        let box = bounds.insetBy(dx: pad, dy: pad)
        context.translateBy(x: box.minX, y: box.maxY); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        if text.shadowBlur > 0 || text.shadowX != 0 || text.shadowY != 0 {
            context.setShadow(offset: CGSize(width: text.shadowX, height: -text.shadowY), blur: text.shadowBlur, color: text.shadowColor.cgColor)
        }
        if text.vertical {
            VerticalTextLayout(text).draw(text, size: box.size, in: context)
            context.restoreGState()
            return
        }
        var alignment: CTTextAlignment = text.alignment == .left ? .left : (text.alignment == .center ? .center : .right)
        var spacing = CGFloat(text.lineSpacing)
        let paragraph = withUnsafePointer(to: &alignment) { ap in
            withUnsafePointer(to: &spacing) { sp in
                let settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ap),
                                CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: sp)]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let attributed = text.attributedContent(text.content, paragraph: paragraph)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: box.size), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        if !lines.isEmpty {
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            var minimum = CGFloat.greatestFiniteMagnitude
            var maximum = -CGFloat.greatestFiniteMagnitude
            for (index, line) in lines.enumerated() {
                var ascent: CGFloat = 0, descent: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                let position = origins[index].y
                minimum = min(minimum, position - descent)
                maximum = max(maximum, position + ascent)
            }
            let extent = maximum - minimum
            if text.resolvedVerticalAlignment != .top {
                let free = max(0, box.height - extent)
                context.translateBy(x: 0, y: text.resolvedVerticalAlignment == .center ? -free / 2 : -free)
            }
        }
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

/// Shape one extended grapheme at a time, keeping Latin, CJK and emoji upright.
/// Newlines start a new column to the left; spacing and measurements share this layout.
private struct VerticalTextLayout {
    struct Glyph {
        let line: CTLine
        let bounds: CGRect
        let ascent: CGFloat
        let descent: CGFloat
    }
    let columns: [[Glyph]]
    let widths: [CGFloat]
    let cellHeight: CGFloat
    let advance: CGFloat
    let columnGap: CGFloat
    var size: CGSize {
        CGSize(width: widths.reduce(0, +) + columnGap * CGFloat(max(0, columns.count - 1)),
               height: columns.map { cellHeight + advance * CGFloat(max(0, $0.count - 1)) }.max() ?? cellHeight)
    }
    init(_ text: TextLayer) {
        let content = text.content.replacingOccurrences(of: "\r\n", with: "\n")
        columns = content.components(separatedBy: .newlines).map { column in
            (column.isEmpty ? " " : column).map { character in
                let line = CTLineCreateWithAttributedString(text.attributedContent(String(character), spacing: false))
                var ascent: CGFloat = 0, descent: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                return Glyph(line: line, bounds: CTLineGetBoundsWithOptions(line, .useGlyphPathBounds), ascent: ascent, descent: descent)
            }
        }
        widths = columns.map { column in max(CGFloat(text.fontSize), column.map { $0.bounds.width }.max() ?? 0) }
        cellHeight = ceil(max(CGFloat(text.fontSize), columns.flatMap { $0 }.map { $0.ascent + $0.descent }.max() ?? 0))
        advance = max(1, cellHeight + CGFloat(text.letterSpacing))
        columnGap = CGFloat(text.lineSpacing)
    }
    func draw(_ text: TextLayer, size box: CGSize, in context: CGContext) {
        let freeX = max(0, box.width - size.width)
        let left = text.alignment == .left ? 0 : (text.alignment == .center ? freeX / 2 : freeX)
        var right = left + size.width
        for (index, column) in columns.enumerated() {
            let width = widths[index]
            let height = cellHeight + advance * CGFloat(max(0, column.count - 1))
            let freeY = max(0, box.height - height)
            let top = text.resolvedVerticalAlignment == .top ? 0 : (text.resolvedVerticalAlignment == .center ? freeY / 2 : freeY)
            for (row, glyph) in column.enumerated() {
                let centerY = box.height - top - CGFloat(row) * advance - cellHeight / 2
                context.textPosition = CGPoint(x: right - width / 2 - glyph.bounds.midX,
                                               y: centerY - (glyph.ascent - glyph.descent) / 2)
                CTLineDraw(glyph.line, context)
            }
            right -= width + columnGap
        }
    }
}
