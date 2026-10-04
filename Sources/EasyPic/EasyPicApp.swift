import SwiftUI
import AppKit

@main
struct EasyPicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = EditorModel()

    var body: some Scene {
        Window("EasyPic", id: "editor") {
            EditorView(model: model, delegate: delegate)
                .onAppear {
                    delegate.model = model
                    if let url = delegate.pendingURL { delegate.pendingURL = nil; model.open(url) }
                    else if model.mediaInfo?.animation != nil { model.playback.play() }
                }
                .onDisappear { model.playback.pause() }
                .onOpenURL { model.open($0) }
        }
        .defaultSize(width: 1180, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开图片或文件夹…", action: model.openPanel).keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("导出图片…", action: model.showExport).keyboardShortcut("s").disabled(!model.canEdit)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销", action: model.undo).keyboardShortcut("z").disabled(!model.canEdit || !model.history.canUndo)
                Button("重做", action: model.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canEdit || !model.history.canRedo)
            }
            CommandMenu("图片") {
                Button("向右旋转 90°") { model.apply(.clockwise) }.keyboardShortcut("r").disabled(!model.canEdit)
                Button("向左旋转 90°") { model.apply(.counterclockwise) }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!model.canEdit)
                Button("水平镜像") { model.apply(.mirrorHorizontal) }.disabled(!model.canEdit)
                Button("垂直镜像") { model.apply(.mirrorVertical) }.disabled(!model.canEdit)
                Divider()
                Button("裁剪", action: model.beginCrop).keyboardShortcut("k").disabled(!model.canEdit)
                Button("适应窗口", action: model.resetZoom).keyboardShortcut("0").disabled(model.image == nil)
                Button("实际像素") { model.actualSize = true; model.zoom = 1 }.keyboardShortcut("1").disabled(model.image == nil || model.cropping)
                Divider()
                Button("上一张") { model.navigate(-1) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(!model.canBrowse)
                Button("下一张") { model.navigate(1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(!model.canBrowse)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: EditorModel?
    var pendingURL: URL?
    private var allowTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let path = filenames.first {
            let url = URL(fileURLWithPath: path)
            if let model { model.open(url) } else { pendingURL = url }
        }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowTermination { return .terminateNow }
        guard let model else { return .terminateNow }
        guard !model.busy, !model.exportSheet, !model.choosingExportLocation else { NSSound.beep(); return .terminateCancel }
        guard model.dirty else { return .terminateNow }
        model.requestLeave { [weak self] in self?.allowTermination = true; NSApp.terminate(nil) }
        return .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model else { return true }
        guard !model.busy, !model.exportSheet, !model.choosingExportLocation else { NSSound.beep(); return false }
        guard model.dirty else { return true }
        model.requestLeave { [weak self] in self?.allowTermination = true; NSApp.terminate(nil) }
        return false
    }
}

struct WindowBridge: NSViewRepresentable {
    let delegate: AppDelegate
    func makeCoordinator() -> WindowDelegateProxy { WindowDelegateProxy(owner: delegate) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.backgroundColor = .clear
            window.isOpaque = false
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            // Preserve SwiftUI's delegate: it owns the scene/window lifecycle.
            context.coordinator.original = window.delegate
            window.delegate = context.coordinator
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    let owner: AppDelegate
    var original: (any NSWindowDelegate)?
    init(owner: AppDelegate) { self.owner = owner }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard owner.windowShouldClose(sender) else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }
}

struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
