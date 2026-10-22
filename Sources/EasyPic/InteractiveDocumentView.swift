import SwiftUI
import AppKit
import EasyPicCore

/// During editing only the layer being manipulated changes. The full-resolution composite
/// remains a committed snapshot for OCR, export and history, rather than a drag preview.
struct InteractiveDocumentView: View {
    let document: EditorDocument
    let draft: StickerLayer?
    let resources: [UUID: CGImage]
    let base: CGImage
    let service: DocumentRenderService
    let scale: Double
    let size: CGSize
    var viewport: CGRect? = nil
    var spatialIndex: LayerSpatialIndex? = nil
    private var layers: [StickerLayer] {
        let visible = (viewport ?? CGRect(origin: .zero, size: size)).insetBy(dx: -64, dy: -64)
        let area = CGRect(x: visible.minX / scale, y: visible.minY / scale, width: visible.width / scale, height: visible.height / scale)
        let index = spatialIndex ?? LayerSpatialIndex(document.layers)
        var selected = Dictionary(uniqueKeysWithValues: index.query(area).map { ($0, document.layers[$0]) })
        if let draft {
            let key = document.layers.firstIndex { $0.id == draft.id } ?? document.layers.count
            selected[key] = draft.visible && draft.canvasBounds.intersects(area) ? draft : nil
        }
        return selected.keys.sorted().compactMap { selected[$0] }
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            NativeRasterImage(image: base)
                .frame(width: size.width, height: size.height)
            ForEach(layers.filter(\.visible)) { layer in
                InteractiveLayerView(layer: layer, resources: resources, service: service, scale: scale, canvasSize: size, viewport: viewport ?? CGRect(origin: .zero, size: size))
            }
        }.frame(width: size.width, height: size.height).clipped().allowsHitTesting(false)
    }
}

private struct InteractiveLayerView: View {
    let layer: StickerLayer
    let resources: [UUID: CGImage]
    let service: DocumentRenderService
    let scale: Double
    let canvasSize: CGSize
    let viewport: CGRect
    @State private var bitmap: CGImage?
    private var key: String {
        let identity = layer.text == nil ? resources[layer.resourceID].map { String(describing: ObjectIdentifier($0)) } ?? "missing" : "text"
        return identity + layer.rasterKey
    }

    private var vectorViewport: CGRect {
        let angle = -layer.angle * .pi / 180, center = CGPoint(x: layer.center.x * scale, y: layer.center.y * scale)
        let width = layer.size.width * scale, height = layer.size.height * scale
        let points = [CGPoint(x: viewport.minX, y: viewport.minY), CGPoint(x: viewport.maxX, y: viewport.minY),
                      CGPoint(x: viewport.maxX, y: viewport.maxY), CGPoint(x: viewport.minX, y: viewport.maxY)].map { p in
            let dx = p.x - center.x, dy = p.y - center.y
            return CGPoint(x: (dx * cos(angle) - dy * sin(angle)) * (layer.mirrored ? -1 : 1) + width / 2,
                           y: dx * sin(angle) + dy * cos(angle) + height / 2)
        }
        let x = points.map(\.x), y = points.map(\.y)
        return CGRect(x: x.min()!, y: y.min()!, width: x.max()! - x.min()!, height: y.max()! - y.min()!)
    }
    var body: some View {
        // Keep a concrete host alive before the first asynchronous text bitmap
        // exists. An empty Group forwards its task to zero children, so a new
        // text layer could never start rendering its first preview.
        ZStack {
            if let image = bitmap ?? (layer.strokes?.isEmpty != false && layer.text == nil ? resources[layer.resourceID] : nil) {
                Group {
                    if let svg = layer.svgData, layer.strokes?.isEmpty != false {
                        VectorStickerView(data: svg, poster: image, viewport: vectorViewport)
                    } else { NativeRasterImage(image: image) }
                }
                    .frame(width: layer.size.width * scale, height: layer.size.height * scale)
                    .scaleEffect(x: layer.mirrored ? -1 : 1, y: 1)
                    .rotationEffect(.degrees(layer.angle))
                    .opacity(layer.opacity)
                    .position(x: layer.center.x * scale, y: layer.center.y * scale)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipShape(LayerClip(polygons: layer.clips, scale: scale))
        .task(id: key) {
            do {
                if layer.svgData != nil && layer.strokes?.isEmpty != false { return }
                let image = try await service.layer(layer, resources: resources)
                guard !Task.isCancelled else { return }
                bitmap = image
            } catch is CancellationError { }
            catch { /* The committed document render reports failures to the editor. */ }
        }
    }
}

private struct LayerClip: Shape {
    let polygons: [[CGPoint]]
    let scale: Double
    func path(in rect: CGRect) -> Path {
        var result = Path(rect)
        for polygon in polygons {
            var path = Path()
            path.addLines(polygon.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }); path.closeSubpath()
            result = result.intersection(path)
        }
        return result
    }
}

private struct VectorStickerView: View {
    let data: Data
    let poster: CGImage
    let viewport: CGRect
    @State private var vector: NSImage?
    var body: some View {
        Group {
            if let vector {
                SVGImageView(image: vector, poster: poster, sourceURL: nil, viewport: viewport, sourceData: data)
            } else { NativeRasterImage(image: poster) }
        }
        .task(id: data) { vector = NSImage(data: data) }
    }
}
