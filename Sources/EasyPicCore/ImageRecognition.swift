import Foundation
import Vision
import CoreGraphics

public struct RecognizedTextLine: Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    /// Normalized top-left coordinates in the complete source image.
    public let bounds: CGRect
    public let confidence: Float
    public init(text: String, bounds: CGRect, confidence: Float) {
        self.text = text; self.bounds = bounds; self.confidence = confidence
    }
}
public struct RecognizedQRCode: Identifiable, Equatable {
    public let id = UUID()
    public let payload: String
    public let bounds: CGRect
}
public struct ImageRecognitionResult: Equatable {
    public var lines: [RecognizedTextLine] = []
    public var codes: [RecognizedQRCode] = []
    public var text: String { lines.map(\.text).joined(separator: "\n") }
    public init() {}
}
public extension ViewerTools {
    static func recognize(in image: CGImage, region: CGRect? = nil, detectText: Bool = true, detectQRCodes: Bool = true,
                          cancellation: ((@escaping () -> Void) -> Void)? = nil) throws -> ImageRecognitionResult {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let normalized = (region ?? unit).intersection(unit)
        guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { throw ImageFailure.invalidCrop }
        let crop = CGRect(x: normalized.minX * CGFloat(image.width), y: normalized.minY * CGFloat(image.height),
                          width: normalized.width * CGFloat(image.width), height: normalized.height * CGFloat(image.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: crop) else { throw ImageFailure.invalidCrop }
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate; text.usesLanguageCorrection = true
        if detectText {
            let supported = try text.supportedRecognitionLanguages()
            text.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
        }
        text.automaticallyDetectsLanguage = true
        let qr = VNDetectBarcodesRequest(); qr.symbologies = [.qr]
        cancellation? { text.cancel(); qr.cancel() }
        try Task.checkCancellation()
        let requests: [VNRequest] = (detectText ? [text] : []) + (detectQRCodes ? [qr] : [])
        try VNImageRequestHandler(cgImage: cropped, orientation: .up).perform(requests)
        try Task.checkCancellation()
        func mapped(_ bounds: CGRect) -> CGRect {
            CGRect(x: (crop.minX + bounds.minX * crop.width) / CGFloat(image.width),
                   y: (crop.minY + (1 - bounds.maxY) * crop.height) / CGFloat(image.height),
                   width: bounds.width * crop.width / CGFloat(image.width), height: bounds.height * crop.height / CGFloat(image.height))
        }
        var result = ImageRecognitionResult()
        result.lines = (text.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextLine(text: candidate.string, bounds: mapped(observation.boundingBox), confidence: candidate.confidence)
        }
        result.codes = (qr.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue else { return nil }
            return RecognizedQRCode(payload: payload, bounds: mapped(observation.boundingBox))
        }
        return result
    }
}
