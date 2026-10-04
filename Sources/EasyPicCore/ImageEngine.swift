import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum ImageFailure: LocalizedError {
    case unreadable, renderFailed, invalidCrop, writeFailed
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取这张图片。文件可能损坏，或系统不支持此格式。"
        case .renderFailed: return "图片处理失败。请尝试较小的图片。"
        case .invalidCrop: return "裁剪范围过小或超出了图片边界。"
        case .writeFailed: return "无法写入导出文件。请检查空间和文件夹权限。"
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
    public var frameCount: Int { mediaInfo.frameCount }
}

public enum ImageEngine {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func load(_ url: URL) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ImageFailure.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        let oriented = normalize(CIImage(cgImage: decoded).oriented(forExifOrientation: orientation))
        return LoadedImage(image: try bitmap(oriented), mediaInfo: ImageMediaInfo.read(from: source))
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
        var result = image
        // JPEG has no alpha channel; explicitly composite transparency onto white.
        if format == .jpg {
            let foreground = CIImage(cgImage: image)
            let white = CIImage(color: CIColor.white).cropped(to: foreground.extent)
            result = try bitmap(foreground.composited(over: white))
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil)
        else { throw ImageFailure.writeFailed }
        let options = [kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality))] as CFDictionary
        CGImageDestinationAddImage(destination, result, options)
        guard CGImageDestinationFinalize(destination) else { throw ImageFailure.writeFailed }
        return data as Data
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
