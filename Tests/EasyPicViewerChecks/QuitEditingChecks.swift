import Foundation
import AppKit
import EasyPicCore

struct QuitEditingChecks {
    @MainActor static func run(photo: URL) async throws {
        let root = photo.deletingLastPathComponent().appendingPathComponent("QuitChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Sample.png")
        try FileManager.default.copyItem(at: photo, to: source)
        let model = try await ViewerModelChecks.loaded(source)
        model.chooseEditorTool(.text)
        var draft = model.selectedLayer!; draft.text?.content = "Unsaved text"; draft.size = draft.text!.naturalSize
        model.updateLayer(draft, commit: false)
        let delegate = AppDelegate(); delegate.model = model
        try ViewerModelChecks.expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel && model.confirmingEditorExit,
                                     "Cmd+Q 仍被文字编辑阻止，没有显示同一个保存提示")
        model.cancelEditorExit()
        try ViewerModelChecks.expect(model.textEditing && model.draftLayer == draft && model.pendingEditorExitAction == nil,
                                     "取消退出丢失文字或保留了退出回调")
        var didExit = false
        model.requestApplicationExit { didExit = true }
        model.saveAndExitEditor()
        try await ViewerModelChecks.wait { !model.busy && !model.textEditing }
        try ViewerModelChecks.expect(didExit && model.sidePanel == nil && !model.dirty && model.document?.layers.isEmpty == true,
                                     "保存后未继续退出或没有提交文字")
        let saved = try ImageEngine.load(source)
        try ViewerModelChecks.expect(saved.image.width == 960 && saved.image.height == 360, "退出前保存破坏图片")
        model.playback.clear()

        let discard = try await ViewerModelChecks.loaded(source)
        discard.chooseEditorTool(.text)
        var pending = discard.selectedLayer!; pending.text?.content = "Discard"; pending.size = pending.text!.naturalSize
        discard.updateLayer(pending, commit: false)
        var discardedExit = false
        discard.requestApplicationExit { discardedExit = true }
        discard.discardEditorSession()
        try ViewerModelChecks.expect(discardedExit && discard.document?.layers.isEmpty == true && !discard.textEditing, "不保存没有继续退出")
        discard.playback.clear()

        let failed = try await ViewerModelChecks.loaded(source)
        failed.chooseEditorTool(.text)
        var failureDraft = failed.selectedLayer!; failureDraft.text?.content = "Keep if save fails"; failureDraft.size = failureDraft.text!.naturalSize
        failed.updateLayer(failureDraft, commit: false)
        var failedExit = false
        failed.requestApplicationExit { failedExit = true }
        try FileManager.default.removeItem(at: source)
        failed.saveAndExitEditor()
        try await ViewerModelChecks.wait { !failed.busy }
        try ViewerModelChecks.expect(!failedExit && failed.sidePanel == .edit && failed.error != nil && failed.pendingEditorExitAction == nil,
                                     "保存失败仍退出，或遗留退出回调")
        failed.playback.clear()
        let readonlyURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/EasyPicCoreTests/Fixtures/Animated.gif")
        let readonly = try await ViewerModelChecks.loaded(readonlyURL)
        let readonlyDelegate = AppDelegate(); readonlyDelegate.model = readonly
        try ViewerModelChecks.expect(readonlyDelegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow,
                                     "只读动图被编辑保护阻止退出")
        readonly.playback.clear()
        print("PASS · Cmd+Q 接受文字草稿，取消保留、保存后继续退出、不保存退出、保存失败留在编辑")
    }
}
