import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import EasyPicCore

final class ImageEngineTests {
    // An asymmetric 3 × 2 image detects wrong rotation direction and crop origin.
    private let colors: [[UInt8]] = [
        [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255],
        [255, 255, 0, 255], [255, 0, 255, 255], [0, 255, 255, 255]
    ]
    private func fixture() -> CGImage {
        let bytes = Data(colors.flatMap { $0 })
        return CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func pixels(_ image: CGImage) -> [[UInt8]] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: bytes.count, by: 4).map { Array(bytes[$0..<($0 + 4)]) }
    }
    func testClockwisePixels() throws {
        let result = try ImageEngine.render(fixture(), operations: [.clockwise])
        try expectEqual(result.width, 2); try expectEqual(result.height, 3)
        try expectEqual(pixels(result), [colors[3], colors[0], colors[4], colors[1], colors[5], colors[2]])
    }
    func testCounterclockwiseAndRoundTrip() throws {
        let result = try ImageEngine.render(fixture(), operations: [.counterclockwise])
        try expectEqual(pixels(result), [colors[2], colors[5], colors[1], colors[4], colors[0], colors[3]])
        try expectEqual(pixels(try ImageEngine.render(fixture(), operations: [.clockwise, .clockwise, .clockwise, .clockwise])), colors)
    }
    func testMirrorPixels() throws {
        try expectEqual(pixels(try ImageEngine.render(fixture(), operations: [.mirrorHorizontal])), [colors[2], colors[1], colors[0], colors[5], colors[4], colors[3]])
        try expectEqual(pixels(try ImageEngine.render(fixture(), operations: [.mirrorVertical])), [colors[3], colors[4], colors[5], colors[0], colors[1], colors[2]])
    }
    func testTopLeftCropAndCropAfterRotation() throws {
        let rect = CGRect(x: 1, y: 0, width: 2, height: 1)
        try expectEqual(pixels(try ImageEngine.render(fixture(), operations: [.crop(rect)])), [colors[1], colors[2]])
        try expectEqual(pixels(try ImageEngine.render(fixture(), operations: [.clockwise, .crop(CGRect(x: 0, y: 0, width: 1, height: 2))])), [colors[3], colors[4]])
    }
    func testInvalidCropRejected() throws {
        for rect in [CGRect(x: -1, y: 0, width: 1, height: 1), CGRect(x: 2, y: 0, width: 2, height: 1), CGRect(x: 0, y: 0, width: 0, height: 1)] {
            try expectThrows { _ = try ImageEngine.render(fixture(), operations: [.crop(rect)]) }
        }
    }
    func testHistoryBranches() throws {
        var history = EditHistory()
        history.apply(.clockwise); history.apply(.mirrorHorizontal)
        history.undo(); history.undo(); history.redo()
        try expectEqual(history.operations, [.clockwise])
        try expect(history.canRedo)
        history.apply(.mirrorVertical)
        try expect(!history.canRedo)
        try expectEqual(history.operations, [.clockwise, .mirrorVertical])
    }
    func testPNGAndJPEGRoundTrip() throws {
        for format in ExportFormat.allCases {
            let data = try ImageEngine.encode(fixture(), format: format)
            let source = try unwrap(CGImageSourceCreateWithData(data as CFData, nil))
            try expectEqual(CGImageSourceGetType(source) as String?, format.type.identifier)
            let result = try unwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            try expectEqual(result.width, 3); try expectEqual(result.height, 2)
            if format == .png { try expectEqual(pixels(result), colors) }
        }
    }
    func testTransparencyAndJPEGWhiteBackground() throws {
        let bytes = Data([0, 0, 0, 0])
        let clear = try unwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        for format in ExportFormat.allCases {
            let data = try ImageEngine.encode(clear, format: format)
            let source = try unwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try unwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let pixel = try unwrap(pixels(image).first)
            if format == .png { try expectEqual(pixel[3], 0) }
            else { try expect(pixel[0] >= 250 && pixel[1] >= 250 && pixel[2] >= 250); try expectEqual(pixel[3], 255) }
        }
    }
    func testEXIFOrientationOnLoad() throws {
        let data = NSMutableData()
        let destination = try unwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, fixture(), [kCGImagePropertyOrientation: 6] as CFDictionary)
        try expect(CGImageDestinationFinalize(destination))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        try (data as Data).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try ImageEngine.load(url)
        try expectEqual(loaded.image.width, 2); try expectEqual(loaded.image.height, 3)
        try expectEqual(pixels(loaded.image), [colors[3], colors[0], colors[4], colors[1], colors[5], colors[2]])
    }
}
