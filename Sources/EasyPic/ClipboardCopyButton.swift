import SwiftUI
import AppKit
import EasyPicCore

struct ClipboardCopyButton: View {
    let text: String
    let title: String
    var copied: () -> Void = {}
    @State private var success = false
    @State private var feedbackID = UUID()
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else { return }
            copied(); success = true
            let id = UUID(); feedbackID = id
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                if feedbackID == id { success = false }
            }
        } label: {
            FunctionIcon(systemName: success ? "checkmark" : "doc.on.doc").frame(width: 14, height: 14)
                .foregroundStyle(success ? EasyPicGlass.accent : .primary)
        }
        .quickHelp(success ? L10n.text("已复制") : title)
        .accessibilityLabel(success ? L10n.text("已复制") : title)
        .overlay(alignment: .topTrailing) {
            if success {
                Text(L10n.text("已复制")).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .glassSurface(.control, radius: 7, selected: true)
                    .fixedSize().offset(y: -29).allowsHitTesting(false)
            }
        }
    }
}
