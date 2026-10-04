import SwiftUI
import AppKit
import EasyPicCore

extension EditorModel {
    func beginBrush() {
        guard canUseLayers else { return }; brushTarget = "base"; brushMode = true; brushPoints = []; cloneSource = nil
    }
    func cancelBrush() { brushMode = false; brushPoints = []; cloneSource = nil }
    func commitBrush(_ points: [CGPoint]) {
        guard brushMode, !busy, let doc = document, !points.isEmpty else { return }
        if brushTool == .clone && cloneSource == nil { cloneSource = points[0]; status = "已设置克隆取样点，拖动开始绘制"; return }
        let rect = brushRectangle ? CGRect(x: min(points[0].x, points.last!.x), y: min(points[0].y, points.last!.y), width: abs(points[0].x - points.last!.x), height: abs(points[0].y - points.last!.y)) : nil
        let stroke = BrushStroke(tool: brushTool, points: points, diameter: brushSize, hardness: brushHardness, opacity: brushOpacity, strength: brushStrength, color: brushColor, source: cloneSource, rectangle: rect)
        let assets = resources, target = brushTool == .solid ? "overlay" : brushTarget, selected = selectedLayerID
        busy = true
        Task {
            do {
                let next = try await Task.detached { () -> (EditorDocument, UUID?, CGImage?) in
                    var next = doc
                    if target == "layer" {
                        guard let index = next.layers.firstIndex(where: { $0.id == selected }), next.layers[index].text == nil,
                              let sourceImage = assets[next.layers[index].resourceID] else { throw AIJobFailure("请选择一个图片贴纸图层。文字可先导出再作为贴纸导入。") }
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
                        guard let clear = CGContext(data:nil,width:Int(doc.size.width),height:Int(doc.size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() else { throw ImageFailure.renderFailed }
                        let clearID = UUID(); next.baseResourceID = doc.baseResourceID
                        next.layers.append(StickerLayer(resourceID: clearID, name: "纯色遮盖", center: CGPoint(x: doc.size.width / 2, y: doc.size.height / 2), size: doc.size))
                        next.layers[next.layers.count - 1].resourceID = clearID
                        next.layers[next.layers.count - 1].strokes = [stroke]
                        return (next, clearID, clear)
                    }
                    let raster = try target == "canvas" ? DocumentEngine.render(doc,resources:assets) : DocumentEngine.renderBase(doc,resources:assets)
                    let id=UUID(); next.baseResourceID=id; next.originalSize=doc.size; next.operations=[]; next.baseStrokes=[stroke]
                    if target == "canvas" { next.layers=[] }
                    return (next,id,raster)
                }.value
                if let id=next.1,let raster=next.2 { resources[id]=raster }
                busy = false; commitDocument(next.0)
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}
struct BrushInspector: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("本地画笔", systemImage: "paintbrush.pointed").font(.headline)
            Picker("画笔", selection: Binding(get: {
                model.brushTool == .solid ? "solid" : (model.brushTool == .repair ? "repair" : "mosaic")
            }, set: { model.brushTool = $0 == "solid" ? .solid : ($0 == "repair" ? .repair : .pixelate) })) {
                Text("纯色").tag("solid"); Text("马赛克").tag("mosaic"); Text("消除").tag("repair")
            }.pickerStyle(.segmented)
            if model.brushTool == .pixelate || model.brushTool == .blur {
                Picker("马赛克样式", selection: $model.brushTool) {
                    Text("像素块").tag(BrushTool.pixelate); Text("高斯模糊").tag(BrushTool.blur)
                }.pickerStyle(.segmented)
            }
            Text("直径 \(Int(model.brushSize)) px"); Slider(value: $model.brushSize, in: 1...500)
            Text("硬度 \(Int(model.brushHardness*100))%"); Slider(value:$model.brushHardness,in:0...1)
            Text("透明度 \(Int(model.brushOpacity*100))%"); Slider(value:$model.brushOpacity,in:0...1)
            if model.brushTool == .pixelate || model.brushTool == .blur { Text("强度 \(Int(model.brushStrength))"); Slider(value:$model.brushStrength,in:1...100) }
            if model.brushTool == .solid {
                ColorPicker("遮盖颜色", selection: Binding(get:{Color(cgColor:model.brushColor.cgColor)},set:{ value in if let c=NSColor(value).usingColorSpace(.sRGB) { model.brushColor=TextColor(c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent) } }))
            }
            if [.pixelate,.blur,.solid].contains(model.brushTool) { Toggle("矩形选区",isOn:$model.brushRectangle) }
            if model.brushTool == .clone {
                Text(model.cloneSource == nil ? "先点击画布设置取样点，再拖动绘制。" : "取样点已设置。按住 Option 点击可重新取样。")
                Button("重新取样") { model.cloneSource=nil }
            }
            if model.brushTool == .repair { Text("消除作用于原图；复杂纹理或大范围水印可能需要分次涂抹。").font(.caption).foregroundStyle(.secondary) }
            Text(model.brushTool == .solid ? "纯色笔画置于顶层，可撤销。" : "作用于原图，保留文字和贴纸，可撤销。").font(.caption).foregroundStyle(.secondary)
            Button("完成画笔",action:model.cancelBrush).keyboardShortcut(.escape,modifiers:[]).buttonStyle(.glassProminent)
            Spacer()
        }.padding(20).frame(width:280).glassEffect(.regular,in:RoundedRectangle(cornerRadius:22)).disabled(model.busy)
    }
}
struct BrushOverlay: View {
    @ObservedObject var model: EditorModel
    let scale: Double
    let size: CGSize
    var body: some View {
        Canvas { context, _ in
            var path=Path()
            if model.brushRectangle, let a=model.brushPoints.first,let b=model.brushPoints.last {
                path.addRect(CGRect(x:min(a.x,b.x)*scale,y:min(a.y,b.y)*scale,width:abs(a.x-b.x)*scale,height:abs(a.y-b.y)*scale))
                context.stroke(path,with:.color(.white),lineWidth:1)
            } else {
                path.addLines(model.brushPoints.map{CGPoint(x:$0.x*scale,y:$0.y*scale)})
                context.stroke(path,with:.color(.white.opacity(0.45)),style:StrokeStyle(lineWidth:model.brushSize*scale,lineCap:.round,lineJoin:.round))
            }
            if let p=model.cloneSource { context.stroke(Path(ellipseIn:CGRect(x:p.x*scale-5,y:p.y*scale-5,width:10,height:10)),with:.color(.orange),lineWidth:2) }
        }.frame(width:size.width,height:size.height).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance:0).onChanged { value in
            guard !model.busy else { return }
            let p=CGPoint(x:min(size.width,max(0,value.location.x))/scale,y:min(size.height,max(0,value.location.y))/scale)
            if model.brushTool == .clone && NSEvent.modifierFlags.contains(.option) { model.cloneSource=p; return }
            model.brushPoints.append(p)
        }.onEnded { _ in let points=model.brushPoints; model.brushPoints=[]; model.commitBrush(points) })
    }
}
