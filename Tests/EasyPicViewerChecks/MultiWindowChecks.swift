import AppKit
import EasyPicCore

struct MultiWindowChecks {
    @MainActor static func run(photo: URL) async throws {
        let delegate = AppDelegate()
        let first = EditorModel()
        var requests: [URL] = []
        let second = photo.deletingLastPathComponent().appendingPathComponent("RotatedSample.jpg")
        delegate.openURLs([photo, second])
        delegate.openEditor = { requests.append($0) }
        delegate.ready(first)
        try await ViewerModelChecks.wait { !first.busy && first.image != nil }
        try ViewerModelChecks.expect(first.fileURL == photo && requests == [second], "启动文件队列丢失或替换了首张图片")
        delegate.openURLs([second, photo])
        try ViewerModelChecks.expect(first.fileURL == photo && requests == [second, second, photo], "再次打开图片未路由到独立窗口")
        let next = try await ViewerModelChecks.loaded(second)
        let w1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let w2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        w1.isReleasedWhenClosed = false; w2.isReleasedWhenClosed = false
        delegate.register(w1, model: first); delegate.register(w2, model: next)
        first.chooseEditorTool(.text)
        var draft = first.selectedLayer!
        draft.text?.content = "Unsaved window one"
        draft.size = draft.text!.naturalSize
        first.updateLayer(draft, commit: false)
        try ViewerModelChecks.expect(delegate.windowShouldClose(w2), "干净窗口被其他窗口草稿阻止关闭")
        try ViewerModelChecks.expect(!delegate.windowShouldClose(w1) && first.confirmingEditorExit && !next.confirmingEditorExit, "关闭提示未定位到所属窗口")
        first.cancelEditorExit()
        try ViewerModelChecks.expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel && first.confirmingEditorExit, "退出未检查非活动窗口的修改")
        first.cancelEditorExit()
        delegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: w1))
        try ViewerModelChecks.expect(delegate.model === first, "当前窗口模型未更新")
        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: w2))
        try ViewerModelChecks.expect(delegate.model === first && first.image != nil, "关闭其他窗口清除了当前文档")
        first.previewTask?.cancel()
        print("PASS · Finder 文件队列、连续多文件路由、窗口独立状态、关闭与退出保护")
    }
}
