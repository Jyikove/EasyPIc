import Foundation
import CoreGraphics

/// Shared, bounded original-image cache. File metadata is checked on every lookup.
public actor ImageLoadingService {
    public static let shared = ImageLoadingService()
    private final class Entry {
        let loaded: LoadedImage
        init(_ loaded: LoadedImage) { self.loaded = loaded }
    }
    private let cache = NSCache<NSString, Entry>()
    public init() { cache.totalCostLimit = 64 * 1024 * 1024; cache.countLimit = 8 }
    private func key(_ url: URL) throws -> NSString {
        // URL resourceValues can cache stale metadata across an atomic file replacement.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(url.standardizedFileURL.path):\((values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(values[.size] ?? 0):\(values[.systemFileNumber] ?? 0)" as NSString
    }
    public func image(_ url: URL) throws -> LoadedImage {
        try Task.checkCancellation()
        let key = try key(url)
        if let entry = cache.object(forKey: key) { return entry.loaded }
        let loaded = try ImageEngine.load(url)
        try Task.checkCancellation()
        let cost = loaded.image.bytesPerRow * loaded.image.height
        if cost <= 64 * 1024 * 1024 { cache.setObject(Entry(loaded), forKey: key, cost: cost) }
        return loaded
    }
    public func prefetch(_ url: URL) throws {
        try Task.checkCancellation()
        // Avoid allocating an original that cannot fit in the prefetch budget.
        guard url.pathExtension.lowercased() != "svg", let size = try? ImageEngine.dimensions(url),
              size.width * size.height * 4 <= 32 * 1024 * 1024 else { return }
        _ = try image(url)
    }
}
