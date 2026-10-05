import Foundation
import AppKit
import EasyPicCore

struct PanelWorkflowChecks {
    @MainActor static func run(photo: URL) async throws {
        let model = try await ViewerModelChecks.loaded(photo)
        model.chooseEditorTool(.text)
        try ViewerModelChecks.expect(model.textEditing && model.draftLayer?.text?.content == "" && !model.dirty && !model.canUndo,
                                     "Text 未直接打开空白编辑界面，或打开面板污染了历史")
        var text = model.selectedLayer!
        text.text?.content = "Direct editing"; text.size = text.text!.naturalSize
        model.updateLayer(text, commit: false)
        model.chooseEditorTool(.undo)
        try await ViewerModelChecks.wait { !model.busy }
        try ViewerModelChecks.expect(model.activeEditorTool == .text && model.textEditing && model.document?.layers.isEmpty == true && model.toolEnabled(.redo),
                                     "撤销文字后未保留编辑面板，或空草稿阻止重做")
        model.chooseEditorTool(.redo)
        try await ViewerModelChecks.wait { !model.busy }
        try ViewerModelChecks.expect(model.activeEditorTool == .text && model.textEditing && model.selectedLayer?.text?.content == "Direct editing",
                                     "重做文字未恢复内容及当前面板")
        model.chooseEditorTool(.crop); model.selectCropRatio(.square)
        model.chooseEditorTool(.undo); try await ViewerModelChecks.wait { !model.busy }
        try ViewerModelChecks.expect(model.cropping && model.activeEditorTool == .crop && model.cropRatio == .square && model.cropRect != nil,
                                     "撤销未保留裁剪面板、选区及比例")
        model.chooseEditorTool(.redo); try await ViewerModelChecks.wait { !model.busy }
        try ViewerModelChecks.expect(model.cropping && model.activeEditorTool == .crop && model.cropRatio == .square,
                                     "重做未保留裁剪面板")
        model.playback.clear()
        print("PASS · Text 直接编辑、空草稿无历史、文字/裁剪撤销重做保留面板")

        let merge = try await ViewerModelChecks.loaded(photo)
        merge.chooseEditorTool(.sticker)
        merge.importSticker(from: photo); try await ViewerModelChecks.wait { !merge.busy }
        merge.chooseEditorTool(.text)
        var draft = merge.selectedLayer!; draft.text?.content = "Merge draft"; draft.size = draft.text!.naturalSize
        merge.updateLayer(draft, commit: false)
        var expectedDoc = merge.document!; expectedDoc.layers.append(draft)
        let expected = try DocumentEngine.render(expectedDoc, resources: merge.resources)
        merge.mergeAllLayers(); try await ViewerModelChecks.wait { !merge.busy }
        try ViewerModelChecks.expect(merge.document?.layers.isEmpty == true && merge.textEditing && merge.activeEditorTool == .text,
                                     "一键合并未提交文字草稿或未合并所有图层")
        let actual = try DocumentEngine.render(merge.document!, resources: merge.resources)
        try ViewerModelChecks.expect(bytes(actual) == bytes(expected), "合并改变了合成图片的像素")
        merge.chooseEditorTool(.undo); try await ViewerModelChecks.wait { !merge.busy }
        try ViewerModelChecks.expect(merge.document?.layers.count == 2 && merge.textEditing, "撤销合并未恢复独立贴纸及文字")
        merge.playback.clear()
        print("PASS · 一键合并全部图层和未提交文字，像素一致，撤销恢复独立图层")

        for tool in [BrushTool.pixelate, .blur, .repair] {
            let brush = try await ViewerModelChecks.loaded(photo)
            let baseID = UUID(), stickerID = UUID()
            brush.resources[baseID] = solidImage()
            brush.resources[stickerID] = checkerImage()
            var doc = EditorDocument(baseResourceID: baseID, size: CGSize(width: 64, height: 64))
            doc.layers.append(StickerLayer(resourceID: stickerID, name: "Sticker", center: CGPoint(x: 18, y: 32), size: CGSize(width: 24, height: 24)))
            var lettering = TextLayer(); lettering.content = "M"; lettering.fontSize = 18; lettering.padding = 0; lettering.color = TextColor(0, 0, 0)
            var layer = StickerLayer(resourceID: UUID(), name: "Text", center: CGPoint(x: 48, y: 32), size: lettering.naturalSize)
            layer.text = lettering; doc.layers.append(layer)
            brush.commitDocument(doc); try await ViewerModelChecks.wait { !brush.busy }
            let before = bytes(try DocumentEngine.render(doc, resources: brush.resources))
            brush.chooseEditorTool(tool == .repair ? .repair : .mosaic)
            brush.brushTool = tool; brush.brushSize = 40; brush.brushHardness = 1; brush.brushOpacity = 1; brush.brushStrength = 12
            brush.commitBrush([CGPoint(x: 18, y: 32), CGPoint(x: 48, y: 32)])
            try await ViewerModelChecks.wait { !brush.busy }
            try ViewerModelChecks.expect(brush.error == nil && brush.document?.layers.isEmpty == true, "笔刷未处理合成图层")
            let after = bytes(try DocumentEngine.render(brush.document!, resources: brush.resources))
            func changed(_ range: Range<Int>) -> Bool {
                (24..<40).contains { y in range.contains { x in
                    let i = (y * 64 + x) * 4
                    return before[i..<i+3] != after[i..<i+3]
                } }
            }
            try ViewerModelChecks.expect(changed(10..<26) && changed(42..<54), "笔刷未改变已有贴纸或文字像素")
            try ViewerModelChecks.expect(before[0..<4] == after[0..<4], "笔刷改变了未选中的区域")
            brush.chooseEditorTool(.undo); try await ViewerModelChecks.wait { !brush.busy }
            try ViewerModelChecks.expect(brush.document?.layers.count == 2 && brush.brushMode && bytes(try DocumentEngine.render(brush.document!, resources: brush.resources)) == before,
                                         "撤销笔刷未恢复独立图层、像素或当前面板")
            brush.chooseEditorTool(.redo); try await ViewerModelChecks.wait { !brush.busy }
            try ViewerModelChecks.expect(brush.brushMode && bytes(try DocumentEngine.render(brush.document!, resources: brush.resources)) == after,
                                         "重做笔刷未恢复合成效果或当前面板")
            brush.playback.clear()
        }
        print("PASS · Pixel/Gaussian/Erase 处理已有贴纸和文字，选区外不变，撤销重做保留画笔")
    }
    static func bytes(_ image: CGImage) -> [UInt8] {
        let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    static func solidImage() -> CGImage {
        bitmap(Array(repeating: [UInt8(180), 180, 180, 255], count: 64 * 64).flatMap { $0 }, size: 64)
    }
    static func checkerImage() -> CGImage {
        bitmap((0..<24).flatMap { y in (0..<24).flatMap { x -> [UInt8] in
            let v: UInt8 = (x / 2 + y / 2) % 2 == 0 ? 0 : 255
            return [v, v, v, 255]
        } }, size: 24)
    }
    static func bitmap(_ pixels: [UInt8], size: Int) -> CGImage {
        CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
