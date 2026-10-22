import AppKit
import SwiftUI

private struct CanvasRenderingKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var canvasRenderingActive: Bool {
        get { self[CanvasRenderingKey.self] }
        set { self[CanvasRenderingKey.self] = newValue }
    }
}

@MainActor final class WindowRenderingActivity {
    private weak var window: NSWindow?
    private weak var model: EditorModel?
    private var tokens: [NSObjectProtocol] = [], workspaceTokens: [NSObjectProtocol] = []
    private var resumeTask: Task<Void, Never>?
    private var resumeAnimation = false, resumeLive = false
    private var sleeping = false
    func attach(_ window: NSWindow, model: EditorModel) {
        guard self.window !== window else { return }
        self.window = window; self.model = model
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    if name == NSWorkspace.screensDidSleepNotification { self?.sleeping = true }
                    if name == NSWorkspace.screensDidWakeNotification { self?.sleeping = false }
                    self?.refresh(spaceTransition: true)
                }
            })
        }
        refresh()
    }
    func refresh(spaceTransition: Bool = false) {
        resumeTask?.cancel()
        guard let window else { return }
        let visible = !sleeping && window.isVisible && !window.isMiniaturized && window.isOnActiveSpace && window.occlusionState.contains(.visible)
        if !visible || spaceTransition { suspend() }
        guard visible else { return }
        // Keep cached content during the desktop slide. Resume optional work after it settles.
        resumeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard let self, let window = self.window, window.isOnActiveSpace,
                  window.occlusionState.contains(.visible), !window.isMiniaturized else { return }
            self.model?.windowIsRendering = true
            (window.contentView as? GlassBackdropView)?.setRenderingActive(true)
            if self.resumeAnimation { self.model?.playback.play() }
            if self.resumeLive { self.model?.livePlayback.play() }
            self.resumeAnimation = false; self.resumeLive = false
        }
    }
    private func suspend() {
        guard let model else { return }
        resumeAnimation = resumeAnimation || model.playback.isPlaying
        resumeLive = resumeLive || model.livePlayback.isPlaying
        model.windowIsRendering = false
        model.playback.pause(); model.livePlayback.pause(); model.prefetchTask?.cancel()
        (window?.contentView as? GlassBackdropView)?.setRenderingActive(false)
    }
    deinit {
        resumeTask?.cancel()
        tokens.forEach(NotificationCenter.default.removeObserver)
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}
