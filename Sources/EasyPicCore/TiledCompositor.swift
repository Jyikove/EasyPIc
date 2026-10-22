import Foundation
import CoreGraphics

public struct TileRenderStatistics {
    public var rendered = 0
    public var reused = 0
    public var candidates = 0
    public var retainedBytes = 0
}

/// Actor-confined persistent original-resolution tiles with exact dirty-region invalidation.
/// A full snapshot is assembled for existing save/OCR APIs, without replaying unchanged tiles.
public final class TiledCompositor {
    private struct Key: Hashable { let x: Int; let y: Int }
    private struct Tile { let image: CGImage; var accessed: Int }
    private let tileSize = 512
    private let byteBudget: Int
    private var tiles: [Key: Tile] = [:]
    private var bytes = 0, clock = 0
    private var previous: EditorDocument?
    private var previousBase: CGImage?
    private var previousSources: [UUID: CGImage] = [:]
    public private(set) var statistics = TileRenderStatistics()
    public init(byteBudget: Int = 96 * 1024 * 1024) { self.byteBudget = max(0, byteBudget) }
    public func render(_ document: EditorDocument, resources: [UUID: CGImage], base: CGImage, trace: UUID? = nil) throws -> CGImage {
        try Task.checkCancellation()
        let canvas = CGRect(origin: .zero, size: document.size)
        let index = LayerSpatialIndex(document.layers)
        if previous?.size != document.size || previousBase !== base || previous == nil {
            tiles.removeAll(); bytes = 0
        } else if let old = previous {
            let oldByID = Dictionary(uniqueKeysWithValues: old.layers.enumerated().map { ($0.element.id, ($0.offset, $0.element)) })
            let newByID = Dictionary(uniqueKeysWithValues: document.layers.enumerated().map { ($0.element.id, ($0.offset, $0.element)) })
            var dirty: [CGRect] = []
            for id in Set(oldByID.keys).union(newByID.keys) {
                let before = oldByID[id], after = newByID[id]
                let sourceChanged = after.map { $0.1.text == nil && previousSources[$0.1.resourceID] !== resources[$0.1.resourceID] } ?? false
                if before?.0 != after?.0 || before?.1 != after?.1 || sourceChanged {
                    if let layer = before?.1, layer.visible { dirty.append(layer.canvasBounds.insetBy(dx: -2, dy: -2)) }
                    if let layer = after?.1, layer.visible { dirty.append(layer.canvasBounds.insetBy(dx: -2, dy: -2)) }
                }
            }
            for key in Array(tiles.keys) where dirty.contains(where: { $0.intersects(rect(key, canvas: canvas)) }) {
                tiles.removeValue(forKey: key)
            }
            bytes = tiles.values.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
        }
        previous = document; previousBase = base
        let ids = document.referencedResourceIDs
        previousSources = resources.filter { ids.contains($0.key) }
        statistics = TileRenderStatistics()
        if document.layers.allSatisfy({ !$0.visible }) { tiles.removeAll(); bytes = 0; return base }
        guard let output = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageFailure.renderFailed }
        output.setBlendMode(.copy)
        InteractionMetrics.shared.mark(trace, "TileRasterBegin")
        for y in 0..<Int(ceil(canvas.height / CGFloat(tileSize))) {
            for x in 0..<Int(ceil(canvas.width / CGFloat(tileSize))) {
                try Task.checkCancellation()
                let key = Key(x: x, y: y), area = rect(key, canvas: canvas)
                clock += 1
                let bitmap: CGImage
                if var tile = tiles[key] {
                    tile.accessed = clock; tiles[key] = tile; bitmap = tile.image; statistics.reused += 1
                } else {
                    let candidates = index.query(area.insetBy(dx: -2, dy: -2))
                    let halo = candidates.reduce(CGFloat(2)) { value, i in
                        guard let text = document.layers[i].text else { return value }
                        return max(value, ceil(text.shadowBlur * 3 + abs(text.shadowX) + abs(text.shadowY)) + 4)
                    }
                    let expanded = area.insetBy(dx: -halo, dy: -halo).intersection(canvas).integral
                    let nearby = index.query(expanded)
                    bitmap = try autoreleasepool {
                        let rendered = try DocumentEngine.renderRegion(document, resources: resources, base: base, region: expanded, candidates: nearby)
                        guard let cropped = rendered.cropping(to: area.offsetBy(dx: -expanded.minX, dy: -expanded.minY)),
                              let copy = CGContext(data: nil, width: Int(area.width), height: Int(area.height), bitsPerComponent: 8,
                                                   bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageFailure.renderFailed }
                        copy.setBlendMode(.copy); copy.draw(cropped, in: CGRect(origin: .zero, size: area.size))
                        guard let image = copy.makeImage() else { throw ImageFailure.renderFailed }; return image
                    }
                    statistics.rendered += 1; statistics.candidates += nearby.count
                    retain(bitmap, key: key)
                }
                output.draw(bitmap, in: CGRect(x: area.minX, y: canvas.height - area.maxY, width: area.width, height: area.height))
            }
        }
        statistics.retainedBytes = bytes
        InteractionMetrics.shared.mark(trace, "TileRasterAndAssemblyReady")
        InteractionMetrics.shared.count(trace, "tilesRendered", statistics.rendered)
        InteractionMetrics.shared.count(trace, "tilesReused", statistics.reused)
        InteractionMetrics.shared.count(trace, "layerCandidates", statistics.candidates)
        InteractionMetrics.shared.count(trace, "retainedTileBytes", bytes)
        guard let image = output.makeImage() else { throw ImageFailure.renderFailed }; return image
    }
    private func rect(_ key: Key, canvas: CGRect) -> CGRect {
        CGRect(x: key.x * tileSize, y: key.y * tileSize, width: tileSize, height: tileSize).intersection(canvas)
    }
    private func retain(_ image: CGImage, key: Key) {
        let cost = image.bytesPerRow * image.height
        guard cost <= byteBudget else { return }
        while bytes + cost > byteBudget, let oldest = tiles.min(by: { $0.value.accessed < $1.value.accessed })?.key {
            let image = tiles.removeValue(forKey: oldest)!.image; bytes -= image.bytesPerRow * image.height
        }
        tiles[key] = Tile(image: image, accessed: clock); bytes += cost
    }
}
