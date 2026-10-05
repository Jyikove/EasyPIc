import Foundation
import CoreGraphics

public enum LayerMergeMode {
    case down(UUID)
    case visible
    case all
}

public enum LayerMergeFailure: LocalizedError {
    case invalidSelection, insufficientVisibleLayers
    public var errorDescription: String? {
        switch self {
        case .invalidSelection: return L10n.text("请选择可见图层；向下合并时，下方图层也需要可见。")
        case .insufficientVisibleLayers: return L10n.text("至少需要两个可见图层才能合并。")
        }
    }
}

extension DocumentEngine {
    /// Rasterize at full canvas resolution. Keep old resources for the caller's undo history.
    public static func merge(_ document: EditorDocument, resources: [UUID: CGImage], mode: LayerMergeMode) throws
        -> (document: EditorDocument, resourceID: UUID, image: CGImage) {
        let indices: [Int]
        let includesBase: Bool
        switch mode {
        case .down(let id):
            guard let index = document.layers.firstIndex(where: { $0.id == id }), document.layers[index].visible,
                  index == 0 || document.layers[index - 1].visible else { throw LayerMergeFailure.invalidSelection }
            includesBase = index == 0
            indices = includesBase ? [index] : [index - 1, index]
        case .visible:
            indices = document.layers.indices.filter { document.layers[$0].visible }
            guard indices.count >= 2 else { throw LayerMergeFailure.insufficientVisibleLayers }
            includesBase = false
        case .all:
            guard !document.layers.isEmpty else { throw LayerMergeFailure.invalidSelection }
            indices = Array(document.layers.indices)
            includesBase = true
        }
        let size = document.size
        var source = document
        source.layers = indices.map { document.layers[$0] }
        var image: CGImage
        if includesBase {
            image = try render(source, resources: resources)
        } else {
            // Render overlays against transparency, retaining the original base independently.
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let clear = context.makeImage() else {
                throw ImageFailure.renderFailed
            }
            image = try render(source, resources: resources, base: clear)
        }
        let resourceID = UUID()
        var next = document
        if includesBase {
            next.baseResourceID = resourceID; next.originalSize = size
            next.operations = []; next.baseStrokes = nil
            if case .all = mode { next.layers = [] }
            else { next.layers.removeFirst() }
            next.activeLayerID = nil
        } else {
            let bounds = mergedBounds(source.layers, canvas: size)
            image = try ImageEngine.render(image, operations: [.crop(bounds)])
            let merged = StickerLayer(resourceID: resourceID, name: L10n.text("合并图层"),
                center: CGPoint(x: bounds.midX, y: bounds.midY), size: bounds.size)
            let included = Set(indices)
            let top = indices.last!
            next.layers = document.layers.enumerated().compactMap { index, layer in
                if index == top { return merged }
                return included.contains(index) ? nil : layer
            }
            next.activeLayerID = merged.id
        }
        return (next, resourceID, image)
    }

    private static func mergedBounds(_ layers: [StickerLayer], canvas: CGSize) -> CGRect {
        func bounds(of points: [CGPoint]) -> CGRect {
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return .null }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        var union = CGRect.null
        for layer in layers {
            let angle = layer.angle * .pi / 180
            let points = [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1), CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1)].map {
                let x = $0.x * layer.size.width / 2, y = $0.y * layer.size.height / 2
                return CGPoint(x: layer.center.x + x * cos(angle) - y * sin(angle),
                               y: layer.center.y + x * sin(angle) + y * cos(angle))
            }
            var rect = bounds(of: points)
            for clip in layer.clips { rect = rect.intersection(bounds(of: clip)) }
            if !rect.isNull { union = union.union(rect) }
        }
        let rect = union.intersection(CGRect(origin: .zero, size: canvas))
        guard !rect.isNull, !rect.isEmpty else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: floor(rect.minX), y: floor(rect.minY),
                      width: ceil(rect.maxX) - floor(rect.minX), height: ceil(rect.maxY) - floor(rect.minY))
    }
}
