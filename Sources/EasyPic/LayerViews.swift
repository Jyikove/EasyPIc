import SwiftUI
import EasyPicCore

enum LayerInspectorFilter {
    case all, sticker, text
    func includes(_ layer: StickerLayer) -> Bool {
        switch self {
        case .all: return true
        case .sticker: return layer.text == nil
        case .text: return layer.text != nil
        }
    }
}

struct LayerInspector: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    var showsInsertionButtons = true
    var fullWidthActions = false
    var filter: LayerInspectorFilter = .all
    var showsLayerProperties = true
    @State private var listHeight: CGFloat = 0
    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .leading, spacing: 10) {
            if showsInsertionButtons {
                Button(action: model.importSticker) { Label(L10n.text("添加图片贴纸…"), systemImage: "plus.square.on.square") }.buttonStyle(GlassButtonStyle())
                Button(action: model.addText) { Label(L10n.text("添加文字"), systemImage: "textformat") }.buttonStyle(GlassButtonStyle())
            }
            Button(action: model.mergeAllLayers) {
                Label(L10n.text("合并图层"), systemImage: "square.stack.3d.up")
                    .frame(maxWidth: fullWidthActions ? .infinity : nil, alignment: .center)
            }
                .buttonStyle(GlassButtonStyle())
                .disabled(!model.canMergeAll)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(Array((model.document?.layers ?? []).filter { filter.includes($0) }.reversed())) { layer in
                        HStack {
                            Button { model.selectedLayerID = layer.id; model.layerAction("visibility") } label: { Image(systemName: layer.visible ? "eye" : "eye.slash").frame(width: 20, height: 20) }
                                .buttonStyle(GlassButtonStyle(radius: 6, horizontalPadding: 0, verticalPadding: 0))
                            Button { model.selectedLayerID = layer.id } label: {
                                Text(filter == .all ? L10n.layerName(layer.name) : L10n.text(layer.text == nil ? "贴纸" : "文字"))
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(GlassButtonStyle(selected: model.selectedLayerID == layer.id, radius: 6,
                                                            horizontalPadding: 4, verticalPadding: 2))
                        }
                        .padding(4).glassSurface(.input, radius: 8, selected: model.selectedLayerID == layer.id)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }.frame(height: min(100, listHeight)).disabled(!model.canUseLayers)
            if showsLayerProperties, let layer = model.selectedLayer, filter.includes(layer) {
                if layer.text != nil {
                    Button(action: model.editText) {
                        Text(L10n.text("编辑文字…")).frame(maxWidth: fullWidthActions ? .infinity : nil, alignment: .center)
                    }.buttonStyle(GlassButtonStyle())
                }
                numeric(L10n.text("中心 X"), value: layer.center.x) { $0.center.x = $1 }
                numeric(L10n.text("中心 Y"), value: layer.center.y) { $0.center.y = $1 }
                numeric(L10n.text("宽度"), value: layer.size.width, range: 1...1_000_000) { l, v in let factor = max(1, v) / l.size.width; l.text?.scale(by: factor); l.size.width *= factor; l.size.height *= factor }
                numeric(L10n.text("高度"), value: layer.size.height, range: 1...1_000_000) { l, v in let factor = max(1, v) / l.size.height; l.text?.scale(by: factor); l.size.width *= factor; l.size.height *= factor }
                numeric(L10n.text("旋转 °"), value: layer.angle) { $0.angle = $1 }
                numeric(L10n.text("透明度 %"), value: layer.opacity * 100, range: 0...100) { $0.opacity = min(1, max(0, $1 / 100)) }
                if filter != .sticker {
                    Group {
                        if fullWidthActions { VStack(spacing: 6) { layerActionButtons } }
                        else { HStack { layerActionButtons } }
                    }.buttonStyle(GlassButtonStyle()).controlSize(.small)
                }
            }
        }
        .font(.system(size: 11)).disabled(!model.canPerformEditorActions)
    }
    @ViewBuilder private var layerActionButtons: some View {
        layerButton(L10n.text("置顶"), action: "top")
        layerButton(L10n.text("置底"), action: "bottom")
        layerButton(L10n.text("复制"), action: "duplicate")
        layerButton(L10n.text("删除"), action: "delete")
    }
    private func layerButton(_ title: String, action: String) -> some View {
        Button { model.layerAction(action) } label: {
            Text(title).frame(maxWidth: fullWidthActions ? .infinity : nil, alignment: .center)
        }
    }
    private func numeric(_ title: String, value: Double, range: ClosedRange<Double> = -1_000_000...1_000_000,
                         change: @escaping (inout StickerLayer, Double) -> Void) -> some View {
        NumericValueControl(title: title, value: Binding(get: { value }, set: { number in
            guard number.isFinite, var layer = model.selectedLayer else { return }
            let previous = layer
            change(&layer, number)
            if layer != previous { model.updateLayer(layer, commit: true) }
        }), range: range, updatesContinuously: false)
            .id("\(model.selectedLayerID?.uuidString ?? "")-\(title)")
    }
}

struct LayerCanvasOverlay: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    let scale: Double
    let size: CGSize
    @State private var initial: StickerLayer?
    @State private var mode = ""
    @State private var opposite: CGPoint?
    @State private var initialPointerAngle: Double = 0
    @State private var outline: Color = .white
    private var canManipulate: Bool {
        model.canUseLayers || (model.textEditing && model.canPerformEditorActions)
    }
    private func display(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: p.y * scale) }
    private func corner(_ layer: StickerLayer, x: Double, y: Double) -> CGPoint {
        let a = layer.angle * .pi / 180
        return CGPoint(x: layer.center.x + x * layer.size.width / 2 * cos(a) - y * layer.size.height / 2 * sin(a),
                       y: layer.center.y + x * layer.size.width / 2 * sin(a) + y * layer.size.height / 2 * cos(a))
    }
    var body: some View {
        let _ = languageSettings.language
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
            if let layer = model.selectedLayer, layer.visible {
                let points = [corner(layer, x: -1, y: -1), corner(layer, x: 1, y: -1), corner(layer, x: 1, y: 1), corner(layer, x: -1, y: 1)]
                Path { path in path.addLines(points.map(display)); path.closeSubpath() }.stroke(outline, lineWidth: 1)
                ForEach(1..<4, id: \.self) { index in
                    Rectangle().fill(outline).frame(width: 10, height: 10).position(display(points[index]))
                }
                let top = corner(layer, x: 0, y: -1)
                let a = layer.angle * .pi / 180
                let knob = CGPoint(x: top.x + sin(a) * 24 / scale, y: top.y - cos(a) * 24 / scale)
                Path { path in path.move(to: display(top)); path.addLine(to: display(knob)) }.stroke(outline, lineWidth: 1)
                Circle().fill(outline).frame(width: 12, height: 12).position(display(knob))
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard canManipulate else { return }
            let start = CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)
            let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
            if initial == nil {
                if let selected = model.selectedLayer, selected.visible {
                    let a = selected.angle * .pi / 180, top = corner(selected, x: 0, y: -1)
                    let knob = CGPoint(x: top.x + sin(a) * 24 / scale, y: top.y - cos(a) * 24 / scale)
                    if hypot(start.x - knob.x, start.y - knob.y) * scale < 12 {
                        initial = selected; mode = "rotate"; initialPointerAngle = atan2(start.y - selected.center.y, start.x - selected.center.x)
                    } else {
                        for (x, y) in [(1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
                            let c = corner(selected, x: x, y: y)
                            if hypot(start.x - c.x, start.y - c.y) * scale < 12 {
                                initial = selected; mode = "resize"; opposite = corner(selected, x: -x, y: -y); break
                            }
                        }
                    }
                }
                if initial == nil {
                    if model.textEditing {
                        guard let draft = model.draftLayer, draft.visible, draft.contains(start) else { return }
                        initial = draft; mode = "move"
                    } else {
                        guard let layer = model.document?.layers.reversed().first(where: { $0.visible && $0.contains(start) }) else { model.selectedLayerID = nil; return }
                        model.selectedLayerID = layer.id; initial = layer; mode = "move"
                    }
                }
            }
            guard var layer = initial else { return }
            switch mode {
            case "move": layer.center.x += value.translation.width / scale; layer.center.y += value.translation.height / scale
            case "rotate": layer.angle += (atan2(point.y - layer.center.y, point.x - layer.center.x) - initialPointerAngle) * 180 / .pi
            case "resize":
                if let opposite {
                    let vector = CGPoint(x: start.x - opposite.x, y: start.y - opposite.y)
                    let denominator = vector.x * vector.x + vector.y * vector.y
                    let minimum = max(1 / layer.size.width, 1 / layer.size.height)
                    let factor = max(minimum, ((point.x - opposite.x) * vector.x + (point.y - opposite.y) * vector.y) / max(0.001, denominator))
                    layer.text?.scale(by: factor)
                    layer.size.width *= factor; layer.size.height *= factor
                    layer.center = CGPoint(x: opposite.x + vector.x * factor / 2, y: opposite.y + vector.y * factor / 2)
                }
            default: break
            }
            model.updateLayer(layer, commit: false)
        }.onEnded { _ in
            if initial != nil, let draft = model.draftLayer { model.updateLayer(draft, commit: !model.textEditing) }
            initial = nil; opposite = nil; mode = ""
        })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
            guard model.canUseLayers else { return }
            let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
            if let layer = model.document?.layers.reversed().first(where: { $0.visible && $0.contains(point) }), layer.text != nil {
                model.selectedLayerID = layer.id; model.editText()
            }
        })
        .overlay(alignment: .topLeading) {
            if let layer = model.selectedLayer, layer.visible {
                Button { model.layerAction("delete") } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(outline, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(GlassButtonStyle(destructive: true, radius: 12, horizontalPadding: 0, verticalPadding: 0))
                .disabled(!model.canUseLayers)
                .quickHelp(L10n.text("删除图层（可撤销）"))
                .accessibilityLabel(L10n.text("删除图层"))
                .position(display(corner(layer, x: -1, y: -1)))
            }
        }
        .task(id: model.image.map { ObjectIdentifier($0) }) {
            guard let image = model.image else { outline = .white; return }
            let light = await Task.detached(priority: .userInitiated) {
                SelectionContrast.isLight(image)
            }.value
            guard !Task.isCancelled else { return }
            outline = light ? .black : .white
        }
        .allowsHitTesting(canManipulate)
    }
}

enum SelectionContrast {
    static func isLight(_ image: CGImage) -> Bool {
        let dimension = 24
        var pixels = [UInt8](repeating: 0, count: dimension * dimension * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: dimension, height: dimension,
                                          bitsPerComponent: 8, bytesPerRow: dimension * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
            let data = buffer.bindMemory(to: UInt8.self)
            var luminance = 0.0
            for index in stride(from: 0, to: data.count, by: 4) {
                // Transparent areas show the dark canvas beneath the image.
                luminance += (0.2126 * Double(data[index]) + 0.7152 * Double(data[index + 1]) +
                              0.0722 * Double(data[index + 2])) / 255 + (1 - Double(data[index + 3]) / 255) * 0.12
            }
            return luminance / Double(dimension * dimension) >= 0.5
        }
    }
}
