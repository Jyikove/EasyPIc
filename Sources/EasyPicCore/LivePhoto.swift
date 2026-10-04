import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum LivePhotoFailure: LocalizedError {
    case missingPair, invalidVideo, invalidEdit, export(String)
    public var errorDescription: String? {
        switch self {
        case .missingPair: return "未找到标识匹配的 Live Photo 照片与 MOV。请将从“照片”导出的未修改原片和视频放在同一文件夹。"
        case .invalidVideo: return "动态照片的视频无法读取，或时长、尺寸无效。"
        case .invalidEdit: return "Live Photo 只支持有效范围内的裁剪和封面选择。"
        case .export(let detail): return "Live Photo 导出失败：" + detail
        }
    }
}

public struct LivePhotoAsset: Sendable {
    public let photoURL: URL
    public let videoURL: URL
    public let identifier: String
    public let duration: Double
    public let originalCoverTime: Double
    public let photoSize: CGSize
    public let frameRate: Double
    public let embeddedVideo: MotionPhotoResource?
    public var kind: String { embeddedVideo == nil ? "Live Photo" : "Motion Photo" }
    public var lastFrameTime: Double { max(0, duration - 1 / frameRate) }
}

/// Normalized top-left coordinates in the original photo. nil cover keeps the original still.
public struct LivePhotoEdits: Equatable, Sendable {
    public var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    public var coverTime: Double?
    public init() {}
    public mutating func cropFurther(_ rect: CGRect, displayedSize: CGSize) throws {
        guard displayedSize.width > 0, displayedSize.height > 0,
              rect.width >= 2, rect.height >= 2,
              CGRect(origin: .zero, size: displayedSize).contains(rect),
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }) else {
            throw LivePhotoFailure.invalidEdit
        }
        crop = CGRect(x: crop.minX + rect.minX / displayedSize.width * crop.width,
                      y: crop.minY + rect.minY / displayedSize.height * crop.height,
                      width: rect.width / displayedSize.width * crop.width,
                      height: rect.height / displayedSize.height * crop.height)
    }
}

public struct LivePhotoHistory {
    public private(set) var edits = LivePhotoEdits()
    private var past: [LivePhotoEdits] = []
    private var future: [LivePhotoEdits] = []
    public init() {}
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public mutating func apply(_ next: LivePhotoEdits) {
        guard next != edits else { return }
        past.append(edits); edits = next; future.removeAll()
    }
    public mutating func undo() { if let last = past.popLast() { future.append(edits); edits = last } }
    public mutating func redo() { if let next = future.popLast() { past.append(edits); edits = next } }
}

public enum LivePhotoEngine {
    private static let stillTimeKey = "com.apple.quicktime.still-image-time"
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func photoIdentifier(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary] as? NSDictionary else { return nil }
        return (maker["17"] ?? maker[17]) as? String
    }

    public static func videoIdentifier(_ url: URL) async throws -> String? {
        let items = try await AVURLAsset(url: url).load(.metadata)
        for item in items where item.identifier == .quickTimeMetadataContentIdentifier {
            if let value = try await item.load(.stringValue), !value.isEmpty { return value }
        }
        return nil
    }

    /// Match embedded identifiers, never a filename alone. MOV input resolves back to the photo.
    public static func discover(_ input: URL) async throws -> LivePhotoAsset? {
        if let extracted = try MotionPhotoEngine.extract(input) {
            return try await inspect(photo: input, video: extracted.resource.url, identifier: "embedded-motion",
                                     embeddedVideo: extracted.resource, preferredCoverTime: extracted.coverTime)
        }
        let videoInput = input.pathExtension.lowercased() == "mov"
        guard let identifier = videoInput ? try await videoIdentifier(input) : photoIdentifier(input) else {
            if videoInput { throw LivePhotoFailure.missingPair }
            return nil
        }
        let files = try FileManager.default.contentsOfDirectory(at: input.deletingLastPathComponent(),
                    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted {
                let stem = input.deletingPathExtension().lastPathComponent
                let a = $0.deletingPathExtension().lastPathComponent == stem
                let b = $1.deletingPathExtension().lastPathComponent == stem
                return a != b ? a : $0.lastPathComponent < $1.lastPathComponent
            }
        if videoInput {
            for photo in files where ["heic", "heif", "jpg", "jpeg"].contains(photo.pathExtension.lowercased()) {
                try Task.checkCancellation()
                if photoIdentifier(photo) == identifier { return try await inspect(photo: photo, video: input, identifier: identifier) }
            }
        } else {
            for video in files where video.pathExtension.lowercased() == "mov" {
                try Task.checkCancellation()
                if (try? await videoIdentifier(video)) == identifier { return try await inspect(photo: input, video: video, identifier: identifier) }
            }
        }
        throw LivePhotoFailure.missingPair
    }

    private static func inspect(photo: URL, video: URL, identifier: String, embeddedVideo: MotionPhotoResource? = nil, preferredCoverTime: Double? = nil) async throws -> LivePhotoAsset {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              duration.isFinite, duration > 0 else { throw LivePhotoFailure.invalidVideo }
        let size = try await track.load(.naturalSize)
        guard size.width > 0, size.height > 0 else { throw LivePhotoFailure.invalidVideo }
        let rate = Double(try await track.load(.nominalFrameRate))
        let fps = rate.isFinite && rate > 0 ? rate : 30
        let image = try ImageEngine.load(photo).image
        let metadataTime = try? await coverTime(in: asset)
        let time = preferredCoverTime ?? metadataTime ?? duration / 2
        return LivePhotoAsset(photoURL: photo, videoURL: video, identifier: identifier, duration: duration,
                              originalCoverTime: min(max(0, time), max(0, duration - 1 / fps)),
                              photoSize: CGSize(width: image.width, height: image.height), frameRate: fps, embeddedVideo: embeddedVideo)
    }

    public static func coverTime(in asset: AVAsset) async throws -> Double? {
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { continue }
            defer { reader.cancelReading() }
            while let group = adaptor.nextTimedMetadataGroup() {
                if group.items.contains(where: { ($0.key as? String) == stillTimeKey || $0.identifier?.rawValue == "mdta/" + stillTimeKey }) {
                    return group.timeRange.start.seconds
                }
            }
        }
        return nil
    }

    public static func composition(for live: LivePhotoAsset, edits: LivePhotoEdits) async throws -> AVVideoComposition {
        try validate(edits, live: live)
        let asset = AVURLAsset(url: live.videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LivePhotoFailure.invalidVideo }
        let natural = try await track.load(.naturalSize)
        let orientation = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: natural).applying(orientation).standardized
        // Center aspect-fill when the paired still and motion have different aspect ratios.
        let photoRatio = live.photoSize.width / live.photoSize.height
        var base = bounds
        if bounds.width / bounds.height > photoRatio {
            base.size.width = bounds.height * photoRatio; base.origin.x += (bounds.width - base.width) / 2
        } else {
            base.size.height = bounds.width / photoRatio; base.origin.y += (bounds.height - base.height) / 2
        }
        let crop = CGRect(x: base.minX + edits.crop.minX * base.width, y: base.minY + edits.crop.minY * base.height,
                          width: edits.crop.width * base.width, height: edits.crop.height * base.height)
        guard crop.width >= 2, crop.height >= 2 else { throw LivePhotoFailure.invalidEdit }
        let renderSize = CGSize(width: max(2, floor(crop.width / 2) * 2), height: max(2, floor(crop.height / 2) * 2))
        let transform = orientation.concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .concatenating(CGAffineTransform(scaleX: renderSize.width / crop.width, y: renderSize.height / crop.height))
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: try await asset.load(.duration))))
        return AVVideoComposition(configuration: .init(
            frameDuration: CMTime(seconds: 1 / live.frameRate, preferredTimescale: 60000),
            instructions: [instruction], renderSize: renderSize))
    }

    public static func frame(_ live: LivePhotoAsset, edits: LivePhotoEdits, at time: Double) async throws -> (image: CGImage, time: Double) {
        guard time.isFinite, time >= 0, time <= live.lastFrameTime else { throw LivePhotoFailure.invalidEdit }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: live.videoURL))
        generator.videoComposition = try await composition(for: live, edits: edits)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000))
        return (result.image, result.actualTime.seconds)
    }

    public static func preview(_ live: LivePhotoAsset, original: CGImage, edits: LivePhotoEdits) async throws -> CGImage {
        try validate(edits, live: live)
        let rect = photoCrop(live, edits: edits)
        if let time = edits.coverTime {
            let image = try await frame(live, edits: edits, at: time).image
            let ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: rect.width / Double(image.width), y: rect.height / Double(image.height)))
            guard let rendered = context.createCGImage(ci, from: CGRect(origin: .zero, size: rect.size), format: .RGBA8,
                                                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw ImageFailure.renderFailed }
            return rendered
        }
        return try ImageEngine.render(original, operations: [.crop(rect)])
    }

    private static func photoCrop(_ live: LivePhotoAsset, edits: LivePhotoEdits) -> CGRect {
        CGRect(x: floor(edits.crop.minX * live.photoSize.width), y: floor(edits.crop.minY * live.photoSize.height),
               width: floor(edits.crop.width * live.photoSize.width), height: floor(edits.crop.height * live.photoSize.height))
    }
    private static func validate(_ edits: LivePhotoEdits, live: LivePhotoAsset) throws {
        let rect = edits.crop
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
              rect.width > 0, rect.height > 0, CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect),
              edits.coverTime.map({ $0.isFinite && $0 >= 0 && $0 <= live.lastFrameTime }) ?? true else {
            throw LivePhotoFailure.invalidEdit
        }
    }

    public static func writePhoto(_ image: CGImage, identifier: String, to url: URL) throws {
        guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw ImageFailure.writeFailed }
        CGImageDestinationAddImage(output, image, [kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImagePropertyOrientation: 1, kCGImageDestinationLossyCompressionQuality: 0.96] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ImageFailure.writeFailed }
    }

    /// Publish a complete pair by moving a staging folder only after both files validate.
    public static func export(_ live: LivePhotoAsset, original: CGImage, edits: LivePhotoEdits, to directory: URL) async throws {
        try validate(edits, live: live)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: directory.path) else { throw LivePhotoFailure.export("请选择一个不存在的新文件夹名称，以保留已有文件。") }
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".easypic-live-" + UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let identifier = UUID().uuidString
        let photo = staging.appendingPathComponent("LivePhoto.JPG"), video = staging.appendingPathComponent("LivePhoto.MOV")
        var cover = edits.coverTime ?? live.originalCoverTime
        let image: CGImage
        if let time = edits.coverTime {
            let selected = try await frame(live, edits: edits, at: time)
            image = selected.image; cover = selected.time
        } else { image = try await preview(live, original: original, edits: edits) }
        try writePhoto(image, identifier: identifier, to: photo)
        try await writeMovie(live, edits: edits, identifier: identifier, coverTime: cover, to: video)
        guard photoIdentifier(photo) == identifier, try await videoIdentifier(video) == identifier,
              let marker = try await coverTime(in: AVURLAsset(url: video)), abs(marker - cover) < 0.05 else {
            throw LivePhotoFailure.export("配对标识或封面时间验证失败。")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: staging, to: directory)
    }

    private static func writeMovie(_ live: LivePhotoAsset, edits: LivePhotoEdits, identifier: String, coverTime: Double, to url: URL) async throws {
        let asset = AVURLAsset(url: live.videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LivePhotoFailure.invalidVideo }
        let composition = try await composition(for: live, edits: edits)
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = composition
        reader.add(videoOutput)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let id = AVMutableMetadataItem(); id.identifier = .quickTimeMetadataContentIdentifier
        id.value = identifier as NSString; id.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [id]
        let size = composition.renderSize
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(20_000_000, max(1_000_000, Int(size.width * size.height * 8))) ]])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw LivePhotoFailure.invalidVideo }
        writer.add(videoInput)
        var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
            let formats = try await audio.load(.formatDescriptions)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first)
            guard reader.canAdd(output), writer.canAdd(input) else { throw LivePhotoFailure.export("无法保留此视频的声音。") }
            reader.add(output); writer.add(input); audioPair = (output, input)
        }
        var description: CMFormatDescription?
        let spec = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/" + stillTimeKey,
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String]
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
             metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw LivePhotoFailure.export("无法创建封面标记。") }
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        guard writer.canAdd(metadataInput) else { throw LivePhotoFailure.invalidVideo }
        writer.add(metadataInput)
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? LivePhotoFailure.invalidVideo }
        writer.startSession(atSourceTime: .zero)
        do {
            let marker = AVMutableMetadataItem(); marker.keySpace = .quickTimeMetadata
            marker.key = stillTimeKey as NSString; marker.value = NSNumber(value: Int8(0))
            marker.dataType = kCMMetadataBaseDataType_SInt8 as String
            let group = AVTimedMetadataGroup(items: [marker], timeRange: CMTimeRange(
                start: CMTime(seconds: coverTime, preferredTimescale: 60000), duration: composition.frameDuration))
            guard adaptor.append(group) else { throw writer.error ?? LivePhotoFailure.export("无法写入封面标记。") }
            metadataInput.markAsFinished()
            let sound = audioPair
            async let video: Void = pump(videoOutput, into: videoInput, writer: writer)
            async let audio: Void = pumpOptional(sound, writer: writer)
            try await video; try await audio
            guard reader.status == .completed else { throw reader.error ?? LivePhotoFailure.invalidVideo }
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? LivePhotoFailure.export("视频编码未完成。") }
        } catch { reader.cancelReading(); writer.cancelWriting(); throw error }
    }

    private static func pumpOptional(_ pair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?, writer: AVAssetWriter) async throws {
        if let (output, input) = pair { try await pump(output, into: input, writer: writer) }
    }
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        while true {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? LivePhotoFailure.export("视频写入中断。") }
            if !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)); continue }
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard input.append(sample) else { throw writer.error ?? LivePhotoFailure.export("无法写入视频或音频帧。") }
        }
        input.markAsFinished()
    }
}
