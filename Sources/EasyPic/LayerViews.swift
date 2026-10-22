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
        layerButton(L10n.text("复制图层"), action: "duplicate")
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

enum LayerCanvasHitTesting {
    static let rotationOffset: CGFloat = 28
    static let controlHitRadius: CGFloat = 14
    static func corner(_ layer: StickerLayer, x: Double, y: Double) -> CGPoint {
        let a = layer.angle * .pi / 180
        return CGPoint(x: layer.center.x + x * layer.size.width / 2 * cos(a) - y * layer.size.height / 2 * sin(a),
                       y: layer.center.y + x * layer.size.width / 2 * sin(a) + y * layer.size.height / 2 * cos(a))
    }
    static func rotationPoint(_ layer: StickerLayer, scale: Double) -> CGPoint {
        let top = corner(layer, x: 0, y: -1), angle = layer.angle * .pi / 180
        return CGPoint(x: top.x + sin(angle) * rotationOffset / scale, y: top.y - cos(angle) * rotationOffset / scale)
    }
    static func deletionPoint(_ layer: StickerLayer, scale: Double, canvasSize: CGSize? = nil) -> CGPoint {
        let top = corner(layer, x: -1, y: -1), angle = layer.angle * .pi / 180
        var point = CGPoint(x: top.x + (sin(angle) - cos(angle)) * 20 / scale,
                            y: top.y - (sin(angle) + cos(angle)) * 20 / scale)
        if let canvasSize {
            let dx = min(20 / scale, canvasSize.width / 2), dy = min(20 / scale, canvasSize.height / 2)
            point.x = min(canvasSize.width - dx, max(dx, point.x))
            point.y = min(canvasSize.height - dy, max(dy, point.y))
        }
        return point
    }
    static func hitsControl(_ layer: StickerLayer, point: CGPoint, scale: Double, canvasSize: CGSize? = nil) -> Bool {
        let corners = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]
        for (x, y) in corners {
            let p = corner(layer, x: x, y: y)
            if hypot(point.x - p.x, point.y - p.y) * scale < controlHitRadius { return true }
        }
        let knob = rotationPoint(layer, scale: scale), delete = deletionPoint(layer, scale: scale, canvasSize: canvasSize)
        return hypot(point.x - knob.x, point.y - knob.y) * scale < controlHitRadius ||
            hypot(point.x - delete.x, point.y - delete.y) * scale < controlHitRadius
    }
}

extension EditorModel {
    func canPanBehindLayers(at point: CGPoint, scale: Double) -> Bool {
        guard sidePanel == .edit, canPerformEditorActions, !cropping, !brushMode,
              activeEditorTool == .sticker || activeEditorTool == .text else { return false }
        if let selectedLayer, selectedLayer.visible,
           LayerCanvasHitTesting.hitsControl(selectedLayer, point: point, scale: scale, canvasSize: document?.size) { return false }
        if textEditing { return draftLayer?.visible != true || draftLayer?.contains(point) != true }
        return sceneIndex.hit(point, layers: document?.layers ?? []) == nil
    }
}

struct LayerCanvasOverlay: View {
    @EnvironmentObject private var frameClock: CanvasFrameClock
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    let scale: Double
    let size: CGSize
    @State private var guides: [SnapGuide] = []
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
        LayerCanvasHitTesting.corner(layer, x: x, y: y)
    }

    var body: some View {
        let _ = languageSettings.language
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
            ForEach(Array(guides.enumerated()), id: \.offset) { _, guide in
                Path { path in
                    let start = guide.vertical ? CGPoint(x: guide.position, y: guide.from) : CGPoint(x: guide.from, y: guide.position)
                    let end = guide.vertical ? CGPoint(x: guide.position, y: guide.to) : CGPoint(x: guide.to, y: guide.position)
                    path.move(to: display(start)); path.addLine(to: display(end))
                }.stroke(Color.cyan, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).allowsHitTesting(false)
            }
            if let layer = model.selectedLayer, layer.visible {
                let points = [corner(layer, x: -1, y: -1), corner(layer, x: 1, y: -1), corner(layer, x: 1, y: 1), corner(layer, x: -1, y: 1)]
                Path { path in path.addLines(points.map(display)); path.closeSubpath() }
                    .stroke(outline.opacity(0.9), style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
                ForEach(0..<4, id: \.self) { index in
                    Circle().fill(.white)
                        .overlay(Circle().strokeBorder(EasyPicGlass.blue.opacity(0.95), lineWidth: 1.3))
                        .frame(width: 10, height: 10)
                        .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                        .position(display(points[index]))
                }
                let top = corner(layer, x: 0, y: -1)
                let knob = LayerCanvasHitTesting.rotationPoint(layer, scale: scale)
                Path { path in path.move(to: display(top)); path.addLine(to: display(knob)) }.stroke(outline, lineWidth: 1)
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EasyPicGlass.blue)
                    .frame(width: 22, height: 22).background(.white, in: Circle())
                    .overlay(Circle().strokeBorder(EasyPicGlass.blue.opacity(0.9), lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .position(display(knob))
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .background(FramePresentationProbe(clock: frameClock))
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            frameClock.submit("LayerDrag", at: ProcessInfo.processInfo.systemUptime - max(0, Date().timeIntervalSince(value.time))) { handleDrag(value) }
        }.onEnded { _ in
            frameClock.flush("LayerDrag")
            if initial != nil, let draft = model.draftLayer { model.updateLayer(draft, commit: !model.textEditing) }
            initial = nil; opposite = nil; mode = ""; guides = []
        })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
            guard model.canUseLayers else { return }
            let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
            if let layer = model.sceneIndex.hit(point, layers: model.document?.layers ?? []), layer.text != nil {
                model.selectedLayerID = layer.id; model.editText()
            }
        })
        .overlay(alignment: .topLeading) { deleteButton }
        .task(id: model.image.map { ObjectIdentifier($0) }) {
            guard let image = model.image else { outline = .white; return }
            let light = await Task.detached(priority: .userInitiated) { SelectionContrast.isLight(image) }.value
            guard !Task.isCancelled else { return }
            outline = light ? .black : .white
        }
        .onDisappear { frameClock.cancel("LayerDrag") }
        .allowsHitTesting(canManipulate)
    }
    private func handleDrag(_ value: DragGesture.Value) {
            guard canManipulate else { return }
            let start = CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)
            let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
            if initial == nil {
                if let selected = model.selectedLayer, selected.visible {
                    let knob = LayerCanvasHitTesting.rotationPoint(selected, scale: scale)
                    if hypot(start.x - knob.x, start.y - knob.y) * scale < LayerCanvasHitTesting.controlHitRadius {
                        initial = selected; mode = "rotate"; initialPointerAngle = atan2(start.y - selected.center.y, start.x - selected.center.x)
                    } else {
                        for (x, y) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
                            let c = corner(selected, x: x, y: y)
                            if hypot(start.x - c.x, start.y - c.y) * scale < LayerCanvasHitTesting.controlHitRadius {
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
                        guard let layer = model.sceneIndex.hit(start, layers: model.document?.layers ?? []) else { model.selectedLayerID = nil; return }
                        model.selectedLayerID = layer.id; initial = layer; mode = "move"
                    }
                }
            }
            guard var layer = initial else { return }
            switch mode {
            case "move":
                layer.center.x += value.translation.width / scale; layer.center.y += value.translation.height / scale
                if !NSEvent.modifierFlags.contains(.option), let doc = model.document {
                    let snapped = LayerSnapping.move(layer, canvas: doc.size, layers: doc.layers, index: model.sceneIndex, scale: scale, previous: guides)
                    layer.center = snapped.center; guides = snapped.guides
                } else { guides = [] }
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
            if mode == "rotate", !NSEvent.modifierFlags.contains(.option) {
                let step = NSEvent.modifierFlags.contains(.shift) ? 15.0 : 90.0
                let snapped = (layer.angle / step).rounded() * step
                if NSEvent.modifierFlags.contains(.shift) || abs(snapped - layer.angle) <= 3 { layer.angle = snapped }
            }
            model.latestInteractionID = frameClock.currentTrace
            model.updateLayer(layer, commit: false)
    }
    @ViewBuilder private var deleteButton: some View {

            if let layer = model.selectedLayer, layer.visible {
                Button { model.layerAction("delete") } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(red: 0.84, green: 0.24, blue: 0.30))
                        .frame(width: 20, height: 20)
                        .background(.white, in: Circle())
                        .overlay(Circle().strokeBorder(EasyPicGlass.blue.opacity(0.65), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canUseLayers)
                .quickHelp(L10n.text("删除图层（可撤销）"))
                .accessibilityLabel(L10n.text("删除图层"))
                .position(display(LayerCanvasHitTesting.deletionPoint(layer, scale: scale,
                    canvasSize: CGSize(width: size.width / scale, height: size.height / scale))))
            }
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
