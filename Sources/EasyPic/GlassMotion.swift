import AppKit
import SwiftUI
import QuartzCore

/// Presentation-only motion. Window sizing and document updates keep their own timing.
enum EasyPicMotion {
    static let panelDuration = 0.16
    static let popupDuration = 0.20
    static let dismissalDuration = 0.16

    static func panelAnimation(reduced: Bool) -> Animation? {
        reduced ? nil : .timingCurve(0.22, 0.80, 0.25, 1, duration: panelDuration)
    }
    static func popupAnimation(reduced: Bool) -> Animation {
        .easeOut(duration: reduced ? 0.10 : popupDuration)
    }
    static func sidebarTransition(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .asymmetric(
            insertion: .offset(x: 14).combined(with: .opacity),
            removal: .offset(x: 8).combined(with: .opacity))
    }
    static func popupTransition(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .scale(scale: 0.97).combined(with: .opacity)
    }
}

extension View {
    func glassEntrance() -> some View { modifier(GlassEntranceModifier()) }
    func glassPopupTransition() -> some View { modifier(GlassPopupTransitionModifier()) }
}

private struct GlassEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
            .scaleEffect(reduceMotion || visible ? 1 : 0.98)
            .onAppear { withAnimation(EasyPicMotion.popupAnimation(reduced: reduceMotion)) { visible = true } }
            .onDisappear { visible = false }
    }
}
private struct GlassPopupTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.transition(EasyPicMotion.popupTransition(reduced: reduceMotion))
    }
}

/// Fade utility panels without moving their frames or delaying their model actions.
@MainActor enum GlassWindowMotion {
    private static var generations: [ObjectIdentifier: UUID] = [:]

    static func present(_ window: NSWindow, key: Bool = true, duration: Double = EasyPicMotion.popupDuration) {
        let identifier = ObjectIdentifier(window), generation = UUID()
        generations[identifier] = generation
        if !window.isVisible { window.alphaValue = 0 }
        if key { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        animate(window, to: 1, duration: duration) {
            guard generations[identifier] == generation else { return }
            generations.removeValue(forKey: identifier)
        }
    }
    static func dismiss(_ window: NSWindow, duration: Double = EasyPicMotion.dismissalDuration) {
        let identifier = ObjectIdentifier(window), generation = UUID()
        generations[identifier] = generation
        guard window.isVisible else { generations.removeValue(forKey: identifier); return }
        animate(window, to: 0, duration: duration) {
            // A rapidly reopened panel must not be hidden by an older fade completion.
            guard generations[identifier] == generation else { return }
            window.orderOut(nil); window.alphaValue = 1
            generations.removeValue(forKey: identifier)
        }
    }
    private static func animate(_ window: NSWindow, to alpha: CGFloat, duration: Double,
                                completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? min(0.10, duration) : duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion() }
        }
    }
}

final class AnimatedGlassUtilityPanel: NSPanel {
    override func close() { GlassWindowMotion.dismiss(self) }
}
