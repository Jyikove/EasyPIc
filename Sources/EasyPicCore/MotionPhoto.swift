import Foundation

/// Owns the extracted movie for exactly as long as the loaded asset needs it.
public final class MotionPhotoResource: @unchecked Sendable {
    public let url: URL
    private let directory: URL
    init(data: Data) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EasyPic-Motion-" + UUID().uuidString)
        url = directory.appendingPathComponent("Motion.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do { try data.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

public struct MotionPhotoPayload: Sendable {
    public let videoRange: Range<Int>
    public let coverTime: Double?
}

/// JPEG-based Google Motion Photo v1 and legacy MicroVideo; ordinary JPEGs stay static.
public enum MotionPhotoEngine {
    public static func payload(in data: Data) throws -> MotionPhotoPayload? {
        guard data.count > 4, data[0] == 0xff, data[1] == 0xd8 else { return nil }
        let xmpHeader = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
        var position = 2
        while position + 4 <= data.count {
            guard data[position] == 0xff else { break }
            while position < data.count && data[position] == 0xff { position += 1 }
            guard position < data.count else { break }
            let marker = data[position]; position += 1
            if marker == 0xda || marker == 0xd9 { break }
            if marker == 0x01 || (0xd0...0xd8).contains(marker) { continue }
            guard position + 2 <= data.count else { break }
            let length = Int(data[position]) * 256 + Int(data[position + 1])
            guard length >= 2, length <= data.count - position else { break }
            let start = position + 2, end = position + length
            if marker == 0xe1, end - start > xmpHeader.count,
               data[start..<start + xmpHeader.count].elementsEqual(xmpHeader) {
                let metadata = MotionXMP()
                let parser = XMLParser(data: data.subdata(in: start + xmpHeader.count..<end))
                parser.shouldProcessNamespaces = true; parser.shouldReportNamespacePrefixes = true
                parser.shouldResolveExternalEntities = false; parser.delegate = metadata
                if parser.parse(), let result = try metadata.payload(fileSize: data.count) {
                    let range = result.videoRange
                    guard range.count >= 16,
                          data[range.lowerBound + 4..<range.lowerBound + 8].elementsEqual(Data("ftyp".utf8)) else {
                        throw LivePhotoFailure.invalidVideo
                    }
                    let boxLength = data[range.lowerBound..<range.lowerBound + 4].reduce(0) { ($0 << 8) | Int($1) }
                    guard boxLength >= 16, boxLength <= range.count else { throw LivePhotoFailure.invalidVideo }
                    return result
                }
            }
            position = end
        }
        return nil
    }

    public static func extract(_ url: URL) throws -> (resource: MotionPhotoResource, coverTime: Double?)? {
        // Only inspect JPEG candidates; a movie may be hundreds of MB.
        guard ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let payload = try payload(in: data) else { return nil }
        return (try MotionPhotoResource(data: data.subdata(in: payload.videoRange)), payload.coverTime)
    }
}

private final class MotionXMP: NSObject, XMLParserDelegate {
    private static let camera = "http://ns.google.com/photos/1.0/camera/"
    private static let container = "http://ns.google.com/photos/1.0/container/"
    private static let item = "http://ns.google.com/photos/1.0/container/item/"
    private var prefixes: [String: String] = [:]
    private var cameraValues: [String: String] = [:]
    private var items: [[String: String]] = []
    private var field: String?
    private var text = ""
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { prefixes[prefix] = namespaceURI }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        var item: [String: String] = [:]
        for (key, value) in attributes {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if prefixes[parts[0]] == Self.camera { cameraValues[parts[1]] = value }
            if prefixes[parts[0]] == Self.item { item[parts[1]] = value }
        }
        if namespaceURI == Self.container && elementName == "Item" { items.append(item) }
        if namespaceURI == Self.camera { field = elementName; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if field != nil { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if namespaceURI == Self.camera, field == elementName { cameraValues[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines); field = nil }
    }
    func payload(fileSize: Int) throws -> MotionPhotoPayload? {
        let modern = cameraValues["MotionPhoto"] != nil
        guard cameraValues[modern ? "MotionPhoto" : "MicroVideo"] == "1" else { return nil }
        let length: Int
        if modern {
            guard cameraValues["MotionPhotoVersion"] == "1", let last = items.last,
                  items.first?["Semantic"] == "Primary", last["Semantic"] == "MotionPhoto",
                  ["video/mp4", "video/quicktime"].contains(last["Mime"] ?? ""),
                  let bytes = Int(last["Length"] ?? "") else { throw LivePhotoFailure.invalidVideo }
            length = bytes
        } else {
            guard let bytes = Int(cameraValues["MicroVideoOffset"] ?? "") else { throw LivePhotoFailure.invalidVideo }
            length = bytes
        }
        guard length >= 16, length < fileSize - 4 else { throw LivePhotoFailure.invalidVideo }
        let microseconds = Double(cameraValues[modern ? "MotionPhotoPresentationTimestampUs" : "MicroVideoPresentationTimestampUs"] ?? "")
        let cover = microseconds.flatMap { $0.isFinite && $0 >= 0 ? $0 / 1_000_000 : nil }
        return MotionPhotoPayload(videoRange: fileSize - length..<fileSize, coverTime: cover)
    }
}
