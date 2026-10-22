import Foundation
import ImageIO
import Vision

public enum ViewerTools {
    /// ImageIO applies EXIF orientation and downsamples without decoding a full-sized bitmap.
    public static func thumbnail(_ url: URL, maxDimension: Int = 240) throws -> CGImage {
        if url.pathExtension.lowercased() == "svg" {
            return try SVGImageRenderer.render(url, maxDimension: maxDimension).bitmap
        }
        guard maxDimension > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImageFailure.unreadable }
        return image
    }

    /// Runs entirely on the device. Call from a background task.
    public static func recognizeText(in image: CGImage, cancellation: ((@escaping () -> Void) -> Void)? = nil) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
        request.automaticallyDetectsLanguage = true
        cancellation? { request.cancel() }
        try Task.checkCancellation()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
