import Foundation
import CoreGraphics

public enum ImageCompression {
    public static func dimensions(_ image: CGImage, scale: Double) -> CGSize {
        let factor = scale.isFinite ? min(1, max(0.01, scale)) : 1
        return CGSize(width: max(1, (Double(image.width) * factor).rounded()),
                      height: max(1, (Double(image.height) * factor).rounded()))
    }

    /// The same encoder serves size measurement and the final file, so the
    /// displayed byte count includes the selected format, quality and scale.
    public static func encode(_ image: CGImage, format: ExportFormat, quality: Double, scale: Double = 1) throws -> Data {
        try Task.checkCancellation()
        let size = dimensions(image, scale: scale)
        let output: CGImage
        if Int(size.width) == image.width && Int(size.height) == image.height {
            output = image
        } else {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ImageFailure.renderFailed
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
            guard let resized = context.makeImage() else { throw ImageFailure.renderFailed }
            output = resized
        }
        try Task.checkCancellation()
        let data = try ImageEngine.encode(output, format: format, quality: quality)
        try Task.checkCancellation()
        return data
    }
}
