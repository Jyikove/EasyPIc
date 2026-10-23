import Foundation
import CoreGraphics

public extension StickerLayer {
    var canvasBounds: CGRect {
        let a = angle * .pi / 180
        let w = abs(cos(a)) * size.width + abs(sin(a)) * size.height
        let h = abs(sin(a)) * size.width + abs(cos(a)) * size.height
        var bounds = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        for polygon in clips {
            guard let first = polygon.first else { continue }
            let box = polygon.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            bounds = bounds.intersection(box)
        }
        return bounds
    }
}

/// Canvas-space uniform grid. Very large objects use an overflow bucket instead of
/// exploding the number of cells. Query results preserve document stacking order.
public struct LayerSpatialIndex {
    private struct Cell: Hashable { let x: Int; let y: Int }
    private var cells: [Cell: [Int]] = [:]
    private var overflow: [Int] = []
    private var bounds: [Int: CGRect] = [:]
    public private(set) var extent = CGRect.null
    private let cellSize: CGFloat = 512
    public init(_ layers: [StickerLayer]) {
        for (index, layer) in layers.enumerated() where layer.visible {
            let rect = layer.canvasBounds
            guard !rect.isNull, rect.width > 0, rect.height > 0,
                  [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite && abs($0) < 1e12 }) else { continue }
            bounds[index] = rect; extent = extent.union(rect)
            let x0 = Int(floor(rect.minX / cellSize)), x1 = Int(floor(rect.maxX / cellSize))
            let y0 = Int(floor(rect.minY / cellSize)), y1 = Int(floor(rect.maxY / cellSize))
            if Double(x1 - x0 + 1) * Double(y1 - y0 + 1) > 256 { overflow.append(index); continue }
            for y in y0...y1 { for x in x0...x1 { cells[Cell(x: x, y: y), default: []].append(index) } }
        }
    }
    public func query(_ rect: CGRect) -> [Int] {
        guard !rect.isNull, !rect.isInfinite, rect.width >= 0, rect.height >= 0 else { return [] }
        let area = rect.intersection(extent)
        guard !area.isNull else { return [] }
        let x0 = Int(floor(area.minX / cellSize)), x1 = Int(floor(area.maxX / cellSize))
        let y0 = Int(floor(area.minY / cellSize)), y1 = Int(floor(area.maxY / cellSize))
        if Double(x1 - x0 + 1) * Double(y1 - y0 + 1) > 4096 {
            return bounds.keys.filter { bounds[$0]!.intersects(rect) }.sorted()
        }
        var candidates = Set(overflow)
        for y in y0...y1 { for x in x0...x1 { candidates.formUnion(cells[Cell(x: x, y: y)] ?? []) } }
        return candidates.filter { bounds[$0]!.intersects(rect) }.sorted()
    }
    public func hit(_ point: CGPoint, layers: [StickerLayer], matching predicate: (StickerLayer) -> Bool = { _ in true }) -> StickerLayer? {
        query(CGRect(x: point.x - 0.001, y: point.y - 0.001, width: 0.002, height: 0.002))
            .reversed().compactMap { layers.indices.contains($0) ? layers[$0] : nil }
            .first { $0.visible && predicate($0) && $0.contains(point) }
    }
}

public struct SnapGuide: Equatable {
    public let vertical: Bool
    public let position: CGFloat
    public let from: CGFloat
    public let to: CGFloat
}
public struct SnapResult {
    public var center: CGPoint
    public var guides: [SnapGuide]
}
public enum LayerSnapping {
    public static func move(_ layer: StickerLayer, canvas: CGSize, layers: [StickerLayer], index: LayerSpatialIndex,
                            scale: Double, previous: [SnapGuide] = []) -> SnapResult {
        let threshold = 6 / max(0.00001, scale), box = layer.canvasBounds
        guard !box.isNull else { return SnapResult(center: layer.center, guides: []) }
        let extent = index.extent.union(CGRect(origin: .zero, size: canvas))
        let vertical = CGRect(x: box.minX - threshold * 1.5, y: extent.minY, width: box.width + threshold * 3, height: extent.height)
        let horizontal = CGRect(x: extent.minX, y: box.minY - threshold * 1.5, width: extent.width, height: box.height + threshold * 3)
        let candidates = Set(index.query(vertical) + index.query(horizontal))
        var references = [CGRect(origin: .zero, size: canvas)]
        references += candidates.sorted().compactMap { layers[$0].id == layer.id ? nil : layers[$0].canvasBounds }
        var center = layer.center, guides: [SnapGuide] = []
        for axis in [true, false] {
            let edges = axis ? [box.minX, box.midX, box.maxX] : [box.minY, box.midY, box.maxY]
            var best: (delta: CGFloat, guide: SnapGuide)?
            for reference in references where !reference.isNull {
                let targets = axis ? [reference.minX, reference.midX, reference.maxX] : [reference.minY, reference.midY, reference.maxY]
                for target in targets {
                    let sticky = previous.contains { $0.vertical == axis && abs($0.position - target) < 0.01 }
                    for edge in edges {
                        let delta = target - edge, limit = threshold * (sticky ? 1.5 : 1)
                        if abs(delta) <= limit && (best == nil || abs(delta) < abs(best!.delta) - 0.001) {
                            best = (delta, SnapGuide(vertical: axis, position: target,
                                from: axis ? min(reference.minY, box.minY) : min(reference.minX, box.minX),
                                to: axis ? max(reference.maxY, box.maxY) : max(reference.maxX, box.maxX)))
                        }
                    }
                }
            }
            if let best {
                if axis { center.x += best.delta } else { center.y += best.delta }
                guides.append(best.guide)
            }
        }
        return SnapResult(center: center, guides: guides)
    }
}
