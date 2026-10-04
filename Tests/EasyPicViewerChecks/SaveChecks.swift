import Foundation
import CoreGraphics
import EasyPicCore

@MainActor
enum SaveChecks {
    private static func expect(_ value: Bool, _ message: String) throws { try ViewerModelChecks.expect(value, message) }
    private static func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    static func run(photo: URL) async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = root.appendingPathComponent("build/ViewerChecks/Save-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = folder.appendingPathComponent("Source.png")
        try FileManager.default.copyItem(at: photo, to: png)
        let original = try Data(contentsOf: png)
        let model = try await ViewerModelChecks.loaded(png)
        model.chooseEditorTool(.text); model.addText()
        try await ViewerModelChecks.wait { !model.busy && model.textEditing }
        var draft = model.selectedLayer!; draft.text?.content = "保存原图"; draft.size = draft.text!.naturalSize
        model.updateLayer(draft, commit: false)
        model.chooseEditorTool(.replaceOriginal)
        try await ViewerModelChecks.wait { !model.busy && !model.textEditing && !model.dirty }
        try expect(model.error == nil && model.activeEditorTool == nil, "替换原图失败或打开了二级窗口")
        let saved = try ImageEngine.load(png)
        let changed = try Data(contentsOf: png) != original
        try expect(saved.typeIdentifier == "public.png" && changed, "替换 PNG 没有保留格式或写入修改")
        let rendered = try DocumentEngine.render(model.document!, resources: model.resources)
        try expect(saved.image.width == rendered.width && saved.image.height == rendered.height, "保存原图没有使用完整像素尺寸")
        let difference = zip(pixels(saved.image), pixels(rendered)).map { abs(Int($0) - Int($1)) }.max() ?? 0
        try expect(difference <= 2, "保存原图合成像素不一致，最大差值：\(difference)")
        try expect(model.canUndo && model.document?.layers.count == 1, "保存丢失了当前编辑图层或历史")
        model.playback.clear()
        print("PASS · 一级保存按钮提交文字草稿、完整合成、同路径 PNG 替换与历史保留")

        let jpg = folder.appendingPathComponent("Source.jpg")
        try ImageEngine.encode(ImageEngine.load(photo).image, format: .jpg).write(to: jpg)
        let jpeg = try await ViewerModelChecks.loaded(jpg)
        jpeg.chooseEditorTool(.rotate); try await ViewerModelChecks.wait { !jpeg.busy }
        jpeg.chooseEditorTool(.replaceOriginal); try await ViewerModelChecks.wait { !jpeg.busy }
        let updated = try ImageEngine.load(jpg)
        try expect(jpeg.error == nil && !jpeg.dirty && updated.typeIdentifier == "public.jpeg" && updated.image.width == 360 && updated.image.height == 960, "替换 JPG 修改了格式或没有保存旋转")
        jpeg.chooseEditorTool(.undo); try await ViewerModelChecks.wait { !jpeg.busy }
        try expect(jpeg.dirty && jpeg.image?.width == 960, "替换后撤销没有成为新的未保存修改")
        jpeg.chooseEditorTool(.saveAs)
        try expect(jpeg.exportSheet && jpeg.activeEditorTool == nil, "另存为没有打开格式选择或展开了二级面板")
        jpeg.cancelExport(); jpeg.playback.clear()
        print("PASS · 同路径 JPG 保留格式、旋转保存、保存后撤销及另存为入口")

        let replacement = try ImageEngine.load(photo).image
        for fixture in ["Animated.gif", "Static.gif", "Animated.png", "Animated.webp", "Pages.tiff"] {
            let source = root.appendingPathComponent("Tests/EasyPicCoreTests/Fixtures/" + fixture)
            let target = folder.appendingPathComponent(fixture)
            try FileManager.default.copyItem(at: source, to: target)
            let before = try Data(contentsOf: target)
            var rejected = false
            do { try ImageEngine.replaceExisting(replacement, at: target) } catch { rejected = true }
            let after = try Data(contentsOf: target)
            try expect(rejected && before == after, "动图或多页原件未被保护：" + fixture)
        }
        let broken = folder.appendingPathComponent("Broken.png"), contents = Data("invalid image".utf8)
        try contents.write(to: broken)
        var rejected = false
        do { try ImageEngine.replaceExisting(replacement, at: broken) } catch { rejected = true }
        let unchanged = try Data(contentsOf: broken)
        try expect(rejected && unchanged == contents, "编码失败前破坏了原件")
        let readonly = try await ViewerModelChecks.loaded(folder.appendingPathComponent("Animated.gif"))
        try expect(!readonly.toolEnabled(.replaceOriginal) && !readonly.toolEnabled(.saveAs), "只读媒体启用了编辑保存")
        readonly.playback.clear()
        print("PASS · GIF/APNG/WebP、多页 TIFF 与无法解码原件拒绝替换且字节保持完整")
    }
}
