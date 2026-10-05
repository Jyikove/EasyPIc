import SwiftUI
import EasyPicCore

struct LanguageSettingsView: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("界面语言")).font(.headline)
            GlassSegmentedPicker(selection: $languageSettings.language,
                                 options: AppLanguage.allCases.map { ($0.name, $0) })
                .accessibilityLabel(L10n.text("语言"))
            Text(L10n.text("重新启动 EasyPic 后，系统菜单和文件选择窗口也会使用所选语言。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 340)
        .glassWindowBackground()
        .glassEntrance()
        .navigationTitle(L10n.text("设置"))
    }
}
