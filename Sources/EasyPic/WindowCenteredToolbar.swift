import SwiftUI
import AppKit

/// NSToolbar's principal item can be pushed aside by leading navigation items.
/// Anchor the actual capsule to the window midpoint, independently of that layout.
struct WindowCenteredToolbar<Content: View>: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    let hitWidth: CGFloat
    let content: Content
    init(width: CGFloat, height: CGFloat, hitWidth: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width; self.height = height; self.hitWidth = hitWidth; self.content = content()
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
        private var width: CGFloat
        private var height: CGFloat
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        init(_ parent: WindowCenteredToolbar) {
            width = parent.width; height = parent.height
            host = CenteredToolbarHost(rootView: parent.content)
            host.identifier = NSUserInterfaceItemIdentifier("EasyPic.CenteredToolbar")
            host.activeWidth = parent.hitWidth
            host.sizingOptions = []
            host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
            host.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        }
        func update(_ parent: WindowCenteredToolbar) {
            host.rootView = parent.content; host.activeWidth = parent.hitWidth
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
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            host.removeFromSuperview(); window = nil
        }
        private func position() {
            guard let window, let close = window.standardWindowButton(.closeButton), var container = close.superview else { return }
            // Use a full-width titlebar ancestor; a traffic-light-only wrapper
            // would otherwise clip both drawing and hit testing outside its bounds.
            while container.bounds.width < window.frame.width - 4, let parent = container.superview { container = parent }
            if host.superview !== container {
                container.addSubview(host, positioned: .above, relativeTo: nil)
            }
            let center = container.convert(CGPoint(x: window.frame.width / 2, y: 0), from: nil)
            let traffic = close.convert(close.bounds, to: container)
            let frame = CGRect(x: center.x - width / 2, y: traffic.midY - height / 2, width: width, height: height)
            if host.frame != frame { host.frame = frame }
        }
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
