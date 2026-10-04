import Foundation
import CoreGraphics
import EasyPicCore

struct LayerMergeTests {
    private func image(width: Int, height: Int, color: [UInt8]) -> CGImage {
        let data = Data(Array(repeating: color, count: width * height).flatMap { $0 })
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    private func expectSameAppearance(_ a: CGImage, _ b: CGImage) throws {
        try expectEqual(a.width, b.width); try expectEqual(a.height, b.height)
        // An extra 8-bit alpha composition can round a channel by one unit.
        let delta = zip(pixels(a), pixels(b)).map { abs(Int($0) - Int($1)) }.max() ?? 0
        try expect(delta <= 2)
    }
    private func fixture() -> (EditorDocument, [UUID: CGImage]) {
        let base = UUID(), picture = UUID()
        var doc = EditorDocument(baseResourceID: base, size: CGSize(width: 80, height: 60))
        var lower = StickerLayer(resourceID: picture, name: "半透明贴纸", center: CGPoint(x: 25, y: 24), size: CGSize(width: 24, height: 20))
        lower.opacity = 0.65; lower.angle = 27; lower.mirrored = true
        lower.strokes = [BrushStroke(tool: .solid, points: [CGPoint(x: 2, y: 2)], diameter: 2, color: TextColor(0, 1, 0))]
        var upper = StickerLayer(resourceID: UUID(), name: "文字", center: CGPoint(x: 34, y: 24), size: CGSize(width: 50, height: 26))
        var text = TextLayer(); text.content = "合并 A"; text.fontSize = 13; text.padding = 4
        text.backgroundColor = TextColor(0.1, 0.4, 0.9, 0.4)
        upper.text = text; upper.opacity = 0.75; upper.angle = -12
        upper.clips = [[CGPoint(x: 15, y: 4), CGPoint(x: 68, y: 4), CGPoint(x: 68, y: 45), CGPoint(x: 15, y: 45)]]
        var hidden = lower; hidden.id = UUID(); hidden.name = "隐藏图层"; hidden.visible = false
        doc.layers = [lower, upper, hidden]
        return (doc, [base: image(width: 80, height: 60, color: [25, 50, 80, 180]),
                      picture: image(width: 4, height: 4, color: [240, 20, 40, 210])])
    }
    func testDownMerge() throws {
        var (doc, assets) = fixture()
        // Other visible layers above and below must keep their order and appearance.
        var below = doc.layers[0]; below.id = UUID(); below.center = CGPoint(x: 16, y: 40)
        var above = below; above.id = UUID(); above.center = CGPoint(x: 50, y: 20)
        doc.layers.insert(below, at: 0); doc.layers.append(above)
        let before = try DocumentEngine.render(doc, resources: assets)
        let result = try DocumentEngine.merge(doc, resources: assets, mode: .down(doc.layers[2].id))
        assets[result.resourceID] = result.image
        try expectEqual(result.document.layers.count, 4)
        try expectEqual(result.document.layers.first, below); try expectEqual(result.document.layers.last, above)
        try expect(result.document.layers[1].text == nil && result.document.layers[1].opacity == 1)
        try expect(result.image.width < Int(doc.size.width))
        let mergedPixels = pixels(result.image)
        let alpha = stride(from: 3, to: mergedPixels.count, by: 4).map { mergedPixels[$0] }
        try expect(alpha.contains(0)); try expect(alpha.contains { $0 > 0 && $0 < 255 })
        try expectSameAppearance(before, DocumentEngine.render(result.document, resources: assets))
        var history = DocumentHistory(doc); history.apply(result.document); history.undo()
        try expectEqual(history.document, doc); history.redo(); try expectEqual(history.document, result.document)
        try expectSameAppearance(before, DocumentEngine.render(history.document, resources: assets))
    }
    func testVisibleMergeAndPersistence() throws {
        var (doc, assets) = fixture()
        let hidden = doc.layers.removeLast(); doc.layers.insert(hidden, at: 1)
        let before = try DocumentEngine.render(doc, resources: assets)
        let merged = try DocumentEngine.merge(doc, resources: assets, mode: .visible)
        assets[merged.resourceID] = merged.image
        try expectEqual(merged.document.baseResourceID, doc.baseResourceID)
        try expectEqual(merged.document.layers.count, 2); try expectEqual(merged.document.layers[0], hidden)
        try expectEqual(merged.document.activeLayerID, merged.document.layers[1].id)
        try expectSameAppearance(before, DocumentEngine.render(merged.document, resources: assets))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".easypic")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentEngine.save(merged.document, resources: assets, to: url)
        let (restored, resources) = try DocumentEngine.load(url)
        try expectEqual(restored, merged.document)
        try expectSameAppearance(before, DocumentEngine.render(restored, resources: resources))
        var moved = restored; moved.layers[1].center.x += 12
        try expect(pixels(try DocumentEngine.render(moved, resources: resources)) != pixels(before))
        try expectThrows { _ = try DocumentEngine.merge(doc, resources: assets, mode: .down(hidden.id)) }
        try expectThrows { _ = try DocumentEngine.merge(doc, resources: assets, mode: .down(doc.layers[2].id)) }
        var empty = doc; empty.layers = []
        try expectThrows { _ = try DocumentEngine.merge(empty, resources: assets, mode: .visible) }
    }
    func testMergeIntoEditedBase() throws {
        var (doc, assets) = fixture()
        doc.baseStrokes = [BrushStroke(tool: .solid, points: [CGPoint(x: 5, y: 5)], diameter: 10, color: TextColor(0, 1, 1))]
        try doc.apply(.crop(CGRect(x: 5, y: 4, width: 65, height: 50)))
        try doc.apply(.clockwise)
        let before = try DocumentEngine.render(doc, resources: assets)
        let result = try DocumentEngine.merge(doc, resources: assets, mode: .down(doc.layers[0].id))
        assets[result.resourceID] = result.image
        try expectEqual(result.document.size, doc.size)
        try expect(result.document.operations.isEmpty && result.document.baseStrokes == nil)
        try expectEqual(result.document.layers, Array(doc.layers.dropFirst()))
        try expectSameAppearance(before, DocumentEngine.render(result.document, resources: assets))
        var rotated = result.document; try rotated.apply(.counterclockwise)
        try expectSameAppearance(ImageEngine.render(before, operations: [.counterclockwise]), DocumentEngine.render(rotated, resources: assets))
        var history = DocumentHistory(doc); history.apply(result.document); history.undo()
        try expectSameAppearance(before, DocumentEngine.render(history.document, resources: assets))
    }
    func run() throws {
        try testDownMerge(); print("PASS · 向下合并保留文字/贴纸/笔画/透明度/裁切像素、层级和撤销重做")
        try testVisibleMergeAndPersistence(); print("PASS · 合并可见图层保留隐藏层与原图、保存重开、移动和无效合并拒绝")
        try testMergeIntoEditedBase(); print("PASS · 合并到已裁剪旋转的原图保留画笔与剩余图层，后续变换与撤销正确")
    }
}
