import AppKit
import SwiftUI
import EasyPicCore

final class GlassBackdropView: NSView {
    private let frost = NSVisualEffectView()
    private let blueWash = NSView()
    private let glass = NSGlassEffectView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        frost.material = .underWindowBackground; frost.blendingMode = .behindWindow; frost.state = .active
        frost.alphaValue = 0.08
        blueWash.wantsLayer = true
        glass.style = .clear; glass.cornerRadius = 14
        glass.tintColor = NSColor(calibratedRed: 0.35, green: 0.66, blue: 1, alpha: 0.10)
        for child in [frost, blueWash, glass] {
            child.frame = bounds; child.autoresizingMask = [.width, .height]; addSubview(child)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func install(in window: NSWindow, reducedTransparency: Bool) {
        window.isOpaque = false; window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        if window.animationBehavior == .default { window.animationBehavior = .utilityWindow }
        if let backdrop = window.contentView as? GlassBackdropView {
            backdrop.setReducedTransparency(reducedTransparency)
            return
        }
        guard let content = window.contentView else { return }
        let backdrop = GlassBackdropView(frame: content.frame)
        backdrop.setReducedTransparency(reducedTransparency)
        window.contentView = backdrop
        // Native glass guarantees the foreground's ordering through contentView.
        content.frame = backdrop.bounds
        content.autoresizingMask = [.width, .height]
        backdrop.glass.contentView = content
    }
    func setReducedTransparency(_ reduced: Bool) {
        blueWash.layer?.backgroundColor = NSColor(calibratedRed: 0.30, green: 0.61, blue: 0.98, alpha: reduced ? 1 : 0.22).cgColor
        glass.style = reduced ? .regular : .clear
        frost.isHidden = reduced
    }
}

private final class GlassModalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor enum GlassUtilityPresenter {
    private static var aboutPanel: NSPanel?
    static func askToLeave(title: String, message: String, saveTitle: String) -> NSApplication.ModalResponse {
        let panel = GlassModalPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        let root = GlassDialog(title: title, message: message) {
            VStack(spacing: 8) {
                Button(saveTitle) { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
                    .buttonStyle(GlassButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                Button(L10n.text("放弃修改")) { NSApp.stopModal(withCode: .alertSecondButtonReturn) }
                    .buttonStyle(GlassButtonStyle(destructive: true))
                Button(L10n.text("取消")) { NSApp.stopModal(withCode: .alertThirdButtonReturn) }
                    .buttonStyle(GlassButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }.glassEntrance().environmentObject(AppLanguageSettings.shared)
        let host = NSHostingView(rootView: root)
        panel.contentView = host; panel.setContentSize(host.fittingSize)
        GlassBackdropView.install(in: panel, reducedTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        if let parent = NSApp.keyWindow {
            panel.setFrameOrigin(CGPoint(x: parent.frame.midX - panel.frame.width / 2,
                                         y: parent.frame.midY - panel.frame.height / 2))
        } else { panel.center() }
        GlassWindowMotion.present(panel)
        let response = NSApp.runModal(for: panel)
        GlassWindowMotion.dismiss(panel)
        return response
    }
    static func showAbout() {
        if let panel = aboutPanel { GlassWindowMotion.present(panel); return }
        let panel = AnimatedGlassUtilityPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.appearance = NSAppearance(named: .darkAqua)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let icon = Bundle.main.url(forResource: "EasyPicIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
        let root = VStack(spacing: 12) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 90, height: 90) }
            Text("EasyPic").font(.system(size: 24, weight: .semibold))
            Text(version).font(.system(size: 12)).foregroundStyle(.secondary)
            Button(L10n.text("好")) { GlassWindowMotion.dismiss(panel) }
                .buttonStyle(GlassButtonStyle()).keyboardShortcut(.defaultAction)
        }
        .padding(32).frame(width: 320, height: 300)
        .glassWindowBackground()
        .glassEntrance()
        .environmentObject(AppLanguageSettings.shared)
        panel.contentView = NSHostingView(rootView: root)
        panel.center(); GlassWindowMotion.present(panel)
        aboutPanel = panel
    }
}
