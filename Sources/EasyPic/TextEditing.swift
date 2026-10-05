import SwiftUI
import AppKit
import EasyPicCore

extension EditorModel {
    func beginTextEditing() {
        guard canUseLayers else { return }
        if selectedLayer?.text != nil { editText(); return }
        if let existing = document?.layers.last(where: { $0.text != nil }) {
            selectedLayerID = existing.id; editText(); return
        }
        guard let doc = document else { return }
        startEditorSessionIfNeeded()
        var text = TextLayer(); text.content = ""
        text.fontSize = max(12, min(96, doc.size.width / 15))
        var layer = StickerLayer(resourceID: UUID(), name: L10n.text("文字"),
                                 center: CGPoint(x: doc.size.width / 2, y: doc.size.height / 2), size: text.naturalSize)
        layer.text = text
        sidePanel = .edit; activeEditorTool = .text; selectedLayerID = layer.id
        draftLayer = layer; textEditing = true
    }
    func addText() {
        if textEditing, !hasTextDraftChanges, let draftLayer,
           document?.layers.contains(where: { $0.id == draftLayer.id }) == false {
            textEditing = false; self.draftLayer = nil; previewTask?.cancel()
        }
        guard canUseLayers, var doc = document else { return }
        startEditorSessionIfNeeded()
        sidePanel = .edit; activeEditorTool = .text
        var layer = StickerLayer(resourceID: UUID(), name: L10n.text("文字"), center: CGPoint(x: doc.size.width / 2, y: doc.size.height / 2), size: CGSize(width: 1, height: 1))
        var text = TextLayer(); text.fontSize = max(12, min(96, doc.size.width / 15)); layer.text = text
        layer.size = text.naturalSize
        doc.layers.append(layer); selectedLayerID = layer.id
        pendingEditorAction = { [weak self] in self?.editText() }
        commitDocument(doc)
    }
    func cancelTextEditing() {
        textEditing = false; draftLayer = nil; previewTask?.cancel()
        if let history = documentHistory { renderDocument(history) }
    }
    func editText() {
        guard canUseLayers, let layer = selectedLayer, layer.text != nil else { return }
        startEditorSessionIfNeeded()
        sidePanel = .edit; activeEditorTool = .text; draftLayer = layer; textEditing = true
    }
}

struct InlineTextEditor: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    @State var layer: StickerLayer
    @FocusState private var contentFocused: Bool
    private var text: TextLayer { layer.text ?? TextLayer() }
    private func binding<T>(_ key: WritableKeyPath<TextLayer, T>) -> Binding<T> {
        Binding(get: { text[keyPath: key] }, set: { value in
            var next = text; next[keyPath: key] = value
            layer.text = next
            layer.size = next.naturalSize
            model.updateLayer(layer, commit: false)
        })
    }
    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: binding(\.content)).focused($contentFocused)
                .scrollContentBackground(.hidden).scrollIndicators(.hidden)
                .padding(6).frame(height: 110)
                .glassSurface(.input, radius: 12, selected: contentFocused)
            EasyPicFontButton(selection: binding(\.fontName))
            number(L10n.text("字号"), \.fontSize, 1...4096)
            HStack(spacing: 6) {
                Toggle(isOn: binding(\.bold)) {
                    Text("B").font(.system(size: 15, weight: .bold, design: .serif)).frame(width: 24, height: 22)
                }.toggleStyle(GlassToggleStyle(isButton: true)).quickHelp(L10n.text("粗体")).accessibilityLabel(L10n.text("粗体"))
                Toggle(isOn: binding(\.italic)) {
                    Text("I").font(.system(size: 15, weight: .bold, design: .serif).italic()).frame(width: 24, height: 22)
                }.toggleStyle(GlassToggleStyle(isButton: true)).quickHelp(L10n.text("斜体")).accessibilityLabel(L10n.text("斜体"))
            }
            color(L10n.text("文字颜色"), \.color)
            HStack(spacing: 2) {
                ForEach(TextAlignmentControl.allCases) { control in
                    Button {
                        var next = text
                        if let horizontal = control.horizontal {
                            next.vertical = false
                            next.alignment = horizontal
                            next.verticalAlignment = .top
                        } else if let vertical = control.vertical {
                            next.vertical = true
                            next.alignment = .right
                            next.verticalAlignment = vertical
                        }
                        layer.text = next; layer.size = next.naturalSize
                        model.updateLayer(layer, commit: false)
                    } label: {
                        TextAlignmentIcon(control: control)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .foregroundStyle(control.isSelected(in: text) ? EasyPicGlass.accent : .primary)
                    }
                    .buttonStyle(GlassButtonStyle(selected: control.isSelected(in: text), radius: 6,
                                                  horizontalPadding: 0, verticalPadding: 0)).quickHelp(control.title).accessibilityLabel(control.title)
                    .accessibilityAddTraits(control.isSelected(in: text) ? .isSelected : [])
                }
            }
            .padding(3).frame(maxWidth: .infinity)
            .glassSurface(.input, radius: 9)
            .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("对齐"))
            number(L10n.text("字距"), \.letterSpacing, -100...1000)
            number(L10n.text("行距"), \.lineSpacing, 0...1000)
            Divider()
            color(L10n.text("描边颜色"), \.strokeColor); number(L10n.text("描边宽度"), \.strokeWidth, 0...200)
            color(L10n.text("阴影颜色"), \.shadowColor)
            number(L10n.text("阴影 X"), \.shadowX, -1000...1000); number(L10n.text("阴影 Y"), \.shadowY, -1000...1000)
            number(L10n.text("阴影模糊"), \.shadowBlur, 0...500)
            Divider()
            color(L10n.text("背景颜色"), \.backgroundColor)
            number(L10n.text("背景内边距"), \.padding, 0...1000)
            number(L10n.text("圆角半径 px"), \.cornerRadius, 0...1000, step: 5)
        }
        .onAppear { contentFocused = true }
        .onChange(of: model.draftLayer) { _, draft in
            if let draft, draft.id == layer.id { layer = draft }
        }
    }
    private func number(_ title: String, _ key: WritableKeyPath<TextLayer, Double>, _ range: ClosedRange<Double>, step: Double = 1) -> some View {
        NumericValueControl(title: title, value: binding(key), range: range, step: step)
    }
    private func color(_ title: String, _ key: WritableKeyPath<TextLayer, TextColor>) -> some View {
        EasyPicColorButton(title: title, selection: binding(key), alignWithNumericInput: true)
    }
}

private enum TextAlignmentControl: CaseIterable, Identifiable {
    case left, horizontalCenter, right, top, verticalCenter, bottom
    var id: Self { self }
    var horizontal: EasyPicCore.TextAlignment? {
        switch self {
        case .left: return .left
        case .horizontalCenter: return .center
        case .right: return .right
        default: return nil
        }
    }
    var vertical: TextVerticalAlignment? {
        switch self {
        case .top: return .top
        case .verticalCenter: return .center
        case .bottom: return .bottom
        default: return nil
        }
    }
    var title: String {
        switch self {
        case .left: return L10n.text("横向左对齐")
        case .horizontalCenter: return L10n.text("横向居中对齐")
        case .right: return L10n.text("横向右对齐")
        case .top: return L10n.text("纵向上对齐")
        case .verticalCenter: return L10n.text("纵向居中对齐")
        case .bottom: return L10n.text("纵向下对齐")
        }
    }
    func isSelected(in text: TextLayer) -> Bool {
        if let horizontal { return !text.vertical && text.alignment == horizontal }
        return text.vertical && text.resolvedVerticalAlignment == vertical
    }
}

private struct TextAlignmentIcon: View {
    let control: TextAlignmentControl
    var body: some View {
        Canvas { context, _ in
            var path = Path()
            for index in 0..<3 {
                let length: CGFloat = index == 2 ? 9 : 18
                let start: CGPoint
                let end: CGPoint
                if let horizontal = control.horizontal {
                    let x: CGFloat = horizontal == .left ? 1 : (horizontal == .center ? (20 - length) / 2 : 19 - length)
                    let y = CGFloat(4 + index * 6)
                    start = CGPoint(x: x, y: y); end = CGPoint(x: x + length, y: y)
                } else {
                    let x = CGFloat(4 + index * 6)
                    let y: CGFloat = control == .top ? 1 : (control == .verticalCenter ? (20 - length) / 2 : 19 - length)
                    start = CGPoint(x: x, y: y); end = CGPoint(x: x, y: y + length)
                }
                path.move(to: start); path.addLine(to: end)
            }
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .frame(width: 20, height: 20).accessibilityHidden(true)
    }
}
