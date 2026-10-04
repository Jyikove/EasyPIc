import Foundation
import CoreGraphics
import EasyPicCore

struct DocumentTests {
    private func fixture(width: Int, height: Int, pixels: [UInt8]) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private func sample() -> (EditorDocument, [UUID: CGImage]) {
        let base = UUID(), sticker = UUID()
        var doc = EditorDocument(baseResourceID: base, size: CGSize(width: 8, height: 6))
        doc.layers = [StickerLayer(resourceID: sticker, name: "非对称透明贴纸", center: CGPoint(x: 3, y: 2), size: CGSize(width: 2, height: 2))]
        let colors: [UInt8] = [255,0,0,255, 0,255,0,255, 0,0,255,255, 0,0,0,0]
        return (doc, [base: fixture(width: 8, height: 6, pixels: Array(repeating: [UInt8(0),0,0,0], count: 48).flatMap { $0 }), sticker: fixture(width: 2, height: 2, pixels: colors)])
    }
    func testPlacementAndAlpha() throws {
        var (doc, resources) = sample()
        let result = pixels(try DocumentEngine.render(doc, resources: resources))
        func at(_ x: Int, _ y: Int) -> [UInt8] { Array(result[(y * 8 + x) * 4..<(y * 8 + x + 1) * 4]) }
        try expectEqual(at(2, 1), [255,0,0,255]); try expectEqual(at(3, 1), [0,255,0,255])
        try expectEqual(at(2, 2), [0,0,255,255]); try expectEqual(at(3, 2), [0,0,0,0])
        doc.layers[0].opacity = 0.5
        let half = pixels(try DocumentEngine.render(doc, resources: resources))
        try expect(abs(Int(half[(1 * 8 + 2) * 4 + 3]) - 128) <= 1)
        doc.layers[0].visible = false
        try expect(pixels(try DocumentEngine.render(doc, resources: resources)).allSatisfy { $0 == 0 })
    }
    func testTransforms() throws {
        let (doc, resources) = sample()
        let original = try DocumentEngine.render(doc, resources: resources)
        for operation in [EditOperation.clockwise, .counterclockwise, .mirrorHorizontal, .mirrorVertical, .crop(CGRect(x: 1, y: 1, width: 5, height: 4))] {
            var next = doc; try next.apply(operation)
            let result = try DocumentEngine.render(next, resources: resources)
            let expected = try ImageEngine.render(original, operations: [operation])
            try expectEqual(pixels(result), pixels(expected))
        }
        var outside = doc; outside.layers[0].center = CGPoint(x: 0, y: 0)
        let prior = try DocumentEngine.render(outside, resources: resources)
        try outside.apply(.crop(CGRect(x: 0, y: 0, width: 5, height: 4))); try outside.apply(.clockwise)
        try expectEqual(pixels(try DocumentEngine.render(outside, resources: resources)), pixels(try ImageEngine.render(prior, operations: [.crop(CGRect(x: 0, y: 0, width: 5, height: 4)), .clockwise])))
        try expectThrows { var invalid = doc; try invalid.apply(.crop(CGRect(x: -1, y: 0, width: 4, height: 4))) }
    }
    func testLayersAndHistory() throws {
        var (doc, resources) = sample()
        var duplicate = doc.layers[0]; duplicate.id = UUID(); duplicate.angle = 180
        doc.layers.append(duplicate)
        let top = try DocumentEngine.render(doc, resources: resources)
        doc.layers.reverse()
        try expect(pixels(top) != pixels(try DocumentEngine.render(doc, resources: resources)))
        var history = DocumentHistory(doc)
        var next = doc; next.layers[0].center.x += 2; history.apply(next)
        next.layers.removeLast(); history.apply(next)
        history.undo(); try expectEqual(history.document.layers.count, 2)
        history.undo(); try expectEqual(history.document, doc)
        history.redo(); try expectEqual(history.document.layers[0].center.x, doc.layers[0].center.x + 2)
        history.apply(doc); try expect(!history.canRedo)
    }
    func testProjectRoundTrip() throws {
        var (doc, resources) = sample(); doc.activeLayerID = doc.layers[0].id
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".easypic")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentEngine.save(doc, resources: resources, to: url)
        let (restored, assets) = try DocumentEngine.load(url)
        try expectEqual(restored, doc)
        try expectEqual(pixels(try DocumentEngine.render(restored, resources: assets)), pixels(try DocumentEngine.render(doc, resources: resources)))
        doc.layers[0].center.x += 2
        try DocumentEngine.save(doc, resources: resources, to: url)
        try expectEqual(try DocumentEngine.load(url).0, doc)
        let missing = url.appendingPathComponent(doc.layers[0].resourceID.uuidString + ".png")
        try FileManager.default.removeItem(at: missing)
        try expectThrows { _ = try DocumentEngine.load(url) }
    }
    func testPreviewAndExport() throws {
        var (doc, resources) = sample()
        doc.layers[0].size = CGSize(width: 4, height: 4)
        let full = try DocumentEngine.render(doc, resources: resources)
        let preview = try DocumentEngine.render(doc, resources: resources, maxDimension: 8)
        try expectEqual(pixels(full), pixels(preview))
        let smaller = try DocumentEngine.render(doc, resources: resources, maxDimension: 4)
        try expectEqual(smaller.width, 4); try expectEqual(smaller.height, 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageEngine.encode(full, format: .png).write(to: url)
        try expectEqual(pixels(try ImageEngine.load(url).image), pixels(full))
        let layer = doc.layers[0]
        for scale in [0.1, 0.5, 1.0, 2.0, 8.0] {
            let display = CGPoint(x: layer.center.x * scale, y: layer.center.y * scale)
            try expect(layer.contains(CGPoint(x: display.x / scale, y: display.y / scale)))
        }
    }
    func run() throws {
        try testPlacementAndAlpha(); print("PASS · 贴纸像素位置、方向、透明度和隐藏")
        try testTransforms(); print("PASS · 图层同步裁剪、整图旋转镜像和边界裁切")
        try testLayersAndHistory(); print("PASS · 层级合成、图层历史、撤销重做和历史分支")
        try testProjectRoundTrip(); print("PASS · 项目资源、保存重开、连续覆盖保存和缺失资源拒绝")
        try testPreviewAndExport(); print("PASS · 预览/PNG 导出一致、预览尺寸和多缩放选择坐标")
    }
}
