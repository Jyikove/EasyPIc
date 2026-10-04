import SwiftUI
import AppKit
import EasyPicCore

extension EditorModel {
    func addText() {
        guard canUseLayers, var doc = document else { return }
        var layer = StickerLayer(resourceID: UUID(), name: "文字", center: CGPoint(x: doc.size.width / 2, y: doc.size.height / 2), size: CGSize(width: 1, height: 1))
        var text = TextLayer(); text.fontSize = max(12, min(96, doc.size.width / 15)); layer.text = text
        layer.size = text.naturalSize
        doc.layers.append(layer); selectedLayerID = layer.id; commitDocument(doc)
    }
    func cancelTextEditing() {
        textEditing = false; draftLayer = nil; previewTask?.cancel()
        if let history = documentHistory { renderDocument(history) }
    }
    func editText() {
        guard canUseLayers, selectedLayer?.text != nil else { return }; textEditing = true
    }
}

struct TextEditorSheet: View {
    @ObservedObject var model: EditorModel
    @State var layer: StickerLayer
    @State private var fonts = NSFontManager.shared.availableFonts.sorted()
    @State private var fontBridge = TextFontBridge()
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
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑文字").font(.title2)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading) {
                    TextEditor(text: binding(\.content)).focused($contentFocused).frame(width: 300, height: 250)
                    Text("画布同步预览；点击应用将本次文字修改记为一个撤销步骤。").font(.caption).foregroundStyle(.secondary)
                }.frame(width: 300)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("字体", selection: binding(\.fontName)) {
                            ForEach(fonts, id: \.self) { name in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                                    Text(text.content.isEmpty ? "预览文字" : text.content)
                                        .font(.custom(name, size: 18))
                                        .lineLimit(1)
                                }.tag(name)
                            }
                        }
                        Button("系统字体面板…") {
                            fontBridge.changed = { name, size in
                                var next = text; next.fontName = name; next.fontSize = size; layer.text = next
                                layer.size = next.naturalSize
                                model.updateLayer(layer, commit: false)
                            }
                            NSFontManager.shared.target = fontBridge
                            NSFontManager.shared.setSelectedFont(NSFont(name: text.fontName, size: text.fontSize) ?? .systemFont(ofSize: text.fontSize), isMultiple: false)
                            NSFontManager.shared.orderFrontFontPanel(nil)
                        }
                        number("字号", \.fontSize, 1...4096)
                        Slider(value: binding(\.fontSize), in: 8...max(200, text.fontSize))
                        HStack { Toggle("粗体", isOn: binding(\.bold)); Toggle("斜体", isOn: binding(\.italic)) }
                        if text.unavailableTraits { Text("当前字体缺少所选粗体或斜体字形，将使用原始字形。").font(.caption).foregroundStyle(.orange) }
                        color("文字颜色", \.color)
                        Picker("对齐", selection: binding(\.alignment)) { Text("左 / 起始").tag(EasyPicCore.TextAlignment.left); Text("居中").tag(EasyPicCore.TextAlignment.center); Text("右 / 末尾").tag(EasyPicCore.TextAlignment.right) }
                        Toggle("竖排（列从右向左）", isOn: binding(\.vertical))
                        number("字距", \.letterSpacing, -100...1000)
                        number("行距", \.lineSpacing, 0...1000)
                        Divider()
                        color("描边颜色", \.strokeColor); number("描边宽度", \.strokeWidth, 0...200)
                        color("阴影颜色", \.shadowColor)
                        number("阴影 X", \.shadowX, -1000...1000); number("阴影 Y", \.shadowY, -1000...1000)
                        number("阴影模糊", \.shadowBlur, 0...500)
                        Divider()
                        color("背景颜色", \.backgroundColor)
                        number("背景内边距", \.padding, 0...1000); number("背景圆角", \.cornerRadius, 0...1000)
                    }.padding(4)
                }.frame(width: 320, height: 420)
            }
            HStack {
                Button("取消") { model.cancelTextEditing() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("应用") {
                    layer.name = String(text.content.prefix(24)).replacingOccurrences(of: "\n", with: " ")
                    if layer.name.isEmpty { layer.name = "文字" }
                    model.textEditing = false; model.updateLayer(layer, commit: true)
                }.keyboardShortcut(.defaultAction).disabled(!text.isValid)
            }
        }
        .padding(24).frame(width: 690).onAppear { contentFocused = true }
        .onDisappear { NSFontManager.shared.target = nil; fontBridge.changed = nil; NSFontPanel.shared.orderOut(nil) }
        .interactiveDismissDisabled()
    }
    private func number(_ title: String, _ key: WritableKeyPath<TextLayer, Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title); Spacer()
            TextField(title, value: Binding(get: { text[keyPath: key] }, set: { value in
                guard value.isFinite else { return }; binding(key).wrappedValue = min(range.upperBound, max(range.lowerBound, value))
            }), format: .number).frame(width: 90).textFieldStyle(.roundedBorder)
        }
    }
    private func color(_ title: String, _ key: WritableKeyPath<TextLayer, TextColor>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(cgColor: text[keyPath: key].cgColor) }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            binding(key).wrappedValue = TextColor(rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
        }), supportsOpacity: true)
    }
}

@MainActor final class TextFontBridge: NSObject {
    var changed: ((String, Double) -> Void)?
    @objc func changeFont(_ sender: NSFontManager) {
        let font = sender.convert(sender.selectedFont ?? .systemFont(ofSize: 48))
        changed?(font.fontName, font.pointSize)
    }
}
