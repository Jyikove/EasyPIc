import Foundation
import CoreText

public struct CommonTextFont: Identifiable {
    public let name: String
    public let postScriptName: String
    public var id: String { postScriptName }
}

public enum TextFontCatalog {
    public static let fonts: [CommonTextFont] = {
        let available = Set(CTFontManagerCopyAvailablePostScriptNames() as! [String])
        let preferred = [
            ("PingFang SC", "PingFangSC-Regular"), ("Hiragino Sans GB", "HiraginoSansGB-W3"),
            ("Heiti SC", "STHeitiSC-Light"), ("Songti SC", "STSongti-SC-Regular"),
            ("Kaiti SC", "STKaitiSC-Regular"), ("STSong", "STSong"), ("STHeiti", "STHeiti"),
            ("Arial", "ArialMT"), ("Helvetica", "Helvetica"), ("Helvetica Neue", "HelveticaNeue"),
            ("Times New Roman", "TimesNewRomanPSMT"), ("Times", "Times-Roman"),
            ("Georgia", "Georgia"), ("Verdana", "Verdana"), ("Trebuchet MS", "TrebuchetMS"),
            ("Courier", "Courier"), ("Courier New", "CourierNewPSMT"), ("Menlo", "Menlo-Regular"),
            ("Avenir", "Avenir-Book"), ("Avenir Next", "AvenirNext-Regular"),
            ("Palatino", "Palatino-Roman"), ("Optima", "Optima-Regular"), ("Gill Sans", "GillSans"),
            ("Baskerville", "Baskerville"), ("Cochin", "Cochin"), ("Hoefler Text", "HoeflerText-Regular"),
            ("Charter", "Charter-Roman"), ("Seravek", "Seravek"), ("Iowan Old Style", "IowanOldStyle-Roman"),
            ("PT Sans", "PTSans-Regular"), ("PT Serif", "PTSerif-Regular"),
            ("Avenir Next Condensed", "AvenirNextCondensed-Regular")
        ]
        return preferred.compactMap { name, face in
            guard available.contains(face), supportsEditing(face) else { return nil }
            return CommonTextFont(name: name, postScriptName: face)
        }
    }()

    private static func supportsEditing(_ face: String) -> Bool {
        let regular = CTFontCreateWithName(face as CFString, 48, nil)
        guard CTFontGetSymbolicTraits(regular).intersection([.boldTrait, .italicTrait]).isEmpty else { return false }
        for (bold, italic) in [(false, false), (true, false), (false, true), (true, true)] {
            var text = TextLayer(); text.fontName = face; text.bold = bold; text.italic = italic
            let line = CTLineCreateWithAttributedString(text.attributedContent("Font 中文字体測試"))
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            guard !runs.isEmpty else { return false }
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                guard !glyphs.contains(0) else { return false }
            }
        }
        return true
    }
}
