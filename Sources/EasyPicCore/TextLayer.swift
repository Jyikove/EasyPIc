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
public struct TextLayer: Codable, Equatable {
    public static let defaultBackgroundCornerRadius: Double = 12
    public var content = "双击编辑文字"
    public var fontName = "PingFangSC-Regular"
    public var fontSize: Double = 48
    public var color = TextColor(1, 1, 1)
    public var bold = false
    public var italic = false
    public var strokeColor = TextColor(0, 0, 0)
    public var strokeWidth: Double = 0
    public var shadowColor = TextColor(0, 0, 0, 0.6)
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
    public init() {}
    public mutating func scale(by factor: Double) {
        fontSize *= factor; padding *= factor; strokeWidth *= factor
        shadowX *= factor; shadowY *= factor; shadowBlur *= factor
        cornerRadius *= factor; letterSpacing *= factor; lineSpacing *= factor
    }
    public var naturalSize: CGSize {
        let attributed = NSAttributedString(string: content.isEmpty ? " " : content, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTKernAttributeName as String): letterSpacing])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let proposed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: 100000, height: 100000), nil)
        let width = max(1, ceil(proposed.width + padding * 2 + strokeWidth * 2))
        let height = max(1, ceil(proposed.height + padding * 2 + strokeWidth * 2))
        return vertical ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
    public var font: CTFont {
        let base = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.boldTrait) }; if italic { traits.insert(.italicTrait) }
        return CTFontCreateCopyWithSymbolicTraits(base, fontSize, nil, traits, [.boldTrait, .italicTrait]) ?? base
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
    /// Context uses top-left image coordinates. Core Text owns shaping, fallback and vertical glyphs.
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
        var alignment: CTTextAlignment = text.alignment == .left ? .left : (text.alignment == .center ? .center : .right)
        var spacing = CGFloat(text.lineSpacing)
        let paragraph = withUnsafePointer(to: &alignment) { ap in
            withUnsafePointer(to: &spacing) { sp in
                let settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ap),
                                CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: sp)]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): text.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): text.color.cgColor,
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): text.strokeColor.cgColor,
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -text.strokeWidth / text.fontSize * 100,
            NSAttributedString.Key(kCTKernAttributeName as String): text.letterSpacing,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String): text.vertical
        ]
        let attributed = NSAttributedString(string: text.content, attributes: attrs)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: box.size), transform: nil)
        let frameAttrs = text.vertical ? [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary : nil
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, frameAttrs)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
