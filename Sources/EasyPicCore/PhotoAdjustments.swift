import Foundation
import CoreImage

/// Neutral, signed controls are stored with the document, never baked into its source.
public struct PhotoAdjustments: Codable, Equatable, Sendable {
    public var exposure: Double = 0
    public var brightness: Double = 0
    public var contrast: Double = 0
    public var saturation: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var temperature: Double = 0
    public var tint: Double = 0
    public var sharpen: Double = 0
    public init() {}
    public var isNeutral: Bool { self == Self() }
    public var isValid: Bool {
        (-3...3).contains(exposure) &&
        [brightness, contrast, saturation, highlights, shadows, temperature, tint].allSatisfy {
            $0.isFinite && (-100...100).contains($0)
        } && (0...100).contains(sharpen)
    }
}

public enum PhotoAdjustmentEngine {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func render(_ source: CGImage, settings: PhotoAdjustments) throws -> CGImage {
        guard settings.isValid else { throw ImageFailure.renderFailed }
        try Task.checkCancellation()
        guard !settings.isNeutral else { return source }
        var image = CIImage(cgImage: source)
        let extent = image.extent
        if settings.temperature != 0 || settings.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + settings.temperature * 35, y: settings.tint)
            ])
        }
        if settings.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": settings.exposure])
        }
        if settings.highlights != 0 || settings.shadows != 0 {
            // Independent smooth tonal bands; signed values can both brighten and darken.
            let shadow = settings.shadows / 100, highlight = settings.highlights / 100
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + shadow * 0.2),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + (shadow + highlight) * 0.025),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + highlight * 0.2),
                "inputPoint4": CIVector(x: 1, y: 1)
            ])
        }
        if settings.brightness != 0 || settings.contrast != 0 || settings.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputBrightness": settings.brightness / 200,
                "inputContrast": 1 + settings.contrast / 100,
                "inputSaturation": 1 + settings.saturation / 100
            ])
        }
        if settings.sharpen != 0 {
            image = image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": settings.sharpen / 100
            ]).cropped(to: extent)
        }
        try Task.checkCancellation()
        guard let output = context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace)
        else { throw ImageFailure.renderFailed }
        try Task.checkCancellation()
        return output
    }
}

/// Single-flight, bounded previews avoid queuing a full-resolution render per pointer event.
public actor AdjustmentPreviewService {
    private var sourceKey: String?
    private var source: CGImage?
    public init() {}
    public func render(_ document: EditorDocument, resources: [UUID: CGImage], settings: PhotoAdjustments) throws -> CGImage {
        var original = document
        original.adjustments = nil; original.layers = []; original.activeLayerID = nil
        let key = original.contentKey
        if sourceKey != key || source == nil {
            let fullSize = try DocumentEngine.renderBase(original, resources: resources)
            let scale = min(1, 1600 / Double(max(fullSize.width, fullSize.height)))
            if scale == 1 { source = fullSize }
            else {
                let image = CIImage(cgImage: fullSize).applyingFilter("CILanczosScaleTransform", parameters: [
                    "inputScale": scale, "inputAspectRatio": 1
                ])
                let context = CIContext(options: [.cacheIntermediates: false])
                source = context.createCGImage(image, from: image.extent.integral)
            }
            guard source != nil else { throw ImageFailure.renderFailed }
            sourceKey = key
        }
        return try PhotoAdjustmentEngine.render(source!, settings: settings)
    }
}
