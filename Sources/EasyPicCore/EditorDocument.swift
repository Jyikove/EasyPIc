import Foundation
import CoreGraphics


public struct StickerLayer: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var resourceID: UUID
    public var strokes: [BrushStroke]? = nil
    public var text: TextLayer? = nil
    public var svgData: Data? = nil
    public var name: String
    public var center: CGPoint
    public var size: CGSize
    public var angle: Double = 0
    public var opacity: Double = 1
    public var visible = true
    public var mirrored = false
    // Each polygon clips content to a previous canvas before a crop or transform.
    public var clips: [[CGPoint]] = []
    public init(resourceID: UUID, name: String, center: CGPoint, size: CGSize) {
        self.resourceID = resourceID; self.name = name; self.center = center; self.size = size
    }
    public var rasterKey: String {
        if let text { return "\(size.width):\(size.height):" + RenderCache.key(text) }
        if svgData != nil { return "svg:\(resourceID):\(size.width):\(size.height):" + RenderCache.key(strokes ?? []) }
        return RenderCache.key(strokes ?? [])
    }
    public func contains(_ point: CGPoint) -> Bool {
        for polygon in clips {
            let path = CGMutablePath(); path.addLines(between: polygon); path.closeSubpath()
            if !path.contains(point) { return false }
        }
        let dx = point.x - center.x, dy = point.y - center.y
        let a = angle * .pi / 180
        return abs(dx * cos(a) + dy * sin(a)) <= size.width / 2 && abs(-dx * sin(a) + dy * cos(a)) <= size.height / 2
    }
}

public struct EditorDocument: Codable, Equatable {
    public var version = 1
    public var baseResourceID: UUID
    public var originalSize: CGSize
    public var baseStrokes: [BrushStroke]? = nil
    public var operations: [EditOperation] = []
    public var layers: [StickerLayer] = []
    public var activeLayerID: UUID?
    public init(baseResourceID: UUID, size: CGSize) { self.baseResourceID = baseResourceID; originalSize = size }
    public var contentKey: String { RenderCache.key(self) }
    public var referencedResourceIDs: Set<UUID> {
        Set([baseResourceID] + layers.filter { $0.text == nil }.map(\.resourceID))
    }
    public var size: CGSize {
        operations.reduce(originalSize) { size, op in
            switch op { case .clockwise, .counterclockwise: return CGSize(width: size.height, height: size.width)
            case .crop(let r): return CGSize(width: floor(r.width), height: floor(r.height))
            default: return size }
        }
    }
    public mutating func apply(_ op: EditOperation) throws {
        let old = size
        if case .crop(let r) = op {
            guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite,
                  r.width >= 1, r.height >= 1, CGRect(origin: .zero, size: old).contains(r) else { throw ImageFailure.invalidCrop }
        }
        func map(_ p: CGPoint) -> CGPoint {
            switch op {
            case .clockwise: return CGPoint(x: old.height - p.y, y: p.x)
            case .counterclockwise: return CGPoint(x: p.y, y: old.width - p.x)
            case .mirrorHorizontal: return CGPoint(x: old.width - p.x, y: p.y)
            case .mirrorVertical: return CGPoint(x: p.x, y: old.height - p.y)
            case .crop(let r): return CGPoint(x: p.x - floor(r.minX), y: p.y - floor(r.minY))
            }
        }
        for i in layers.indices {
            layers[i].clips.append([.zero, CGPoint(x: old.width, y: 0), CGPoint(x: old.width, y: old.height), CGPoint(x: 0, y: old.height)])
            layers[i].clips = layers[i].clips.map { $0.map(map) }
            layers[i].center = map(layers[i].center)
            switch op {
            case .clockwise: layers[i].angle += 90
            case .counterclockwise: layers[i].angle -= 90
            case .mirrorHorizontal: layers[i].angle = -layers[i].angle; layers[i].mirrored.toggle()
            case .mirrorVertical: layers[i].angle = 180 - layers[i].angle; layers[i].mirrored.toggle()
            case .crop: break
            }
        }
        if case .crop(let r) = op {
            operations.append(.crop(CGRect(x: floor(r.minX), y: floor(r.minY), width: floor(r.width), height: floor(r.height))))
        } else { operations.append(op) }
    }
}

public struct DocumentHistory {
    public private(set) var document: EditorDocument
    private var past: [EditorDocument] = []
    private var future: [EditorDocument] = []
    public init(_ document: EditorDocument) { self.document = document }
    public var referencedResourceIDs: Set<UUID> {
        var ids = document.referencedResourceIDs
        for snapshot in past { ids.formUnion(snapshot.referencedResourceIDs) }
        for snapshot in future { ids.formUnion(snapshot.referencedResourceIDs) }
        return ids
    }
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public mutating func apply(_ next: EditorDocument) {
        guard next != document else { return }; past.append(document); document = next; future.removeAll()
    }
    public mutating func undo() { if let next = past.popLast() { future.append(document); document = next } }
    public mutating func redo() { if let next = future.popLast() { past.append(document); document = next } }
}

public enum DocumentEngine {
    public static func renderBase(_ document: EditorDocument, resources: [UUID: CGImage]) throws -> CGImage {
        guard var image = resources[document.baseResourceID] else { throw ImageFailure.unreadable }
        image = try stroked(image, strokes: document.baseStrokes ?? [])
        return try ImageEngine.render(image, operations: document.operations)
    }
    private static func stroked(_ image: CGImage, strokes: [BrushStroke]) throws -> CGImage {
        guard !strokes.isEmpty else { return image }
        var result = image
        var prefix: [BrushStroke] = []
        for stroke in strokes {
            try Task.checkCancellation()
            prefix.append(stroke)
            let key = "strokes:\(ObjectIdentifier(image)):\(RenderCache.key(prefix))"
            let previous = result
            result = try RenderCache.shared.image(key: key, source: image) { try BrushEngine.apply(stroke, to: previous) }
        }
        return result
    }

    public static func layerBitmap(_ layer: StickerLayer, resources: [UUID: CGImage], maxTextDimension: CGFloat? = nil) throws -> CGImage {
        if let text = layer.text {
            guard text.isValid else { throw ImageFailure.renderFailed }
            let scale = maxTextDimension.map { min(1, $0 / max(layer.size.width, layer.size.height)) } ?? 1
            let width = max(1, Int(ceil(layer.size.width * scale))), height = max(1, Int(ceil(layer.size.height * scale)))
            let key = "text:\(width):\(height):" + layer.rasterKey
            return try RenderCache.shared.image(key: key) {
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageFailure.renderFailed }
                context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
                context.scaleBy(x: CGFloat(width) / layer.size.width, y: -CGFloat(height) / layer.size.height)
                TextRenderer.draw(text, size: layer.size, in: context)
                guard let image = context.makeImage() else { throw ImageFailure.renderFailed }
                return image
            }
        }
        if let data = layer.svgData, layer.strokes?.isEmpty != false {
            let limit = maxTextDimension ?? max(layer.size.width, layer.size.height)
            let scale = min(1, limit / max(layer.size.width, layer.size.height))
            return try RenderCache.shared.image(key: "vector:" + layer.rasterKey + ":\(scale)") {
                try SVGImageRenderer.renderRegion(data: data, region: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                  pixelSize: CGSize(width: layer.size.width * scale, height: layer.size.height * scale))
            }
        }
        guard let image = resources[layer.resourceID] else { throw ImageFailure.unreadable }
        return try stroked(image, strokes: layer.strokes ?? [])
    }
    public static func render(_ document: EditorDocument, resources: [UUID: CGImage], base: CGImage? = nil, maxDimension: CGFloat? = nil) throws -> CGImage {
        try Task.checkCancellation()
        let background = try base ?? renderBase(document, resources: resources)
        if document.layers.allSatisfy({ !$0.visible }), maxDimension == nil { return background }
        let size = document.size
        let scale = maxDimension.map { min(1, $0 / max(size.width, size.height)) } ?? 1
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageFailure.renderFailed }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)
        func draw(_ image: CGImage, rect: CGRect) {
            context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
        }
        draw(background, rect: CGRect(origin: .zero, size: size))
        try drawLayers(document.layers, resources: resources, in: context)
        guard let result = context.makeImage() else { throw ImageFailure.renderFailed }; return result
    }
    static func drawLayers(_ layers: [StickerLayer], resources: [UUID: CGImage], in context: CGContext) throws {
        func draw(_ image: CGImage, rect: CGRect) {
            context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
        }
        for layer in layers where layer.visible {
            try Task.checkCancellation()
            context.saveGState()
            for polygon in layer.clips {
                context.beginPath(); context.addLines(between: polygon); context.closePath(); context.clip()
            }
            context.setAlpha(layer.opacity)
            context.translateBy(x: layer.center.x, y: layer.center.y); context.rotate(by: layer.angle * .pi / 180)
            if layer.mirrored { context.scaleBy(x: -1, y: 1) }
            if let text = layer.text { TextRenderer.draw(text, size: layer.size, in: context) }
            else if let svg = layer.svgData, layer.strokes?.isEmpty != false {
                context.translateBy(x: -layer.size.width / 2, y: layer.size.height / 2); context.scaleBy(x: 1, y: -1)
                context.setAlpha(1)
                try SVGImageRenderer.draw(data: svg, in: CGRect(origin: .zero, size: layer.size), context: context, opacity: layer.opacity)
            } else {
                let edited = try layerBitmap(layer, resources: resources)
                draw(edited, rect: CGRect(x: -layer.size.width / 2, y: -layer.size.height / 2, width: layer.size.width, height: layer.size.height))
            }
            context.restoreGState()
        }
    }
    /// Draw directly into a canvas-space region; never render a whole frame and then crop it.
    static func renderRegion(_ document: EditorDocument, resources: [UUID: CGImage], base: CGImage,
                             region: CGRect, candidates: [Int]) throws -> CGImage {
        guard let context = CGContext(data: nil, width: Int(region.width), height: Int(region.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageFailure.renderFailed }
        context.translateBy(x: 0, y: region.height); context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -region.minX, y: -region.minY)
        context.saveGState(); context.translateBy(x: 0, y: document.size.height); context.scaleBy(x: 1, y: -1)
        context.draw(base, in: CGRect(origin: .zero, size: document.size)); context.restoreGState()
        try drawLayers(candidates.map { document.layers[$0] }, resources: resources, in: context)
        guard let image = context.makeImage() else { throw ImageFailure.renderFailed }
        return image
    }
    public static func save(_ document: EditorDocument, resources: [UUID: CGImage], to url: URL) throws {
        try validate(document)
        let fm = FileManager.default
        let staging = url.deletingLastPathComponent().appendingPathComponent(".easypic-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let ids = Set([document.baseResourceID] + document.layers.filter { $0.text == nil }.map(\.resourceID))
        for id in ids {
            guard let image = resources[id] else { throw ImageFailure.unreadable }
            try ProjectResourceCache.shared.png(image, id: id).write(to: staging.appendingPathComponent(id.uuidString + ".png"), options: .atomic)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: staging.appendingPathComponent("document.json"), options: .atomic)
        _ = try load(staging)
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: staging) }
        else { try fm.moveItem(at: staging, to: url) }
    }
    public static func load(_ url: URL) throws -> (EditorDocument, [UUID: CGImage]) {
        let document = try JSONDecoder().decode(EditorDocument.self, from: Data(contentsOf: url.appendingPathComponent("document.json")))
        try validate(document)
        var resources: [UUID: CGImage] = [:]
        for id in Set([document.baseResourceID] + document.layers.filter { $0.text == nil }.map(\.resourceID)) {
            resources[id] = try ImageEngine.load(url.appendingPathComponent(id.uuidString + ".png")).image
        }
        guard let base = resources[document.baseResourceID], document.originalSize == CGSize(width: base.width, height: base.height) else { throw ImageFailure.unreadable }
        _ = try ImageEngine.render(base, operations: document.operations)
        return (document, resources)
    }
    private static func validate(_ d: EditorDocument) throws {
        guard d.version == 1, d.originalSize.width.isFinite, d.originalSize.height.isFinite, d.originalSize.width > 0, d.originalSize.height > 0,
              Set(d.layers.map(\.id)).count == d.layers.count else { throw ImageFailure.unreadable }
        guard (d.baseStrokes ?? []).allSatisfy(\.isValid) else { throw ImageFailure.unreadable }
        for l in d.layers {
            guard (l.strokes ?? []).allSatisfy(\.isValid) else { throw ImageFailure.unreadable }
            guard l.text?.isValid != false else { throw ImageFailure.unreadable }
            guard [l.center.x, l.center.y, l.size.width, l.size.height, l.angle, l.opacity].allSatisfy(\.isFinite),
                  l.size.width >= 1, l.size.height >= 1, (0...1).contains(l.opacity),
                  l.clips.allSatisfy({ $0.count >= 3 && $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else { throw ImageFailure.unreadable }
        }
    }
}
