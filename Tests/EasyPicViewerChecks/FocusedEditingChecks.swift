import AppKit
import UniformTypeIdentifiers
import EasyPicCore

@MainActor
enum FocusedEditingChecks {
    static func run(photo: URL) async throws {
        let model = try await ViewerModelChecks.loaded(photo)
        let before = model.document
        let resourceCount = model.resources.count
        model.toggleEditor(); model.chooseEditorTool(.sticker)
        let providers = (0..<2).map { _ in NSItemProvider(item: photo as NSURL, typeIdentifier: UTType.fileURL.identifier) }
        try ViewerModelChecks.expect(model.importDroppedStickers(providers), "贴纸面板拒绝文件拖入")
        try await ViewerModelChecks.wait { !model.busy && model.document?.layers.count == 2 }
        model.toggleEditor()
        try ViewerModelChecks.expect(model.confirmingEditorExit && model.sidePanel == .edit, "修改后退出没有先询问")
        model.cancelEditorExit()
        try ViewerModelChecks.expect(model.document?.layers.count == 2 && model.sidePanel == .edit, "取消退出丢失编辑")
        model.toggleEditor(); model.discardEditorSession()
        try ViewerModelChecks.expect(model.document == before && model.resources.count == resourceCount &&
                                     model.sidePanel == nil && model.canBrowse && !model.canUndo && !model.dirty,
                                     "放弃没有恢复整个编辑会话，包括资源和历史")
        model.playback.clear()
        print("PASS · 多文件拖入贴纸，退出确认/取消，放弃恢复图像、资源和历史")

        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/ViewerChecks/Editing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("Source.png")
        try FileManager.default.copyItem(at: photo, to: source)
        let saving = try await ViewerModelChecks.loaded(source)
        saving.toggleEditor(); saving.chooseEditorTool(.rotate)
        try await ViewerModelChecks.wait { !saving.busy }
        saving.toggleEditor()
        try ViewerModelChecks.expect(saving.confirmingEditorExit && saving.editorExitUsesReplacement, "退出保存没有选择可用的原图保存")
        saving.saveAndExitEditor()
        try await ViewerModelChecks.wait { !saving.busy && saving.sidePanel == nil }
        let written = try ImageEngine.load(source)
        try ViewerModelChecks.expect(!saving.dirty && written.image.width == 360 && written.image.height == 960,
                                     "保存退出没有写入修改或没有返回查看模式")
        let checkpoint = saving.document
        saving.toggleEditor(); saving.chooseEditorTool(.horizontal)
        try await ViewerModelChecks.wait { !saving.busy }
        saving.toggleEditor(); saving.discardEditorSession()
        try ViewerModelChecks.expect(saving.document == checkpoint && !saving.dirty && saving.canBrowse,
                                     "后续放弃没有恢复最近保存的状态")
        saving.playback.clear()
        print("PASS · 保存成功后退出，重新编辑并放弃恢复最近保存的状态")

        let exporting = try await ViewerModelChecks.loaded(photo)
        let originalBytes = try Data(contentsOf: photo)
        exporting.toggleEditor(); exporting.chooseEditorTool(.text); exporting.addText()
        try await ViewerModelChecks.wait { !exporting.busy && exporting.textEditing }
        exporting.finishInlineText {}
        try await ViewerModelChecks.wait { !exporting.busy && !exporting.textEditing }
        exporting.exportSheet = true
        exporting.writeExport(exporting.image!, source: photo, destination: folder)
        try await ViewerModelChecks.wait { !exporting.busy }
        try ViewerModelChecks.expect(exporting.error != nil && exporting.document?.layers.count == 1 && exporting.dirty,
                                     "写入失败合并了图层或丢失编辑")
        exporting.error = nil
        let destination = folder.appendingPathComponent("Saved.png")
        exporting.writeExport(exporting.image!, source: photo, destination: destination)
        try await ViewerModelChecks.wait { !exporting.busy }
        let saved = try ImageEngine.load(destination)
        let unchangedSource = try Data(contentsOf: photo)
        try ViewerModelChecks.expect(exporting.error == nil && exporting.document?.layers.isEmpty == true &&
                                     !exporting.dirty && saved.image.width == 960 && unchangedSource == originalBytes,
                                     "另存为没有合并图层或改写了源图")
        exporting.toggleEditor()
        try ViewerModelChecks.expect(exporting.sidePanel == nil && !exporting.confirmingEditorExit && exporting.canBrowse,
                                     "已保存且未继续修改时仍弹出退出确认")
        exporting.playback.clear()
        print("PASS · 另存为失败保留图层，成功合并且保留原文件，已保存退出无需确认")
    }
}
