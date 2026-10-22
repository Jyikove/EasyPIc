import SwiftUI
import AppKit
import EasyPicCore

extension EditorModel {
    func beginBrush() {
        guard canUseLayers else { return }
        startEditorSessionIfNeeded(); sidePanel = .edit
        activeEditorTool = brushTool == .solid ? .solid : (brushTool == .repair ? .repair : .mosaic)
        brushTarget = brushTool == .solid ? "base" : "canvas"
        brushMode = true; brushPoints = []; cloneSource = nil
    }
    func cancelBrush() { brushMode = false; brushPoints = []; cloneSource = nil }
    func makeBrushStroke(_ points: [CGPoint]) -> BrushStroke {
        let rect = (brushTool != .solid || brushShape == .freehand) && brushRectangle && !points.isEmpty ? CGRect(x: min(points[0].x, points.last!.x), y: min(points[0].y, points.last!.y), width: abs(points[0].x - points.last!.x), height: abs(points[0].y - points.last!.y)) : nil
        return BrushStroke(tool: brushTool, points: points, diameter: brushSize, hardness: brushHardness, opacity: brushOpacity,
                           strength: brushStrength, color: brushColor, source: cloneSource, rectangle: rect,
                           shape: brushTool == .solid ? brushShape : nil,
                           cornerRadius: brushTool == .solid ? brushCornerRadius : nil,
                           constrainCircle: brushTool == .solid ? brushCircle : nil)
    }
    func commitBrush(_ points: [CGPoint]) {
        guard brushMode, !busy, let doc = document, !points.isEmpty else { return }
        if brushTool == .clone && cloneSource == nil { cloneSource = points[0]; status = L10n.text("已设置克隆取样点，拖动开始绘制"); return }
        let stroke = makeBrushStroke(points)
        if brushTool == .solid && brushShape != .freehand && BrushShapeGeometry.path(for: stroke) == nil { return }
        let trace = InteractionMetrics.shared.begin("BrushCommit", parent: latestInteractionID)
        InteractionMetrics.shared.mark(trace, "BrushProcessingBegin")
        let committedPreview = documentPreview
        let assets = resources, target = brushTool == .solid ? "overlay" : brushTarget, selected = selectedLayerID
        busy = true
        Task {
            do {
                let next = try await Task.detached { () -> (EditorDocument, UUID?, CGImage?) in
                    var next = doc
                    if target == "layer" {
                        guard let index = next.layers.firstIndex(where: { $0.id == selected }), next.layers[index].text == nil,
                              let sourceImage = assets[next.layers[index].resourceID] else { throw NSError(domain: "EasyPic.Brush", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("请选择一个图片贴纸图层。文字可先导出再作为贴纸导入。")]) }
                        let layer = next.layers[index], a = layer.angle * .pi / 180
                        func local(_ p: CGPoint) -> CGPoint {
                            let dx = p.x-layer.center.x, dy = p.y-layer.center.y
                            let x = (dx*cos(a)+dy*sin(a)) * (layer.mirrored ? -1 : 1)
                            let y = -dx*sin(a)+dy*cos(a)
                            return CGPoint(x:(x+layer.size.width/2)*CGFloat(sourceImage.width)/layer.size.width,
                                           y:(y+layer.size.height/2)*CGFloat(sourceImage.height)/layer.size.height)
                        }
                        var mapped = stroke; mapped.points = stroke.points.map(local); mapped.source = stroke.source.map(local)
                        mapped.diameter *= CGFloat(sourceImage.width)/layer.size.width
                        if let rect = stroke.rectangle {
                            let corners = [local(rect.origin),local(CGPoint(x:rect.maxX,y:rect.minY)),local(CGPoint(x:rect.maxX,y:rect.maxY)),local(CGPoint(x:rect.minX,y:rect.maxY))]
                            mapped.rectangle=CGRect(x:corners.map(\.x).min()!,y:corners.map(\.y).min()!,width:corners.map(\.x).max()!-corners.map(\.x).min()!,height:corners.map(\.y).max()!-corners.map(\.y).min()!)
                        }
                        var strokes=layer.strokes ?? []; strokes.append(mapped); next.layers[index].strokes=strokes
                        return (next,nil,nil)
                    }
                    if target == "base", doc.operations.isEmpty {
                        var strokes=next.baseStrokes ?? []; strokes.append(stroke); next.baseStrokes=strokes
                        return (next,nil,nil)
                    }
                    if target == "overlay" {
                        guard let painted = try BrushEngine.paintLayer(stroke, canvasSize: doc.size) else { return (doc, nil, nil) }
                        let id = UUID()
                        next.layers.append(StickerLayer(resourceID: id, name: L10n.text("纯色画笔"),
                                                        center: CGPoint(x: painted.rect.midX, y: painted.rect.midY), size: painted.rect.size))
                        return (next, id, painted.image)
                    }
                    let raster = try target == "canvas" ? (committedPreview ?? DocumentEngine.render(doc,resources:assets)) : DocumentEngine.renderBase(doc,resources:assets)
                    let id=UUID(); next.baseResourceID=id; next.originalSize=doc.size; next.operations=[]; next.baseStrokes=[stroke]
                    if target == "canvas" { next.layers=[]; next.activeLayerID = nil }
                    return (next,id,raster)
                }.value
                InteractionMetrics.shared.mark(trace, "BrushProcessingReady")
                if let id=next.1,let raster=next.2 { resources[id]=raster }
                latestInteractionID = trace
                busy = false; commitDocument(next.0)
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}
struct BrushToolControls: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .leading, spacing: 14) {
            if model.brushTool == .solid {
                GlassSlidingPicker(selection: $model.brushShape,
                                   options: BrushShape.allCases.map { ($0.title, $0) },
                                   symbols: BrushShape.allCases.map(\.icon))
                    .accessibilityLabel(L10n.text("画笔形状"))
                if model.brushShape == .rectangle {
                    NumericValueControl(title: L10n.text("圆角半径"), value: $model.brushCornerRadius, range: 0...1000, step: 5)
                } else if model.brushShape == .ellipse {
                    Toggle(L10n.text("正圆"), isOn: $model.brushCircle).toggleStyle(GlassToggleStyle())
                }
            }
            if model.brushTool == .pixelate || model.brushTool == .blur {
                MosaicEffectSlider(value: effectBinding)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.text("马赛克视觉效果"))
                .accessibilityValue(model.brushTool == .pixelate ? L10n.text("Pixel") : L10n.text("Gaussian"))
            }
            HStack(spacing: 8) {
                Text(L10n.text("直径"))
                Spacer(minLength: 0)
                Circle()
                    .fill(model.brushTool == .solid ? Color(cgColor: model.brushColor.cgColor).opacity(model.brushOpacity) : Color.primary.opacity(0.1))
                    .overlay(Circle().strokeBorder(.primary.opacity(0.65), lineWidth: 1))
                    .frame(width: model.brushPreviewDiameter, height: model.brushPreviewDiameter)
                    .glassSurface(.control, radius: model.brushPreviewDiameter / 2)
                    .quickHelp(L10n.text("按画布缩放预览直径；超大笔刷适配面板显示。"))
                    .accessibilityLabel(L10n.text("画笔直径预览"))
                    .accessibilityValue(L10n.text("{0} 像素", String(describing: Int(model.brushSize))))
            }
            GlassSlider(value: $model.brushSize, in: EditorModel.brushSizeRange).accessibilityLabel(L10n.text("画笔直径"))
            Text(L10n.text("硬度 {0}%", String(describing: Int(model.brushHardness*100)))); GlassSlider(value:$model.brushHardness,in:0...1)
            Text(L10n.text("透明度 {0}%", String(describing: Int(model.brushOpacity*100)))); GlassSlider(value:$model.brushOpacity,in:0...1)
            if model.brushTool == .pixelate || model.brushTool == .blur { Text(L10n.text("强度 {0}", String(describing: Int(model.brushStrength)))); GlassSlider(value:$model.brushStrength,in:1...100) }
            if model.brushTool == .solid {
                EasyPicColorButton(title: L10n.text("画笔颜色"), selection: $model.brushColor)
            }
            if [.pixelate,.blur].contains(model.brushTool) || (model.brushTool == .solid && model.brushShape == .freehand) {
                Toggle(L10n.text("矩形选区"),isOn:$model.brushRectangle).toggleStyle(GlassToggleStyle())
            }
            if model.brushTool == .clone {
                Button(L10n.text("重新取样")) { model.cloneSource=nil }.quickHelp(L10n.text("先点击画布设置取样点，再拖动绘制；Option 点击重新取样。"))
            }
        }.disabled(model.busy)
    }
    private var effectBinding: Binding<Double> {
        Binding(
            get: { model.brushTool == .pixelate ? 0.25 : 0.75 },
            set: { model.brushTool = $0 < 0.5 ? .pixelate : .blur }
        )
    }
}

private extension BrushShape {
    var icon: String {
        switch self {
        case .freehand: return "paintbrush.pointed"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        }
    }
}

private struct MosaicEffectSlider: View {
    @Binding var value: Double
    var body: some View {
        GlassSlidingPicker(selection: Binding(get: { value < 0.5 ? 0 : 1 }, set: { value = $0 == 0 ? 0.25 : 0.75 }),
                           options: [(L10n.text("像素模糊"), 0), (L10n.text("高斯模糊"), 1)])
            .frame(minWidth: 160)
    }
}
private final class StrokeSampleBuffer {
    var points: [CGPoint] = []
}
struct BrushOverlay: View {
    @EnvironmentObject private var frameClock: CanvasFrameClock
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    let scale: Double
    let size: CGSize
    @State private var samples = StrokeSampleBuffer()
    @State private var lastInputTrace: UUID?
    @State private var points: [CGPoint] = []
    @State private var pointer: CGPoint?
    @State private var drawing = false
    @State private var committingPoints: [CGPoint] = []

    private var color: Color {
        Color(.sRGB, red: model.brushColor.red, green: model.brushColor.green,
              blue: model.brushColor.blue, opacity: 1)
    }
    private var opacity: Double { model.brushColor.alpha * model.brushOpacity }

    var body: some View {
        let _ = languageSettings.language
        Canvas { context, _ in
            let points = model.busy ? committingPoints : self.points
            if model.brushTool == .solid, model.brushShape != .freehand,
               let outline = BrushShapeGeometry.path(for: model.makeBrushStroke(points)) {
                paint(Path(outline).applying(CGAffineTransform(scaleX: scale, y: scale)), in: &context)
            } else if model.brushRectangle, let a = points.first, let b = points.last {
                let rect = Path(CGRect(x: min(a.x, b.x) * scale, y: min(a.y, b.y) * scale,
                                       width: abs(a.x - b.x) * scale, height: abs(a.y - b.y) * scale))
                if model.brushTool == .solid { context.fill(rect, with: .color(color.opacity(opacity))) }
                else { context.stroke(rect, with: .color(.white), lineWidth: 1) }
            } else if model.brushTool == .solid {
                paint(points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }, in: &context)
            } else if !points.isEmpty {
                var path = Path(); path.addLines(points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) })
                context.stroke(path, with: .color(.white.opacity(0.45)),
                               style: StrokeStyle(lineWidth: model.brushSize * scale, lineCap: .round, lineJoin: .round))
            }
            if let pointer, !model.busy {
                if model.brushTool == .solid && !drawing && model.brushShape == .freehand && !model.brushRectangle {
                    paint([pointer], in: &context)
                }
                let diameter = max(2, model.brushSize * scale)
                let ring = Path(ellipseIn: CGRect(x: pointer.x - diameter / 2, y: pointer.y - diameter / 2,
                                                 width: diameter, height: diameter))
                context.stroke(ring, with: .color(.black.opacity(0.65)), lineWidth: 3)
                context.stroke(ring, with: .color(model.brushTool == .solid ? color : .white), lineWidth: 1)
            }
            if let p = model.cloneSource {
                context.stroke(Path(ellipseIn: CGRect(x: p.x * scale - 5, y: p.y * scale - 5, width: 10, height: 10)),
                               with: .color(.orange), lineWidth: 2)
            }
        }
        .frame(width: size.width, height: size.height).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard !model.busy else { return }
            let location = CGPoint(x: min(size.width, max(0, value.location.x)),
                                   y: min(size.height, max(0, value.location.y)))
            let nextPointer = CGRect(origin: .zero, size: size).contains(value.location) ? location : nil
            let p = CGPoint(x: location.x / scale, y: location.y / scale)
            if model.brushTool == .clone && NSEvent.modifierFlags.contains(.option) {
                model.cloneSource = p; return
            }
            if samples.points.isEmpty {
                let start = CGPoint(x: min(size.width, max(0, value.startLocation.x)) / scale,
                                    y: min(size.height, max(0, value.startLocation.y)) / scale)
                samples.points.append(start)
            }
            if model.brushTool == .solid && model.brushShape != .freehand {
                samples.points = [samples.points[0], p]
            } else if samples.points.last != p { samples.points.append(p) }
            frameClock.submit("BrushInput", at: ProcessInfo.processInfo.systemUptime - max(0, Date().timeIntervalSince(value.time))) {
                lastInputTrace = frameClock.currentTrace
                points = samples.points; pointer = nextPointer; drawing = true
                model.latestInteractionID = frameClock.currentTrace
            }
        }.onEnded { _ in
            frameClock.flush("BrushInput")
            let strokePoints = samples.points
            samples.points = []; committingPoints = strokePoints; points = []; drawing = false
            model.latestInteractionID = lastInputTrace
            model.commitBrush(strokePoints)
            if !model.busy { committingPoints = [] }
        })
        .background(FramePresentationProbe(clock: frameClock))
        .onDisappear { frameClock.cancel("BrushInput"); frameClock.cancel("BrushCursor") }
        .onContinuousHover { phase in
            guard !drawing else { return }
            switch phase {
            case .active(let location): frameClock.submit("BrushCursor") { pointer = location }
            case .ended: frameClock.submit("BrushCursor") { pointer = nil }
            }
        }
        .onChange(of: model.busy) { _, busy in if !busy { committingPoints = [] } }
    }

    private func paint(_ points: [CGPoint], in context: inout GraphicsContext) {
        guard !points.isEmpty else { return }
        var path = Path(); path.addLines(points)
        paint(path, dot: points.count == 1 ? points[0] : nil, in: &context)
    }
    private func paint(_ path: Path, dot: CGPoint? = nil, in context: inout GraphicsContext) {
        // Draw the feathered mask in an isolated layer so overlaps do not darken one stroke.
        context.drawLayer { layer in
            layer.blendMode = .copy
            let softness = 1 - model.brushHardness
            let bands = softness > 0 ? 20 : 1
            for band in 1...bands {
                let strength = Double(band) / Double(bands)
                let diameter = model.brushSize * scale * max(0.01, 1 - softness * strength)
                let ink = color.opacity(opacity * strength)
                if let p = dot {
                    layer.fill(Path(ellipseIn: CGRect(x: p.x - diameter / 2, y: p.y - diameter / 2,
                                                     width: diameter, height: diameter)), with: .color(ink))
                } else {
                    layer.stroke(path, with: .color(ink),
                                 style: StrokeStyle(lineWidth: diameter, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}
