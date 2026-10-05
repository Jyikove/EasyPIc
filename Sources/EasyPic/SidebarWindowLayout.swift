import AppKit
import SwiftUI
import QuartzCore

extension Notification.Name {
    static let easyPicFullScreenTransitionFailed = Notification.Name("EasyPicFullScreenTransitionFailed")
}

struct SidebarWidthPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Keep the document viewport by adding the sidebar's measured footprint to the window.
struct SidebarWindowBridge: NSViewRepresentable {
    @ObservedObject var sizer: SidebarWindowSizer
    let sidebarWidth: CGFloat
    func makeCoordinator() -> SidebarWindowSizer { sizer }
    func makeNSView(context: Context) -> SidebarAttachmentView {
        let view = SidebarAttachmentView()
        view.attach = { [weak sizer = context.coordinator] window in sizer?.attach(to: window) }
        context.coordinator.update(sidebarWidth: sidebarWidth)
        return view
    }
    func updateNSView(_ view: SidebarAttachmentView, context: Context) {
        context.coordinator.update(sidebarWidth: sidebarWidth)
    }
}

final class SidebarAttachmentView: NSView {
    var attach: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { attach?(window) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class SidebarWindowSizer: ObservableObject {
    // Enough for the titlebar controls, without imposing the old wide document minimum.
    static let minimumViewerWidth: CGFloat = 440
    /// Independent of sidebar measurement, so a newly inserted panel cannot squeeze the image.
    @Published private(set) var viewportWidth: CGFloat?
    private weak var window: NSWindow?
    private let minimumWidth: CGFloat
    private let horizontalInset: CGFloat
    private var desiredWidth: CGFloat = 0
    private var appliedWidth: CGFloat = 0
    private var baseWindowWidth: CGFloat = 0
    private var resizeGeneration: UUID?
    private var resizeDisplayLink: CADisplayLink?
    private var animationStart = NSRect.zero
    private var animationTarget = NSRect.zero
    private var animationStartedAt: CFTimeInterval = 0
    private var fullScreenTransition = false
    private var reconcileFullScreen = false
    private var pendingResize = false
    private var appActive = true
    private var observers: [NSObjectProtocol] = []

    init(minimumWidth: CGFloat, horizontalInset: CGFloat = 24) {
        self.minimumWidth = minimumWidth; self.horizontalInset = horizontalInset
    }
    deinit { resizeDisplayLink?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        self.window = window
        resizeDisplayLink?.invalidate(); resizeDisplayLink = nil
        appliedWidth = 0
        baseWindowWidth = window.frame.width
        resizeGeneration = nil
        fullScreenTransition = false
        reconcileFullScreen = false
        observe(NSWindow.willEnterFullScreenNotification) { $0.beginFullScreenTransition() }
        observe(NSWindow.willExitFullScreenNotification) { $0.beginFullScreenTransition() }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     .easyPicFullScreenTransitionFailed] {
            observe(name) { sizer in sizer.fullScreenTransition = false; sizer.scheduleResize() }
        }
        observe(NSWindow.didResizeNotification) { $0.windowDidResize() }
        observeGlobal(NSApplication.didResignActiveNotification) { sizer in
            sizer.appActive = false
            sizer.resizeDisplayLink?.invalidate(); sizer.resizeDisplayLink = nil
            if sizer.resizeGeneration != nil, let window = sizer.window {
                window.setFrame(sizer.animationTarget, display: false, animate: false)
                window.contentMinSize.width = sizer.minimumWidth + sizer.appliedWidth
                sizer.resizeGeneration = nil
            }
        }
        observeGlobal(NSApplication.didBecomeActiveNotification) { sizer in
            sizer.appActive = true
            sizer.scheduleResize()
        }
        observe(NSWindow.willStartLiveResizeNotification) { sizer in
            // Give a manual resize control immediately, even if a panel was just opened.
            sizer.resizeDisplayLink?.invalidate(); sizer.resizeDisplayLink = nil
            sizer.resizeGeneration = nil
            sizer.windowDidResize()
        }
        observe(NSWindow.didEndLiveResizeNotification) { sizer in
            sizer.windowDidResize(); sizer.scheduleResize()
        }
        scheduleResize()
    }
    func update(sidebarWidth: CGFloat) {
        desiredWidth = sidebarWidth.isFinite ? max(0, sidebarWidth) : 0
        scheduleResize()
    }
    private func observe(_ name: Notification.Name, action: @escaping (SidebarWindowSizer) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }
    private func observeGlobal(_ name: Notification.Name, action: @escaping (SidebarWindowSizer) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }
    private func beginFullScreenTransition() {
        resizeDisplayLink?.invalidate(); resizeDisplayLink = nil
        fullScreenTransition = true
        reconcileFullScreen = true
        resizeGeneration = nil
        viewportWidth = nil
    }
    private func windowDidResize() {
        guard let window, !fullScreenTransition, !reconcileFullScreen,
              !window.styleMask.contains(.fullScreen), resizeGeneration == nil else { return }
        baseWindowWidth = window.frame.width - appliedWidth
        publishViewport()
    }
    private func publishViewport() {
        guard let window else { return }
        let chromeWidth = window.frame.width - window.contentLayoutRect.width
        let width = max(1, baseWindowWidth - chromeWidth - horizontalInset)
        if viewportWidth != width { viewportWidth = width }
    }
    private func scheduleResize() {
        guard !pendingResize else { return }
        pendingResize = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingResize = false
            self.resizeWindow()
        }
    }
    private func resizeWindow() {
        guard let window, !fullScreenTransition else { return }
        if window.styleMask.contains(.fullScreen) {
            // Fullscreen keeps the screen frame: SwiftUI divides its available space.
            window.contentMinSize.width = minimumWidth
            viewportWidth = nil
            return
        }
        guard !window.inLiveResize else { return }
        // The baseline changes only on real window resize notifications, never as a
        // side effect of SwiftUI measuring an inserted or removed panel.
        reconcileFullScreen = false
        publishViewport()
        if resizeGeneration != nil && abs(desiredWidth - appliedWidth) <= 0.5 { return }
        var frame = window.frame
        frame.size.width = baseWindowWidth + desiredWidth
        guard abs(desiredWidth - appliedWidth) > 0.5 || abs(frame.width - window.frame.width) > 0.5 else {
            window.contentMinSize.width = minimumWidth + desiredWidth
            return
        }
        // Keep the screen-space origin fixed, including when the right edge exceeds the display.
        resizeDisplayLink?.invalidate(); resizeDisplayLink = nil
        appliedWidth = desiredWidth
        let generation = UUID()
        resizeGeneration = generation
        // Do not let a new minimum force an early frame jump before the transition.
        window.contentMinSize.width = minimumWidth
        // Retarget from the viewport baseline, never from an intermediate animated frame.
        if !window.isVisible || !appActive || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(frame, display: true)
            window.contentMinSize.width = minimumWidth + appliedWidth
            resizeGeneration = nil
        } else {
            // Set real frames instead of NSWindow's animator proxy, which can animate
            // a scaled snapshot of the whole window (including the supposedly fixed image).
            animationStart = window.frame
            animationTarget = frame
            animationStartedAt = CACurrentMediaTime()
            let target = SidebarDisplayLinkTarget(owner: self)
            let link = window.displayLink(target: target, selector: #selector(SidebarDisplayLinkTarget.tick(_:)))
            let maximum = Float(max(1, window.screen?.maximumFramesPerSecond ?? 60))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            resizeDisplayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    fileprivate func advanceResize(_ link: CADisplayLink) {
        guard resizeDisplayLink === link, let window, let generation = resizeGeneration else {
            link.invalidate(); return
        }
        let progress = min(1, max(0, (link.targetTimestamp - animationStartedAt) / EasyPicMotion.panelDuration))
        let eased = 1 - pow(1 - progress, 3)
        var frame = animationStart
        frame.size.width += (animationTarget.width - animationStart.width) * eased
        // Let AppKit coalesce drawing with this display refresh instead of forcing a
        // synchronous redraw of the glass and image on every window-size update.
        window.setFrame(frame, display: false, animate: false)
        if progress >= 1 {
            link.invalidate(); resizeDisplayLink = nil
            window.contentMinSize.width = minimumWidth + appliedWidth
            DispatchQueue.main.async { [weak self] in
                guard self?.resizeGeneration == generation else { return }
                self?.resizeGeneration = nil
            }
        }
    }
}

@MainActor private final class SidebarDisplayLinkTarget: NSObject {
    weak var owner: SidebarWindowSizer?
    init(owner: SidebarWindowSizer) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.advanceResize(link) }
}
