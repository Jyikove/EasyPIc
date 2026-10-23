import EasyPicCore
import SwiftUI
import AppKit

@main
struct EasyPicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @FocusedValue(\.editorModel) private var focusedModel
    @StateObject private var emptyModel = EditorModel()
    private var model: EditorModel { focusedModel ?? emptyModel }
    @StateObject private var languageSettings = AppLanguageSettings.shared

    init() { AppLanguageSettings.shared.prepareSystemLanguage() }

    var body: some Scene {
        WindowGroup("EasyPic", id: "editor", for: URL.self) { $url in
            EditorWindowRoot(delegate: delegate, initialURL: url)
                .environmentObject(languageSettings)
                .environment(\.locale, languageSettings.language.locale)
        }
        .defaultSize(width: 1180, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("关于 EasyPic")) {
                    GlassUtilityPresenter.showAbout()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("打开图片或文件夹…"), action: model.openPanel).keyboardShortcut("o")
                Button(L10n.text("关闭窗口")) {
                    NSApp.keyWindow?.performClose(nil)
                }.keyboardShortcut("w")
            }
            CommandGroup(replacing: .saveItem) {
                Button(L10n.text("保存"), action: model.saveUsingShortcut).keyboardShortcut("s").disabled(!model.canPerformEditorActions)
                Button(L10n.text("保存并替换原图")) { model.chooseEditorTool(.replaceOriginal) }.disabled(!model.canReplaceOriginal)
                Button(L10n.text("保存可编辑项目…"), action: model.saveFromEditor).keyboardShortcut("s", modifiers: [.command, .option]).disabled(!model.canPerformEditorActions || model.cropping || model.livePhoto != nil)
                Button(L10n.text("另存为"), action: model.exportFromEditor).keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.canPerformEditorActions)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(L10n.text("撤销")) { model.chooseEditorTool(.undo) }.keyboardShortcut("z").disabled(!model.toolEnabled(.undo))
                Button(L10n.text("重做")) { model.chooseEditorTool(.redo) }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.toolEnabled(.redo))
            }
            CommandGroup(after: .windowSize) {
                Button(L10n.text("切换全屏")) { delegate.editorWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [.control, .command])
                Button(L10n.text("适应窗口"), action: model.resetZoom).keyboardShortcut("0").disabled(model.image == nil)
                Button(L10n.text("实际像素")) { model.resetZoom(); model.actualSize = true }
                    .keyboardShortcut("1").disabled(model.image == nil || model.cropping)
            }
        }

        Settings {
            LanguageSettingsView()
                .environmentObject(languageSettings)
                .environment(\.locale, languageSettings.language.locale)
        }
    }
}

private struct EditorModelFocusKey: FocusedValueKey {
    typealias Value = EditorModel
}
extension FocusedValues {
    var editorModel: EditorModel? {
        get { self[EditorModelFocusKey.self] }
        set { self[EditorModelFocusKey.self] = newValue }
    }
}

private struct EditorWindowRoot: View {
    let delegate: AppDelegate
    let initialURL: URL?
    @StateObject private var model = EditorModel()
    @State private var opened = false
    @State private var loadedURL: URL?
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        EditorView(model: model, delegate: delegate)
            .focusedSceneValue(\.editorModel, model)
            .onAppear {
                delegate.showEditor = { openWindow(id: "editor") }
                delegate.openEditor = { openWindow(id: "editor", value: $0) }
                guard !opened else { return }
                opened = true
                loadInitialURL(initialURL)
                delegate.ready(model)
            }
            // WindowGroup may populate its value after the view first appears.
            // A nil launch value must not permanently mark the document loaded.
            .onChange(of: initialURL) { _, url in loadInitialURL(url) }
            .onOpenURL { url in
                if model.image == nil && !model.busy && model.error == nil {
                    loadInitialURL(url)
                } else if model.fileURL != url {
                    openWindow(id: "editor", value: url)
                }
            }
            .onDisappear { model.playback.pause(); model.livePlayback.pause() }
    }
    private func loadInitialURL(_ url: URL?) {
        guard let url, loadedURL != url else { return }
        loadedURL = url
        model.open(url, viewingOnly: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: EditorModel?
    weak var editorWindow: NSWindow?
    var showEditor: (() -> Void)?
    var openEditor: ((URL) -> Void)?
    private var pendingURLs: [URL] = []
    private var editors: [ObjectIdentifier: Entry] = [:]
    private var allowTermination = false
    private var legacyRedoMonitor: Any?
    private let menuLayout = ApplicationMenuLayout()
    private final class Entry {
        weak var window: NSWindow?
        weak var model: EditorModel?
        init(_ window: NSWindow, _ model: EditorModel) { self.window = window; self.model = model }
    }
    func register(_ window: NSWindow, model: EditorModel) {
        editors[ObjectIdentifier(window)] = Entry(window, model)
        self.model = model; editorWindow = window
        menuLayout.schedule()
    }
    func ready(_ model: EditorModel) {
        if self.model == nil { self.model = model }
        let urls = pendingURLs; pendingURLs.removeAll()
        if model.image == nil && !model.busy, let first = urls.first {
            model.open(first, viewingOnly: true)
            openURLs(Array(urls.dropFirst()))
        } else { openURLs(urls) }
    }
    func openURLs(_ urls: [URL]) {
        guard let openEditor else { pendingURLs.append(contentsOf: urls); return }
        for url in urls {
            // Reuse only an unused launch window. An existing document is never
            // replaced by a Finder request, even while it is still loading.
            if let model, model.image == nil, !model.busy, model.error == nil {
                model.open(url, viewingOnly: true)
                editorWindow?.makeKeyAndOrderFront(nil)
            } else { openEditor(url) }
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        menuLayout.start()
        legacyRedoMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard let self, event.window === self.editorWindow, let model = self.model else { return false }
                let key = event.charactersIgnoringModifiers?.lowercased()
                if modifiers == .command, key == "y", model.toolEnabled(.redo) { model.chooseEditorTool(.redo); return true }
                if (modifiers == .command || modifiers == [.command, .shift]), key == "r", model.canRotate {
                    model.apply(modifiers.contains(.shift) ? .counterclockwise : .clockwise); return true
                }
                if modifiers == .command, key == "k", model.canEdit { model.beginCrop(); return true }
                if modifiers.isEmpty {
                    if event.keyCode == 123, model.canNavigatePrevious { model.navigate(-1); return true }
                    if event.keyCode == 124, model.canNavigateNext { model.navigate(1); return true }
                    if event.keyCode == 53 {
                        if model.cropping, !model.busy { model.cancelCrop(); return true }
                        if model.brushMode, model.canPerformEditorActions { model.closeToolDetails(); return true }
                    }
                }
                return false
            }
            return handled ? nil : event
        }
        if let iconURL = Bundle.main.url(forResource: "EasyPicIcon", withExtension: "icns"), let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let legacyRedoMonitor { NSEvent.removeMonitor(legacyRedoMonitor) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showEditor?() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowTermination { return .terminateNow }
        let active = editors.values.compactMap { $0.window == nil ? nil : $0.model }
        let models = active.isEmpty ? [model].compactMap { $0 } : active
        guard models.allSatisfy({ $0.image == nil || $0.canRequestApplicationExit }) else {
            NSSound.beep(); return .terminateCancel
        }
        guard let pending = models.first(where: { $0.dirty || $0.editorSessionHasChanges }) else { return .terminateNow }
        editors.values.first(where: { $0.model === pending })?.window?.makeKeyAndOrderFront(nil)
        confirmTermination(models.filter { $0.dirty || $0.editorSessionHasChanges }, sender: sender)
        return .terminateCancel
    }
    private func confirmTermination(_ remaining: [EditorModel], sender: NSApplication) {
        guard let current = remaining.first else {
            allowTermination = true
            sender.terminate(nil)
            return
        }
        editors.values.first(where: { $0.model === current })?.window?.makeKeyAndOrderFront(nil)
        current.requestApplicationExit { [weak self] in
            self?.confirmTermination(Array(remaining.dropFirst()), sender: sender)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model = editors[ObjectIdentifier(sender)]?.model, model.image != nil else { return true }
        guard model.canRequestApplicationExit else { NSSound.beep(); return false }
        guard model.dirty || model.editorSessionHasChanges else { return true }
        model.requestApplicationExit { [weak sender] in sender?.close() }
        return false
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        editorWindow = window; model = editors[ObjectIdentifier(window)]?.model
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let entry = editors.removeValue(forKey: ObjectIdentifier(window))
        entry?.model?.playback.pause(); entry?.model?.livePlayback.pause()
        if editorWindow === window { editorWindow = nil; model = nil }
    }
}

struct WindowBridge: NSViewRepresentable {
    let delegate: AppDelegate
    let model: EditorModel
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
            delegate.register(window, model: model)
            // Preserve SwiftUI's delegate: it owns the scene/window lifecycle.
            context.coordinator.original = window.delegate
            window.delegate = context.coordinator
            context.coordinator.renderingActivity.attach(window, model: model)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    let renderingActivity = WindowRenderingActivity()
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
    func windowDidBecomeKey(_ notification: Notification) {
        owner.windowDidBecomeKey(notification)
        original?.windowDidBecomeKey?(notification)
    }
    func windowWillClose(_ notification: Notification) {
        owner.windowWillClose(notification)
        original?.windowWillClose?(notification)
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
