import SwiftUI
import AppKit

extension View {
    func quickHelp(_ text: String) -> some View {
        modifier(QuickHelpModifier(text: text))
    }
}

private struct QuickHelpModifier: ViewModifier {
    let text: String
    @State private var identifier = UUID()

    func body(content: Content) -> some View {
        content.contentShape(Rectangle())
            .accessibilityHint(text)
            .onHover { hovering in
                if hovering { QuickHelpPresenter.shared.show(text, owner: identifier) }
                else { QuickHelpPresenter.shared.hide(owner: identifier) }
            }
            .simultaneousGesture(TapGesture().onEnded { QuickHelpPresenter.shared.hide(owner: identifier) })
            .onChange(of: text) { _, text in QuickHelpPresenter.shared.update(text, owner: identifier) }
            .onDisappear { QuickHelpPresenter.shared.hide(owner: identifier) }
    }
}

@MainActor
private final class QuickHelpPresenter {
    static let shared = QuickHelpPresenter()
    private var panel: NSPanel?
    private var task: Task<Void, Never>?
    private var owner: UUID?
    private var text = ""

    func show(_ text: String, owner: UUID) {
        task?.cancel()
        if let panel { GlassWindowMotion.dismiss(panel, duration: 0.08) }
        self.owner = owner; self.text = text
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            guard let self, self.owner == owner, NSApp.isActive else { return }
            present()
        }
    }

    func hide(owner: UUID) {
        guard self.owner == owner else { return }
        task?.cancel(); task = nil; self.owner = nil
        if let panel { GlassWindowMotion.dismiss(panel, duration: 0.08) }
    }

    func update(_ text: String, owner: UUID) {
        guard self.owner == owner else { return }
        self.text = text
        if panel?.isVisible == true { present() }
    }

    private func present() {
        let panel = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        self.panel = panel
        panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear
        // A rectangular window shadow plus a clipped glass shadow leaves dark
        // right-angle remnants at the lower corners. Draw one padded round shadow.
        panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        let host = QuickHelpHostingView(rootView: QuickHelpBubble(text: text))
        host.wantsLayer = true; host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        let size = host.fittingSize
        panel.contentView = host; panel.setContentSize(size)
        let pointer = NSEvent.mouseLocation
        let bounds = NSScreen.screens.first(where: { $0.frame.contains(pointer) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(pointer.x + 12, bounds.minX + 6), bounds.maxX - size.width - 6)
        var y = pointer.y - size.height - 16
        if y < bounds.minY + 6 { y = pointer.y + 20 }
        panel.setFrameOrigin(CGPoint(x: x, y: min(y, bounds.maxY - size.height - 6)))
        GlassWindowMotion.present(panel, key: false, duration: 0.10)
    }
}

private struct QuickHelpBubble: View {
    let text: String
    private var width: CGFloat {
        min(290, ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width) + 20)
    }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(width: width, alignment: .leading)
            .glassSurface(.panel, radius: 8)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .compositingGroup()
            .shadow(color: .black.opacity(0.20), radius: 4, y: 2)
            .padding(10)
            .preferredColorScheme(.dark)
    }
}

private final class QuickHelpHostingView: NSHostingView<QuickHelpBubble> {
    override var isOpaque: Bool { false }
}
