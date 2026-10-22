import Foundation
import UniformTypeIdentifiers

final class FolderIndexCache: @unchecked Sendable {
    static let shared = FolderIndexCache()
    private struct Entry { let stamp: Date; let files: [URL] }
    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]
    func pictures(in directory: URL) -> [URL] {
        let stamp = ((try? FileManager.default.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date) ?? .distantPast
        lock.lock(); let existing = entries[directory]; lock.unlock()
        if stamp != .distantPast, let existing, existing.stamp == stamp { return existing.files }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []).filter {
            guard let values = try? $0.resourceValues(forKeys: keys), values.isRegularFile == true else { return false }
            return values.contentType?.conforms(to: .image) == true || $0.pathExtension.lowercased() == "svg"
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        lock.lock()
        if entries.count >= 8 { entries.removeAll(keepingCapacity: true) }
        entries[directory] = Entry(stamp: stamp, files: files)
        lock.unlock()
        return files
    }
}
