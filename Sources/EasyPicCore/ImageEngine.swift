import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum ImageFailure: LocalizedError {
    case unreadable, renderFailed, invalidCrop, writeFailed, cannotReplace
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取这张图片。文件可能损坏，或系统不支持此格式。"
        case .renderFailed: return "图片处理失败。请尝试较小的图片。"
        case .invalidCrop: return "裁剪范围过小或超出了图片边界。"
        case .writeFailed: return "无法写入导出文件。请检查空间和文件夹权限。"
        case .cannotReplace: return "此原图暂不支持直接替换，请另存为 JPG 或 PNG。"
        }
    }
}

/// Crop coordinates use image pixels, with the origin at the top left.
public enum EditOperation: Codable, Equatable, Sendable {
    case clockwise, counterclockwise, mirrorHorizontal, mirrorVertical
    case crop(CGRect)
}

/// History stores commands, never a full-resolution bitmap per undo step.
public struct EditHistory: Sendable {
    public private(set) var operations: [EditOperation] = []
    private var future: [EditOperation] = []
    public init() {}
    public var canUndo: Bool { !operations.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public mutating func apply(_ operation: EditOperation) {
        operations.append(operation)
        future.removeAll()
    }
    public mutating func undo() {
        if let last = operations.popLast() { future.append(last) }
    }
    public mutating func redo() {
        if let next = future.popLast() { operations.append(next) }
    }
}

public enum ExportFormat: String, CaseIterable, Sendable {
    case png, jpg
    public var type: UTType { self == .png ? .png : .jpeg }
}

public struct LoadedImage {
    public let image: CGImage
    public let mediaInfo: ImageMediaInfo
    public let typeIdentifier: String
    public var frameCount: Int { mediaInfo.frameCount }
}

public enum ImageEngine {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let destinationTypes = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
    public static func canEncode(typeIdentifier: String) -> Bool { destinationTypes.contains(typeIdentifier) }

    public static func load(_ url: URL) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ImageFailure.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let oriented = normalize(CIImage(cgImage: decoded).oriented(forExifOrientation: orientation))
        return LoadedImage(image: try bitmap(oriented), mediaInfo: ImageMediaInfo.read(from: source),
                           typeIdentifier: CGImageSourceGetType(source) as String? ?? "")
    }

    public static func render(_ original: CGImage, operations: [EditOperation]) throws -> CGImage {
        var image = CIImage(cgImage: original)
        for operation in operations {
            switch operation {
            case .clockwise: image = image.oriented(.right)
            case .counterclockwise: image = image.oriented(.left)
            case .mirrorHorizontal: image = image.oriented(.upMirrored)
            case .mirrorVertical: image = image.oriented(.downMirrored)
            case .crop(let rect):
                let bounds = image.extent
                guard rect.width >= 1, rect.height >= 1,
                      rect.minX.isFinite, rect.minY.isFinite,
                      rect.width.isFinite, rect.height.isFinite,
                      CGRect(origin: .zero, size: bounds.size).contains(rect) else { throw ImageFailure.invalidCrop }
                let pixelRect = CGRect(x: floor(rect.minX), y: floor(rect.minY),
                                       width: floor(rect.width), height: floor(rect.height))
                image = image.cropped(to: CGRect(x: pixelRect.minX, y: bounds.height - pixelRect.maxY,
                                               width: pixelRect.width, height: pixelRect.height))
            }
            image = normalize(image)
        }
        return try bitmap(image)
    }

    public static func encode(_ image: CGImage, format: ExportFormat, quality: Double = 0.92) throws -> Data {
        try encode(image, typeIdentifier: format.type.identifier, quality: quality)
    }

    private static func encode(_ image: CGImage, typeIdentifier: String, quality: Double) throws -> Data {
        var result = image
        // JPEG has no alpha channel; explicitly composite transparency onto white.
        if typeIdentifier == UTType.jpeg.identifier {
            let foreground = CIImage(cgImage: image)
            let white = CIImage(color: CIColor.white).cropped(to: foreground.extent)
            result = try bitmap(foreground.composited(over: white))
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, typeIdentifier as CFString, 1, nil)
        else { throw ImageFailure.writeFailed }
        let options = [kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality))] as CFDictionary
        CGImageDestinationAddImage(destination, result, options)
        guard CGImageDestinationFinalize(destination) else { throw ImageFailure.writeFailed }
        return data as Data
    }

    /// Encode and validate fully before atomically replacing a single static source image.
    public static func replaceExisting(_ image: CGImage, at url: URL, quality: Double = 0.92) throws {
        guard url.isFileURL else { throw ImageFailure.cannotReplace }
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        guard (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let source = CGImageSourceCreateWithURL(target as CFURL, nil), CGImageSourceGetCount(source) == 1,
              !ImageMediaInfo.read(from: source).isReadOnly,
              let type = CGImageSourceGetType(source) as String?, canEncode(typeIdentifier: type) else {
            throw ImageFailure.cannotReplace
        }
        let data = try encode(image, typeIdentifier: type, quality: quality)
        guard let check = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(check) as String? == type,
              let decoded = CGImageSourceCreateImageAtIndex(check, 0, nil),
              decoded.width == image.width, decoded.height == image.height else { throw ImageFailure.writeFailed }
        try data.write(to: target, options: .atomic)
    }

    private static func normalize(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private static func bitmap(_ image: CIImage) throws -> CGImage {
        guard let output = context.createCGImage(image, from: image.extent.integral,
                                                 format: .RGBA8, colorSpace: outputColorSpace)
        else { throw ImageFailure.renderFailed }
        return output
    }
}
