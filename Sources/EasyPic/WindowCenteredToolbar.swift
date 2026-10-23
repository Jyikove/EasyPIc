import SwiftUI
import AppKit

/// Budget navigation from its actual titlebar origin to the centered capsule.
/// Both hosts share the same native coordinate system, including during resize.
struct TitlebarNavigationLayout: Equatable {
    let collapsed: Bool
    let filenameWidth: CGFloat
    let width: CGFloat
    init(availableWidth: CGFloat, hasFilename: Bool) {
        let available = max(0, availableWidth)
        let buttonsWidth: CGFloat = 3 * 28 + 2 * 12 + 2 * 3
        collapsed = available < buttonsWidth
        filenameWidth = !collapsed && hasFilename ? min(180, max(0, available - buttonsWidth - 28)) : 0
        width = collapsed ? min(28, available) : buttonsWidth + (filenameWidth > 0 ? filenameWidth + 28 : 0)
    }
}

struct WindowCenteredToolbar<Content: View, Navigation: View>: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    let hitWidth: CGFloat
    let showsNavigation: Bool
    let hasFilename: Bool
    let navigation: (TitlebarNavigationLayout) -> Navigation
    let content: Content
    init(width: CGFloat, height: CGFloat, hitWidth: CGFloat, showsNavigation: Bool, hasFilename: Bool,
         @ViewBuilder navigation: @escaping (TitlebarNavigationLayout) -> Navigation,
         @ViewBuilder content: () -> Content) {
        self.width = width; self.height = height; self.hitWidth = hitWidth; self.content = content()
        self.showsNavigation = showsNavigation; self.hasFilename = hasFilename; self.navigation = navigation
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ToolbarWindowAttachment {
        let view = ToolbarWindowAttachment()
        view.attach = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateNSView(_ view: ToolbarWindowAttachment, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ view: ToolbarWindowAttachment, coordinator: Coordinator) { coordinator.detach() }

    final class Coordinator {
        private let host: CenteredToolbarHost<Content>
        private let navigationHost: LeadingToolbarHost<Navigation>
        private var navigation: (TitlebarNavigationLayout) -> Navigation
        private var showsNavigation: Bool
        private var hasFilename: Bool
        private var navigationLayout: TitlebarNavigationLayout?
        private var navigationRestore: DispatchWorkItem?
        private var width: CGFloat
        private var height: CGFloat
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        init(_ parent: WindowCenteredToolbar) {
            width = parent.width; height = parent.height
            navigation = parent.navigation; showsNavigation = parent.showsNavigation; hasFilename = parent.hasFilename
            host = CenteredToolbarHost(rootView: parent.content)
            navigationHost = LeadingToolbarHost(rootView: parent.navigation(.init(availableWidth: 0, hasFilename: parent.hasFilename)))
            navigationHost.identifier = NSUserInterfaceItemIdentifier("EasyPic.NavigationToolbar")
            navigationHost.sizingOptions = []
            navigationHost.wantsLayer = true; navigationHost.layer?.backgroundColor = NSColor.clear.cgColor
            host.identifier = NSUserInterfaceItemIdentifier("EasyPic.CenteredToolbar")
            host.activeWidth = parent.hitWidth
            host.sizingOptions = []
            host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
            host.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        }
        func update(_ parent: WindowCenteredToolbar) {
            let restoringNavigation = !showsNavigation && parent.showsNavigation
            host.rootView = parent.content; host.activeWidth = parent.hitWidth
            navigation = parent.navigation; showsNavigation = parent.showsNavigation; hasFilename = parent.hasFilename
            if !showsNavigation {
                navigationRestore?.cancel(); navigationRestore = nil
                navigationHost.rootView = navigation(.init(availableWidth: 0, hasFilename: hasFilename))
            } else if restoringNavigation {
                // Restore after the wider editing capsule finishes retracting.
                let restore = DispatchWorkItem { [weak self] in
                    self?.navigationRestore = nil; self?.position()
                }
                navigationRestore = restore
                DispatchQueue.main.asyncAfter(deadline: .now() + EasyPicMotion.panelDuration + 0.02, execute: restore)
            }
            navigationLayout = nil
            width = parent.width; height = parent.height; position()
        }
        func attach(_ window: NSWindow?) {
            guard let window else { detach(); return }
            guard self.window !== window else { position(); return }
            detach(); self.window = window
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.position() }
                })
            }
            position()
        }
        func detach() {
            navigationRestore?.cancel(); navigationRestore = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            host.removeFromSuperview(); navigationHost.removeFromSuperview(); window = nil
            navigationLayout = nil
        }
        private func position() {
            guard let window, let close = window.standardWindowButton(.closeButton), var container = close.superview else { return }
            // Use a full-width titlebar ancestor; a traffic-light-only wrapper
            // would otherwise clip both drawing and hit testing outside its bounds.
            while container.bounds.width < window.frame.width - 4, let parent = container.superview { container = parent }
            if host.superview !== container {
                container.addSubview(host, positioned: .above, relativeTo: nil)
            }
            if navigationHost.superview !== container {
                container.addSubview(navigationHost, positioned: .above, relativeTo: nil)
            }
            let center = container.convert(CGPoint(x: window.frame.width / 2, y: 0), from: nil)
            let traffic = close.convert(close.bounds, to: container)
            let frame = CGRect(x: center.x - width / 2, y: traffic.midY - height / 2, width: width, height: height)
            if host.frame != frame { host.frame = frame }
            // Hide immediately before Edit expands; no disabled navigation placeholder.
            navigationHost.isHidden = !showsNavigation || navigationRestore != nil
            guard !navigationHost.isHidden else { return }
            let trafficRight = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
                .filter { !$0.isHidden }
                .map { $0.convert($0.bounds, to: container).maxX }.max() ?? traffic.maxX
            let leading = trafficRight + 12
            let layout = TitlebarNavigationLayout(availableWidth: center.x - host.activeWidth / 2 - 12 - leading,
                                                 hasFilename: hasFilename)
            if navigationLayout != layout {
                navigationHost.rootView = navigation(layout); navigationLayout = layout
            }
            let navigationFrame = CGRect(x: leading, y: traffic.midY - height / 2, width: layout.width, height: height)
            if navigationHost.frame != navigationFrame { navigationHost.frame = navigationFrame }
        }
    }
}

final class LeadingToolbarHost<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

final class ToolbarWindowAttachment: NSView {
    var attach: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach?(window) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class CenteredToolbarHost<Content: View>: NSHostingView<Content> {
    var activeWidth: CGFloat = 0
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let active = CGRect(x: (bounds.width - activeWidth) / 2, y: 0, width: activeWidth, height: bounds.height)
        return active.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }
}
