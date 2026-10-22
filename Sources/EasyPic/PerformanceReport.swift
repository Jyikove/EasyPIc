import AppKit
import EasyPicCore

@MainActor enum PerformanceReport {
    static func export() {
        let panel = NSSavePanel(); EasyPicGlass.prepareFilePanel(panel)
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "EasyPic-Performance.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try InteractionMetrics.shared.report().write(to: url, options: .atomic) }
            catch { NSApp.presentError(error) }
        }
    }
}
