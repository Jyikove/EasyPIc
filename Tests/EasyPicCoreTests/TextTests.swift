import Foundation
import CoreGraphics
import CoreText
import EasyPicCore

struct TextTests {
    func render(_ style: TextLayer) throws -> CGImage {
        let size = CGSize(width: 360, height: 260)
        let id = UUID()
        let context = CGContext(data: nil, width: 360, height: 260, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var doc = EditorDocument(baseResourceID: id, size: size)
        var layer = StickerLayer(resourceID: UUID(), name: "文字", center: CGPoint(x: 180, y: 130), size: size)
        layer.text = style; doc.layers = [layer]
        return try DocumentEngine.render(doc, resources: [id: context.makeImage()!])
    }
    func bytes(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    func run() throws {
        var fitted = TextLayer(); fitted.content = "EasyPic"
        let short = fitted.naturalSize
        fitted.content = "EasyPic EasyPic"
        try expect(fitted.naturalSize.width > short.width)
        let before = fitted.naturalSize
        fitted.scale(by: 2)
        try expect(abs(fitted.naturalSize.width - before.width * 2) <= 2)
        try expect(abs(fitted.naturalSize.height - before.height * 2) <= 2)
        var text = TextLayer(); text.content = "你好，EasyPic！\n第二行 ABC"; text.fontSize = 36
        let horizontal = bytes(try render(text))
        try expect(horizontal.contains { $0 > 0 })
        text.vertical = true
        let vertical = bytes(try render(text))
        try expect(vertical.contains { $0 > 0 }); try expect(horizontal != vertical)
        // The actual vertical frame progresses columns right to left and uses vertical glyph shaping.
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): text.font, NSAttributedString.Key(kCTVerticalFormsAttributeName as String): true]
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text.content, attributes: attrs))
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: 360, height: 260), transform: nil), [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary)
        try expectEqual(CTFrameGetStringRange(frame).length, (text.content as NSString).length)
        print("PASS · 中英文多行文字、Core Text 竖排字形与列流")
        text.vertical = false; text.strokeWidth = 2; text.shadowX = 4; text.shadowY = 5; text.shadowBlur = 3
        text.backgroundColor = TextColor(0.2, 0.4, 0.8, 0.4); text.cornerRadius = 15; text.padding = 12
        try expect(bytes(try render(text)) != horizontal)
        text.alignment = .right; text.letterSpacing = 3; text.lineSpacing = 8
        let styled = try render(text)
        try expect(bytes(styled) != horizontal)
        text.fontName = "Helvetica"; text.bold = true; text.italic = true
        try expect(CTFontGetSymbolicTraits(text.font).contains([.boldTrait, .italicTrait]))
        print("PASS · 文字描边/阴影/透明背景、间距、对齐与真实粗斜体")
        let id = UUID(); var doc = EditorDocument(baseResourceID: id, size: CGSize(width: styled.width, height: styled.height))
        var layer = StickerLayer(resourceID: UUID(), name: "保存文字", center: CGPoint(x: 180, y: 130), size: doc.size); layer.text = text; doc.layers = [layer]
        let context = CGContext(data: nil, width: styled.width, height: styled.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let resources = [id: context.makeImage()!]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".easypic")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentEngine.save(doc, resources: resources, to: url)
        let (restored, assets) = try DocumentEngine.load(url)
        try expectEqual(doc, restored); try expectEqual(assets.count, 1)
        try expectEqual(bytes(try DocumentEngine.render(restored, resources: assets)), bytes(try DocumentEngine.render(doc, resources: resources)))
        var history = DocumentHistory(restored); var changed = restored; changed.layers[0].text?.content = "重新编辑"; history.apply(changed); history.undo(); try expectEqual(history.document, restored)
        print("PASS · 文字项目保存恢复、预览/导出一致与可继续编辑/撤销")
    }
}
