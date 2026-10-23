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
    public var content = L10n.text("编辑文字")
    /// Only new, untouched template text is disposable; literal user text is preserved.
    public var placeholderContent: String? = nil
    public var isUnfinished: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || placeholderContent == content
    }
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
    public var layoutKey: String {
        var geometry = self
        geometry.placeholderContent = nil
        geometry.color = TextColor(0, 0, 0); geometry.strokeColor = TextColor(0, 0, 0)
        geometry.shadowColor = TextColor(0, 0, 0); geometry.backgroundColor = TextColor(0, 0, 0)
        geometry.shadowX = 0; geometry.shadowY = 0; geometry.shadowBlur = 0; geometry.cornerRadius = 0
        geometry.alignment = .left; geometry.verticalAlignment = nil
        return RenderCache.key(geometry)
    }
    public var naturalSize: CGSize { TextLayoutCache.size(self) }
    fileprivate var measuredSize: CGSize {
        if vertical {
            let measured = TextLayoutCache.vertical(self).size
            let inset = padding * 2 + strokeWidth * 2
            return CGSize(width: max(1, ceil(measured.width + inset)), height: max(1, ceil(measured.height + inset)))
        }
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let attributed = attributedContent(normalized.isEmpty ? " " : normalized)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let proposed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: attributed.length), nil, CGSize(width: 100000, height: 100000), nil)
        // Framesetter fitting can trim trailing whitespace. Keep the complete
        // advance of each explicit line so spaces enlarge the layer as typed.
        let logicalWidth = normalized.components(separatedBy: "\n").reduce(CGFloat.zero) { width, string in
            let line = CTLineCreateWithAttributedString(attributedContent(string))
            return max(width, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        let width = max(1, ceil(max(proposed.width, logicalWidth) + padding * 2 + strokeWidth * 2))
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
        let key = RenderCache.key(self) + ":\(spacing):\(paragraph != nil):" + string
        if let cached = TextLayoutCache.attributed.object(forKey: key as NSString) { return cached }
        let result = NSMutableAttributedString(string: string)
        let base = TextLayoutCache.font(key: "base:\(fontName):\(fontSize):\(bold):\(italic)") { font }
        var location = 0
        for character in string {
            let value = String(character), length = value.utf16.count
            var face = TextLayoutCache.font(key: "fallback:\(fontName):\(fontSize):\(bold):\(italic):" + value) {
                styledFont(CTFontCreateForString(base, value as CFString, CFRange(location: 0, length: length)))
            }
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
        let immutable = NSAttributedString(attributedString: result)
        TextLayoutCache.attributed.setObject(immutable, forKey: key as NSString, cost: max(256, string.utf16.count * 128))
        return immutable
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
            TextLayoutCache.vertical(text).draw(text, size: box.size, in: context)
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
        let normalized = text.content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let attributed = text.attributedContent(normalized.isEmpty ? " " : normalized, paragraph: paragraph)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: box.size), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: attributed.length), path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        if !lines.isEmpty {
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            for (index, line) in lines.enumerated() {
                let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let free = max(0, box.width - advance)
                origins[index].x = text.alignment == .left ? 0 : (text.alignment == .center ? free / 2 : free)
            }
            // Font ascent/descent includes invisible space. Center the visible
            // glyph block instead, retaining paragraph alignment between lines.
            let offset = TextLayoutCache.centeringOffset(text, size: box.size) {
                lines.enumerated().reduce(CGRect.null) { bounds, item in
                    let ink = occupiedBounds(item.element, content: attributed.string as NSString)
                    guard !ink.isNull, !ink.isEmpty else { return bounds }
                    return bounds.union(ink.offsetBy(dx: origins[item.offset].x, dy: origins[item.offset].y))
                }
            }
            context.translateBy(x: offset.x, y: offset.y)
            for (index, line) in lines.enumerated() {
                context.textPosition = origins[index]; CTLineDraw(line, context)
            }
        }
        context.restoreGState()
    }

    private static func occupiedBounds(_ line: CTLine, content: NSString) -> CGRect {
        var ink = CTLineGetImageBounds(line, nil)
        let trailing = CTLineGetTrailingWhitespaceWidth(line)
        let range = CTLineGetStringRange(line)
        let leading = range.location < content.length &&
            content.substring(with: NSRange(location: range.location, length: min(range.length, content.length - range.location))).first?.isWhitespace == true
        guard leading || trailing > 0 else { return ink }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        if ink.isNull || ink.isEmpty {
            return advance > 0 ? CGRect(x: 0, y: -descent, width: advance, height: ascent + descent) : .null
        }
        let left = leading ? min(0, ink.minX) : ink.minX
        let right = trailing > 0 ? max(advance, ink.maxX) : ink.maxX
        ink.origin.x = left; ink.size.width = right - left
        return ink
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
        var placements: [(Glyph, CGPoint)] = []
        for (index, column) in columns.enumerated() {
            let width = widths[index]
            let height = cellHeight + advance * CGFloat(max(0, column.count - 1))
            let freeY = max(0, box.height - height)
            let top = text.resolvedVerticalAlignment == .top ? 0 : (text.resolvedVerticalAlignment == .center ? freeY / 2 : freeY)
            for (row, glyph) in column.enumerated() {
                let centerY = box.height - top - CGFloat(row) * advance - cellHeight / 2
                placements.append((glyph, CGPoint(x: right - width / 2 - glyph.bounds.midX,
                                                 y: centerY - (glyph.ascent - glyph.descent) / 2)))
            }
            right -= width + columnGap
        }
        let offset = TextLayoutCache.centeringOffset(text, size: box) {
            placements.reduce(CGRect.null) { bounds, item in
                let ink = CTLineGetImageBounds(item.0.line, nil)
                guard !ink.isNull, !ink.isEmpty else { return bounds }
                return bounds.union(ink.offsetBy(dx: item.1.x, dy: item.1.y))
            }
        }
        context.saveGState(); context.translateBy(x: offset.x, y: offset.y)
        for (glyph, point) in placements {
            context.textPosition = point; CTLineDraw(glyph.line, context)
        }
        context.restoreGState()
    }
}

/// Core Text objects are immutable and shared by measuring and drawing. Each cache is bounded.
private enum TextLayoutCache {
    final class OffsetBox { let point: CGPoint; init(_ point: CGPoint) { self.point = point } }
    final class SizeBox { let size: CGSize; init(_ size: CGSize) { self.size = size } }
    final class FontBox { let font: CTFont; init(_ font: CTFont) { self.font = font } }
    final class VerticalBox { let layout: VerticalTextLayout; init(_ layout: VerticalTextLayout) { self.layout = layout } }
    static let sizes: NSCache<NSString, SizeBox> = { let c = NSCache<NSString, SizeBox>(); c.countLimit = 256; return c }()
    static let offsets: NSCache<NSString, OffsetBox> = { let c = NSCache<NSString, OffsetBox>(); c.countLimit = 256; return c }()
    static func centeringOffset(_ text: TextLayer, size: CGSize, bounds: () -> CGRect) -> CGPoint {
        let key = "\(text.layoutKey):\(text.alignment):\(text.resolvedVerticalAlignment):\(size.width):\(size.height)" as NSString
        if let cached = offsets.object(forKey: key) { return cached.point }
        let ink = bounds()
        let point = ink.isNull || ink.isEmpty ? CGPoint.zero : CGPoint(x: size.width / 2 - ink.midX, y: size.height / 2 - ink.midY)
        offsets.setObject(OffsetBox(point), forKey: key)
        return point
    }
    static let fonts: NSCache<NSString, FontBox> = { let c = NSCache<NSString, FontBox>(); c.countLimit = 2048; return c }()
    static let attributed: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>(); c.totalCostLimit = 8 * 1024 * 1024; c.countLimit = 256; return c
    }()
    static let verticals: NSCache<NSString, VerticalBox> = {
        let c = NSCache<NSString, VerticalBox>(); c.totalCostLimit = 8 * 1024 * 1024; c.countLimit = 128; return c
    }()
    static func size(_ text: TextLayer) -> CGSize {
        let key = text.layoutKey as NSString
        if let cached = sizes.object(forKey: key) { return cached.size }
        let size = text.measuredSize
        sizes.setObject(SizeBox(size), forKey: key)
        return size
    }
    static func font(key: String, create: () -> CTFont) -> CTFont {
        if let box = fonts.object(forKey: key as NSString) { return box.font }
        let font = create(); fonts.setObject(FontBox(font), forKey: key as NSString); return font
    }
    static func vertical(_ text: TextLayer) -> VerticalTextLayout {
        let key = RenderCache.key(text) as NSString
        if let box = verticals.object(forKey: key) { return box.layout }
        let layout = VerticalTextLayout(text)
        verticals.setObject(VerticalBox(layout), forKey: key, cost: max(256, text.content.utf16.count * 256))
        return layout
    }
}
