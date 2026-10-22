import Foundation
import CoreGraphics

/// Rebuildable bitmaps have a shared byte budget. Source references prevent identity reuse.
final class RenderCache {
    static let shared = RenderCache()
    private final class Entry {
        let image: CGImage
        let source: CGImage?
        init(_ image: CGImage, source: CGImage?) { self.image = image; self.source = source }
    }
    private let images = NSCache<NSString, Entry>()
    init() { images.totalCostLimit = 96 * 1024 * 1024; images.countLimit = 128 }
    func image(key: String, source: CGImage? = nil, create: () throws -> CGImage) throws -> CGImage {
        try Task.checkCancellation()
        if let entry = images.object(forKey: key as NSString) { return entry.image }
        let result = try create()
        try Task.checkCancellation()
        let cost = result.bytesPerRow * result.height + (source.map { $0 === result ? 0 : $0.bytesPerRow * $0.height } ?? 0)
        if cost <= 96 * 1024 * 1024 { images.setObject(Entry(result, source: source), forKey: key as NSString, cost: cost) }
        return result
    }
    static func key<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value).base64EncodedString()) ?? UUID().uuidString
    }
}

/// One synchronous render at a time per document. Cancelled waiting jobs do no drawing.
public actor DocumentRenderService {
    private let compositor = TiledCompositor()
    public init() {}
    public func render(_ document: EditorDocument, resources: [UUID: CGImage], base: CGImage?, trace: UUID? = nil) throws -> (CGImage, CGImage) {
        try Task.checkCancellation()
        InteractionMetrics.shared.mark(trace, "BaseRenderBegin")
        let background = try base ?? DocumentEngine.renderBase(document, resources: resources)
        InteractionMetrics.shared.mark(trace, "BaseReady")
        try Task.checkCancellation()
        return (background, try compositor.render(document, resources: resources, base: background, trace: trace))
    }
    public func layer(_ layer: StickerLayer, resources: [UUID: CGImage]) throws -> CGImage {
        try Task.checkCancellation()
        // Only an oversized interactive text texture is bounded. Final rendering
        // draws Core Text directly into the original-resolution output context.
        return try DocumentEngine.layerBitmap(layer, resources: resources, maxTextDimension: 4096)
    }
}

/// Only immutable source images are reused. Atomic project validation remains unchanged.
final class ProjectResourceCache {
    static let shared = ProjectResourceCache()
    private final class Entry {
        let source: CGImage
        let data: Data
        init(_ source: CGImage, _ data: Data) { self.source = source; self.data = data }
    }
    private let cache = NSCache<NSString, Entry>()
    init() { cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 64 }
    func png(_ image: CGImage, id: UUID) throws -> Data {
        let key = "\(id):\(ObjectIdentifier(image))" as NSString
        if let entry = cache.object(forKey: key) { return entry.data }
        let data = try ImageEngine.encode(image, format: .png)
        let cost = data.count + image.bytesPerRow * image.height
        if cost <= 32 * 1024 * 1024 { cache.setObject(Entry(image, data), forKey: key, cost: cost) }
        return data
    }
}
