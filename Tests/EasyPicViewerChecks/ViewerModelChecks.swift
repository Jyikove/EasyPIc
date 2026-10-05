import Foundation
import AppKit
import EasyPicCore

@main
struct ViewerModelChecks {
    @MainActor static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "EasyPic.ViewerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            try expect(Date() < deadline, "等待查看器操作超时")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor static func loaded(_ url: URL) async throws -> EditorModel {
        let model = EditorModel(); model.open(url, viewingOnly: true)
        try await wait { !model.busy && model.image != nil }
        try expect(model.error == nil, "测试图片加载失败")
        return model
    }
    @MainActor static func main() async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/ViewerFixtures")
        let photo = folder.appendingPathComponent("TextSample.png")
        try await MultiWindowChecks.run(photo: photo)
        if CommandLine.arguments.contains("--window-routing-only") { return }
        let model = EditorModel()
        model.sidePanel = .edit
        model.open(photo, viewingOnly: true)
        try await wait { !model.busy && model.browsingFiles.count == 2 }
        try expect(model.error == nil && model.image?.width == 960, "打开图片失败")
        try expect(model.sidePanel == nil, "Finder 打开图片未收起右侧栏")
        try expect(model.canNavigatePrevious && !model.canNavigateNext, "最后一张的导航状态不正确")
        print("PASS · 打开图片默认收起右侧栏、同文件夹浏览与边界状态")

        model.togglePanel(.thumbnails)
        model.navigate(-1)
        try await wait { !model.busy }
        try expect(model.sidePanel == .thumbnails && model.fileURL?.lastPathComponent == "RotatedSample.jpg", "预览导航丢失面板或目标图片")
        try expect(!model.canNavigatePrevious && model.canNavigateNext, "第一张的导航状态不正确")
        model.navigate(1)
        try await wait { !model.busy }
        model.togglePanel(.text)
        try await wait { !model.recognizingText }
        try expect(model.sidePanel == .text && model.recognizedText.contains("你好世界"), "OCR 未识别当前图片")
        model.togglePanel(.text)
        try expect(model.sidePanel == nil && model.recognizedText.isEmpty, "再次点击 OCR 未收起并清空结果")
        print("PASS · 预览前后跳转、面板互斥和 OCR 展开/收起")

        model.togglePanel(.text)
        model.togglePanel(.thumbnails)
        try await Task.sleep(for: .milliseconds(500))
        try expect(model.sidePanel == .thumbnails && model.recognizedText.isEmpty && !model.recognizingText, "关闭 OCR 后旧任务污染结果")
        model.togglePanel(.text)
        try await wait { !model.recognizingText }
        model.open(photo)
        try await wait { !model.busy && !model.recognizingText }
        try expect(model.sidePanel == .text && model.recognizedText.contains("EasyPic 2026"), "换图后 OCR 未刷新")
        print("PASS · OCR 旧结果取消、保留 OCR 面板并重新加载识别")

        model.togglePanel(.edit)
        model.apply(.counterclockwise)
        try await wait { !model.busy }
        try expect(model.image?.width == 360 && model.image?.height == 960 && model.canUndo, "逆时针旋转没有形成可撤销编辑")
        model.undo()
        try await wait { !model.busy }
        try expect(model.image?.width == 960 && model.image?.height == 360 && !model.dirty && model.canRedo, "撤销旋转失败")
        model.beginCrop(); model.togglePanel(.thumbnails)
        try expect(model.sidePanel == .edit, "裁剪时隐藏了操作面板")
        model.cancelCrop(); model.beginBrush(); model.togglePanel(.edit)
        try expect(model.sidePanel == nil && !model.brushMode, "关闭编辑栏未退出画笔模式")
        print("PASS · 旋转/撤销、裁剪期间面板保护、关闭编辑栏退出画笔")
        model.clearRecognition(); model.playback.clear(); model.livePlayback.clear()

        let tools = try await loaded(photo)
        try expect(NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: nil) != nil, "铅笔头图标不可用")
        for tool in EditorTool.allCases {
            try expect(NSImage(systemSymbolName: tool.icon, accessibilityDescription: nil) != nil, "工具图标不可用：" + tool.title)
        }
        tools.toggleEditor()
        try expect(tools.sidePanel == .edit && tools.activeEditorTool == nil, "首次打开编辑栏未只显示工具栏")
        tools.chooseEditorTool(.crop)
        try expect(tools.cropping && tools.activeEditorTool == .crop, "裁剪详情未打开")
        tools.chooseEditorTool(.solid)
        try expect(!tools.cropping && tools.brushMode && tools.brushTool == .solid, "切换画笔未退出裁剪")
        tools.chooseEditorTool(.mosaic); tools.brushTool = .blur
        tools.chooseEditorTool(.repair)
        try expect(tools.brushMode && tools.brushTool == .repair && !tools.brushRectangle, "消除画笔状态错误")
        tools.chooseEditorTool(.mosaic)
        try expect(tools.brushTool == .pixelate && tools.activeEditorTool == .mosaic, "马赛克入口未切换到马赛克画笔")
        tools.brushTool = .blur; tools.closeToolDetails()
        tools.chooseEditorTool(.mosaic)
        try expect(tools.brushTool == .blur, "重新打开马赛克未保留模糊样式")
        tools.chooseEditorTool(.mosaic)
        try expect(!tools.brushMode && tools.activeEditorTool == nil && tools.sidePanel == .edit, "重复点击未收起详情并保留工具栏")
        tools.toggleEditor()
        try expect(tools.sidePanel == nil, "编辑按钮未收起工具栏")
        print("PASS · 工具图标、两级展开/收起、裁剪和三种画笔互斥")

        tools.toggleEditor()
        for tool in [EditorTool.horizontal, .vertical, .rotate] {
            tools.chooseEditorTool(tool); try await wait { !tools.busy }
            try expect(tools.activeEditorTool == nil, "翻转或旋转打开了二级窗口")
        }
        try expect(tools.document?.operations == [.mirrorHorizontal, .mirrorVertical, .counterclockwise], "工具栏变换顺序或方向错误")
        try expect(tools.image?.width == 360 && tools.image?.height == 960, "旋转结果尺寸错误")
        tools.chooseEditorTool(.undo); try await wait { !tools.busy }
        try expect(tools.activeEditorTool == nil, "撤销打开了二级窗口")
        try expect(tools.image?.width == 960 && tools.canRedo, "工具栏撤销未生效")
        tools.chooseEditorTool(.redo); try await wait { !tools.busy }
        try expect(tools.activeEditorTool == nil, "重做打开了二级窗口")
        try expect(tools.image?.width == 360 && !tools.canRedo, "工具栏重做未生效")
        tools.playback.clear()
        print("PASS · 工具栏水平/垂直镜像、逆时针旋转及撤销重做")

        let stickers = try await loaded(photo)
        stickers.chooseEditorTool(.sticker)
        try expect(stickers.document?.layers.isEmpty == true && !stickers.choosingOpenLocation, "贴纸工具未等待用户点击导入")
        let stickerURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/EasyPicCoreTests/Fixtures/Static.png")
        stickers.importSticker(from: stickerURL); try await wait { !stickers.busy }
        try expect(stickers.document?.layers.count == 1 && stickers.selectedLayer?.text == nil && stickers.activeEditorTool == .sticker, "图片贴纸导入或选中失败")
        var sticker = stickers.selectedLayer!; sticker.center = CGPoint(x: 120, y: 100); sticker.angle = 27
        stickers.updateLayer(sticker, commit: true); try await wait { !stickers.busy }
        stickers.chooseEditorTool(.undo); try await wait { !stickers.busy }
        try expect(stickers.selectedLayer?.angle == 0, "贴纸位置/旋转撤销失败")
        stickers.playback.clear()
        print("PASS · 贴纸详情独立展开、图片导入、选中及变换撤销")

        let text = try await loaded(photo)
        text.chooseEditorTool(.text); text.addText()
        try await wait { !text.busy && text.textEditing }
        let initial = text.selectedLayer!
        var draft = initial
        draft.text?.content = "拖动与圆角\nEasyPic"
        draft.text?.cornerRadius = 24; draft.text?.backgroundColor = TextColor(0.2, 0.3, 0.8)
        draft.size = draft.text!.naturalSize; draft.center.x += 35; draft.angle = 12
        text.updateLayer(draft, commit: false)
        try expect(text.hasTextDraftChanges && text.document?.layers.first == initial, "文字预览提前写入撤销历史")
        text.chooseEditorTool(.mosaic)
        try await wait { !text.busy && text.brushMode }
        try expect(!text.textEditing && text.document?.layers.first?.text == draft.text && text.document?.layers.first?.center == draft.center, "文字切换工具时未保存样式与位置")
        let committed = text.document!
        let rendered = try DocumentEngine.render(committed, resources: text.resources)
        try expect(rendered.width == text.image?.width && text.documentPreview != nil, "文字切换后未完成图片渲染")
        text.chooseEditorTool(.undo); try await wait { !text.busy }
        try expect(text.document?.layers.first == initial && text.brushMode && text.activeEditorTool == .mosaic, "文字预览修改撤销未恢复文档或保留马赛克面板")
        text.chooseEditorTool(.redo); try await wait { !text.busy }
        try expect(text.document == committed, "文字重做丢失样式或位置")
        text.chooseEditorTool(.text)
        var invalid = text.selectedLayer!; invalid.text?.fontSize = 0
        text.updateLayer(invalid, commit: false); text.chooseEditorTool(.solid)
        try expect(text.textEditing && !text.brushMode && text.error != nil, "非法文字参数未阻止工具切换")
        text.error = nil; text.cancelTextEditing(); try await wait { !text.busy }
        try expect(text.document == committed && text.draftLayer == nil, "取消文字修改破坏已提交文档")
        text.editText()
        var closing = text.selectedLayer!; closing.text?.content = "收起时保存"
        text.updateLayer(closing, commit: false); text.toggleEditor()
        try expect(text.confirmingEditorExit && text.sidePanel == .edit && text.textEditing, "退出编辑未先询问保存")
        text.cancelEditorExit()
        try expect(text.draftLayer?.text?.content == "收起时保存" && text.sidePanel == .edit, "取消退出丢失了文字草稿")
        text.toggleEditor(); text.discardEditorSession()
        try expect(text.sidePanel == nil && text.document?.layers.isEmpty == true && !text.textEditing && text.canBrowse,
                   "放弃退出未恢复本次编辑之前的图片")
        text.playback.clear()
        print("PASS · 文字草稿、切换提交、整步撤销、退出确认/取消/放弃和非法设置保护")

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let readonly = try await loaded(root.appendingPathComponent("Tests/EasyPicCoreTests/Fixtures/Animated.gif"))
        try expect(readonly.playback.isPlaying && EditorTool.allCases.allSatisfy { !readonly.toolEnabled($0) }, "动图播放或只读保护失败")
        readonly.toggleEditor(); try expect(readonly.sidePanel == nil, "只读动图打开了编辑栏")
        readonly.playback.clear()
        try expect(CommandLine.arguments.count == 2, "缺少 Live Photo 合成样本目录")
        let live = try await loaded(URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Portrait.JPG"))
        try expect(live.livePhoto != nil && live.toolEnabled(.crop), "Live Photo 未启用裁剪")
        try expect([EditorTool.horizontal, .vertical, .rotate, .sticker, .text, .solid, .mosaic, .repair].allSatisfy { !live.toolEnabled($0) }, "Live Photo 启用了不支持的编辑")
        live.toggleEditor(); live.chooseEditorTool(.crop); live.cancelCrop()
        try expect(live.activeEditorTool == .crop && live.canEdit, "取消裁剪未保留封面工具入口")
        live.playback.clear(); live.livePlayback.clear()
        print("PASS · GIF 保持只读播放、Live Photo 仅启用裁剪和封面相关工具")
        try await CropChecks.run(photo: photo, liveURL: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Portrait.JPG"))
        try await SaveChecks.run(photo: photo)
        print("16 项查看器与编辑工具模型验证通过")
    }
}
