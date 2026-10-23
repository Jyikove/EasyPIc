import SwiftUI

/// SF Symbols can substitute localized glyphs (for example A → 文).
/// Keep functional artwork stable while the surrounding labels are translated.
struct FunctionIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.layoutDirection, .leftToRight)
    }
}

extension Label where Title == Text, Icon == FunctionIcon {
    init(_ title: String, functionIcon name: String) {
        self.init { Text(title) } icon: { FunctionIcon(systemName: name) }
    }
}
