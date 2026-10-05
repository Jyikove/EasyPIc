import SwiftUI
import EasyPicCore

struct EasyPicFontButton: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @Binding var selection: String
    @State private var presented = false
    private var name: String { TextFontCatalog.fonts.first { $0.postScriptName == selection }?.name ?? selection }

    var body: some View {
        let _ = languageSettings.language
        HStack {
            Text(L10n.text("字体"))
            Spacer(minLength: 4)
            Button { presented.toggle() } label: {
                Text(name).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, minHeight: 22)
            }
            .buttonStyle(GlassButtonStyle())
            .quickHelp(L10n.text("选择字体"))
            .accessibilityLabel(L10n.text("选择字体"))
            .popover(isPresented: $presented, arrowEdge: .leading) {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(TextFontCatalog.fonts) { font in
                            Button {
                                selection = font.postScriptName
                                presented = false
                            } label: {
                                HStack(spacing: 12) {
                                    Text(font.name).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text("Font").font(.custom(font.postScriptName, size: 24))
                                        .foregroundStyle(.primary)
                                    Image(systemName: "checkmark").font(.system(size: 11))
                                        .opacity(selection == font.postScriptName ? 1 : 0)
                                }
                                .padding(.horizontal, 10).frame(height: 42)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(GlassButtonStyle(selected: selection == font.postScriptName, radius: 8, horizontalPadding: 0, verticalPadding: 0))
                            .accessibilityLabel(font.name)
                            .accessibilityAddTraits(selection == font.postScriptName ? .isSelected : [])
                        }
                    }
                }
                .frame(width: 280, height: min(420, CGFloat(TextFontCatalog.fonts.count) * 46))
                .padding(12).glassPopover(radius: 18)
            }
        }
    }
}
