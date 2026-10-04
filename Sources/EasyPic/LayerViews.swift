import SwiftUI
import EasyPicCore

struct LayerInspector: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: model.importSticker) { Label("添加图片贴纸…", systemImage: "plus.square.on.square") }.buttonStyle(.glass)
            Button(action: model.addText) { Label("添加文字", systemImage: "textformat") }.buttonStyle(.glass)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(Array((model.document?.layers ?? []).reversed())) { layer in
                        HStack {
                            Button { model.selectedLayerID = layer.id; model.layerAction("visibility") } label: { Image(systemName: layer.visible ? "eye" : "eye.slash") }.buttonStyle(.plain)
                            Button { model.selectedLayerID = layer.id } label: { Text(layer.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                        }
                        .padding(6).background(model.selectedLayerID == layer.id ? Color.white.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }.frame(maxHeight: 100)
            if model.document?.layers.isEmpty == true { Text("添加贴纸或文字后，在画布中选择并调整。").foregroundStyle(.secondary) }
            if let layer = model.selectedLayer {
                if layer.text != nil { Button("编辑文字…", action: model.editText).buttonStyle(.glass) }
                numeric("中心 X", value: layer.center.x) { $0.center.x = $1 }
                numeric("中心 Y", value: layer.center.y) { $0.center.y = $1 }
                numeric("宽度", value: layer.size.width) { l, v in let factor = max(1, v) / l.size.width; l.text?.scale(by: factor); l.size.width *= factor; l.size.height *= factor }
                numeric("高度", value: layer.size.height) { l, v in let factor = max(1, v) / l.size.height; l.text?.scale(by: factor); l.size.width *= factor; l.size.height *= factor }
                numeric("旋转 °", value: layer.angle) { $0.angle = $1 }
                numeric("透明度 %", value: layer.opacity * 100) { $0.opacity = min(1, max(0, $1 / 100)) }
                HStack {
                    Button("置顶") { model.layerAction("top") }; Button("置底") { model.layerAction("bottom") }
                    Button("复制") { model.layerAction("duplicate") }; Button("删除") { model.layerAction("delete") }
                }.buttonStyle(.glass).controlSize(.small)
                Text(layer.text == nil ? "拖动移动；三个角等比缩放；上方圆点旋转，左上角删除。数值输入后按回车确认。" : "双击编辑文字；角点等比缩放文字。上方圆点旋转，左上角删除。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11)).disabled(!model.canUseLayers)
    }
    private func numeric(_ title: String, value: Double, change: @escaping (inout StickerLayer, Double) -> Void) -> some View {
        LayerNumberField(title: title, value: value) { number in
            guard number.isFinite, var layer = model.selectedLayer else { return }
            change(&layer, number); model.updateLayer(layer, commit: true)
        }.id("\(model.selectedLayerID?.uuidString ?? "")-\(title)")
    }
}

private struct LayerNumberField: View {
    let title: String
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            Text(title); Spacer()
            TextField(title, text: $text).labelsHidden().frame(width: 76).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit { if let number = Double(text) { commit(number) }; focused = false }
        }
        .onAppear { text = String(format: "%.2f", value) }
        .onChange(of: value) { _, value in if !focused { text = String(format: "%.2f", value) } }
        .onChange(of: focused) { _, focused in if !focused { text = String(format: "%.2f", value) } }
    }
}

struct LayerCanvasOverlay: View {
    @ObservedObject var model: EditorModel
    let scale: Double
    let size: CGSize
    @State private var initial: StickerLayer?
    @State private var mode = ""
    @State private var opposite: CGPoint?
    @State private var initialPointerAngle: Double = 0
    private func display(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale, y: p.y * scale) }
    private func corner(_ layer: StickerLayer, x: Double, y: Double) -> CGPoint {
        let a = layer.angle * .pi / 180
        return CGPoint(x: layer.center.x + x * layer.size.width / 2 * cos(a) - y * layer.size.height / 2 * sin(a),
                       y: layer.center.y + x * layer.size.width / 2 * sin(a) + y * layer.size.height / 2 * cos(a))
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
            if let layer = model.selectedLayer, layer.visible {
                let points = [corner(layer, x: -1, y: -1), corner(layer, x: 1, y: -1), corner(layer, x: 1, y: 1), corner(layer, x: -1, y: 1)]
                Path { path in path.addLines(points.map(display)); path.closeSubpath() }.stroke(.white, lineWidth: 1)
                ForEach(1..<4, id: \.self) { index in
                    Rectangle().fill(.white).frame(width: 10, height: 10).position(display(points[index]))
                }
                let top = corner(layer, x: 0, y: -1)
                let a = layer.angle * .pi / 180
                let knob = CGPoint(x: top.x + sin(a) * 24 / scale, y: top.y - cos(a) * 24 / scale)
                Path { path in path.move(to: display(top)); path.addLine(to: display(knob)) }.stroke(.white, lineWidth: 1)
                Circle().fill(.white).frame(width: 12, height: 12).position(display(knob))
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard model.canUseLayers else { return }
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
                    guard let layer = model.document?.layers.reversed().first(where: { $0.visible && $0.contains(start) }) else { model.selectedLayerID = nil; return }
                    model.selectedLayerID = layer.id; initial = layer; mode = "move"
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
            if initial != nil, let draft = model.draftLayer { model.updateLayer(draft, commit: true) }
            initial = nil; opposite = nil; mode = ""
        })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
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
                        .background(.red, in: Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("删除图层（可撤销）")
                .accessibilityLabel("删除图层")
                .position(display(corner(layer, x: -1, y: -1)))
            }
        }
        .allowsHitTesting(model.canUseLayers)
    }
}
