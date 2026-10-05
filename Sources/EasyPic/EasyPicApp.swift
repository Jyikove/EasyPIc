import EasyPicCore
import SwiftUI
import AppKit

@main
struct EasyPicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = EditorModel()
    @StateObject private var languageSettings = AppLanguageSettings.shared

    init() { AppLanguageSettings.shared.prepareSystemLanguage() }

    var body: some Scene {
        Window("EasyPic", id: "editor") {
            EditorView(model: model, delegate: delegate)
                .environmentObject(languageSettings)
                .environment(\.locale, languageSettings.language.locale)
                .onAppear {
                    delegate.model = model
                    if let url = delegate.pendingURL { delegate.pendingURL = nil; model.open(url, viewingOnly: true) }
                    else if model.mediaInfo?.animation != nil { model.playback.play() }
                }
                .onDisappear { model.playback.pause(); model.livePlayback.pause() }
                .onOpenURL { model.open($0, viewingOnly: true) }
        }
        .defaultSize(width: 1180, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text(L10n.text("设置…")) }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("关于 EasyPic")) {
                    GlassUtilityPresenter.showAbout()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("打开图片或文件夹…"), action: model.openPanel).keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button(L10n.text("保存并替换原图")) { model.chooseEditorTool(.replaceOriginal) }.disabled(!model.canReplaceOriginal)
                Button(L10n.text("保存可编辑项目…"), action: model.saveFromEditor).keyboardShortcut("s").disabled(!model.canPerformEditorActions || model.cropping || model.livePhoto != nil)
                Button(L10n.text("导出图片…"), action: model.exportFromEditor).keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.canPerformEditorActions || model.cropping)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(L10n.text("撤销")) { model.chooseEditorTool(.undo) }.keyboardShortcut("z").disabled(!model.toolEnabled(.undo))
                Button(L10n.text("重做")) { model.chooseEditorTool(.redo) }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.toolEnabled(.redo))
            }
            CommandGroup(after: .windowSize) {
                Button(L10n.text("切换全屏")) { delegate.editorWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [.control, .command])
            }
            CommandMenu(L10n.text("图片")) {
                Button(L10n.text("本地画笔…"),action:model.beginBrush).disabled(!model.canUseLayers)
                Button(L10n.text("添加文字"), action: model.addText).disabled(!model.canUseLayers)
                Button(L10n.text("添加图片贴纸…"), action: model.importSticker).disabled(!model.canUseLayers)
                Button(L10n.text("向右旋转 90°")) { model.apply(.clockwise) }.keyboardShortcut("r").disabled(!model.canTransform)
                Button(L10n.text("向左旋转 90°")) { model.apply(.counterclockwise) }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!model.canTransform)
                Button(L10n.text("水平镜像")) { model.apply(.mirrorHorizontal) }.disabled(!model.canTransform)
                Button(L10n.text("垂直镜像")) { model.apply(.mirrorVertical) }.disabled(!model.canTransform)
                Divider()
                Button(L10n.text("将当前帧设为封面"), action: model.setLiveCover).disabled(!model.canEdit || model.livePhoto == nil)
                Button(L10n.text("裁剪"), action: model.beginCrop).keyboardShortcut("k").disabled(!model.canEdit)
                Button(L10n.text("应用裁剪"), action: model.commitCrop).keyboardShortcut(.return, modifiers: []).disabled(!model.canApplyCrop)
                Button(L10n.text("取消裁剪"), action: model.cancelCrop).keyboardShortcut(.escape, modifiers: []).disabled(!model.cropping || model.busy)
                Button(L10n.text("退出画笔"), action: model.closeToolDetails).keyboardShortcut(.escape, modifiers: []).disabled(!model.brushMode || !model.canPerformEditorActions)
                Button(L10n.text("适应窗口"), action: model.resetZoom).keyboardShortcut("0").disabled(model.image == nil)
                Button(L10n.text("实际像素")) { model.actualSize = true; model.zoom = 1 }.keyboardShortcut("1").disabled(model.image == nil || model.cropping)
                Divider()
                Button(L10n.text("上一张")) { model.navigate(-1) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(!model.canNavigatePrevious)
                Button(L10n.text("下一张")) { model.navigate(1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(!model.canNavigateNext)
                Divider()
                Button(L10n.text("播放 / 暂停")) {
                    if model.livePhoto != nil { model.livePlayback.toggle() }
                    else { model.playback.toggle() }
                }.disabled(!model.canBrowse || (model.livePhoto == nil && model.mediaInfo?.animation == nil))
                Button(L10n.text("从头播放")) {
                    if model.livePhoto != nil { model.livePlayback.restart() }
                    else { model.playback.restart() }
                }.disabled(!model.canBrowse || (model.livePhoto == nil && model.mediaInfo?.animation == nil))
            }
        }
        Settings {
            LanguageSettingsView()
                .environmentObject(languageSettings)
                .environment(\.locale, languageSettings.language.locale)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: EditorModel?
    weak var editorWindow: NSWindow?
    var pendingURL: URL?
    var showEditor: (() -> Void)?
    private var allowTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "EasyPicIcon", withExtension: "icns"), let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let path = filenames.first {
            showEditor?()
            let url = URL(fileURLWithPath: path)
            if let model { model.open(url, viewingOnly: true) } else { pendingURL = url }
        }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEditor?() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowTermination { return .terminateNow }
        guard let model, model.image != nil else { return .terminateNow }
        guard model.canRequestApplicationExit else { NSSound.beep(); return .terminateCancel }
        guard model.dirty || model.editorSessionHasChanges else { return .terminateNow }
        model.requestApplicationExit { [weak self] in
            self?.allowTermination = true
            sender.terminate(nil)
        }
        return .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowTermination { return true }
        guard let model, model.image != nil else { return true }
        guard model.canRequestApplicationExit else { NSSound.beep(); return false }
        guard model.dirty || model.editorSessionHasChanges else { return true }
        model.requestApplicationExit { [weak self] in
            self?.allowTermination = true
            NSApp.terminate(nil)
        }
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
            window.animationBehavior = .documentWindow
            window.collectionBehavior.insert(.fullScreenPrimary)
            delegate.editorWindow = window
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
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        NotificationCenter.default.post(name: .easyPicFullScreenTransitionFailed, object: window)
        original?.windowDidFailToEnterFullScreen?(window)
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        NotificationCenter.default.post(name: .easyPicFullScreenTransitionFailed, object: window)
        original?.windowDidFailToExitFullScreen?(window)
    }
}

/// Measures the space already reserved below the toolbar's visible controls.
struct ToolbarSpacingReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void
    func makeNSView(context: Context) -> ToolbarSpacingView {
        let view = ToolbarSpacingView()
        view.onChange = onChange
        return view
    }
    func updateNSView(_ nsView: ToolbarSpacingView, context: Context) {
        nsView.onChange = onChange
        nsView.needsLayout = true
    }
}

final class ToolbarSpacingView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var lastSpacing: CGFloat?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let window, bounds.height > 0 else { return }
        let frameInWindow = convert(bounds, to: nil)
        let spacing = max(0, frameInWindow.minY - window.contentLayoutRect.maxY)
        guard lastSpacing == nil || abs(spacing - lastSpacing!) > 0.5 else { return }
        lastSpacing = spacing
        DispatchQueue.main.async { [weak self] in self?.onChange?(spacing) }
    }
}
