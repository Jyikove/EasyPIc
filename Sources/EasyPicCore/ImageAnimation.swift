import Foundation
import ImageIO
import Combine

public enum AnimationFormat: String, Sendable {
    case gif = "GIF", apng = "APNG", webP = "动态 WebP", heics = "HEIC 序列"
}

public struct AnimationMetadata: Sendable {
    public let format: AnimationFormat
    public let frameDurations: [TimeInterval]
    public var frameCount: Int { frameDurations.count }
    public var duration: TimeInterval { frameDurations.reduce(0, +) }
}

/// A multi-page TIFF is not an animation; a GIF is always opened read-only.
public struct ImageMediaInfo: Sendable {
    public let frameCount: Int
    public let animation: AnimationMetadata?
    public let isGIF: Bool
    public var isReadOnly: Bool { isGIF || animation != nil }

    static func read(from source: CGImageSource) -> ImageMediaInfo {
        let count = CGImageSourceGetCount(source)
        let type = CGImageSourceGetType(source) as String? ?? ""
        let isGIF = type == "com.compuserve.gif"
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let keys: (AnimationFormat, CFString, CFString, CFString)?
        if isGIF {
            keys = (.gif, kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime)
        } else if type == "public.png" {
            keys = (.apng, kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
        } else if type == "org.webmproject.webp" {
            keys = (.webP, kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
        } else if first[kCGImagePropertyHEICSDictionary] != nil {
            keys = (.heics, kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime)
        } else { keys = nil }
        guard count > 1, let (format, dictionaryKey, rawDelayKey, delayKey) = keys else {
            return ImageMediaInfo(frameCount: count, animation: nil, isGIF: isGIF)
        }
        let durations = (0..<count).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let animation = properties?[dictionaryKey] as? [CFString: Any]
            let raw = (animation?[rawDelayKey] as? NSNumber)?.doubleValue
            let delay = (animation?[delayKey] as? NSNumber)?.doubleValue
            // Prefer unadjusted timing (e.g. 20ms), while guarding corrupt/zero delays.
            let value = raw ?? delay ?? 0.1
            return value.isFinite && value >= 0.01 ? value : 0.1
        }
        return ImageMediaInfo(frameCount: count,
                              animation: AnimationMetadata(format: format, frameDurations: durations), isGIF: isGIF)
    }
}

/// Uses a monotonic timeline, so delayed decoding skips ahead instead of slowing playback.
public struct AnimationTimeline: Sendable {
    private let ends: [TimeInterval]
    public let duration: TimeInterval
    public init(_ metadata: AnimationMetadata) {
        var sum = 0.0
        ends = metadata.frameDurations.map { sum += $0; return sum }
        duration = sum
    }
    public func frameIndex(at elapsed: TimeInterval) -> Int {
        let time = position(elapsed)
        var low = 0, high = ends.count
        while low < high {
            let mid = (low + high) / 2
            if time < ends[mid] { high = mid } else { low = mid + 1 }
        }
        return min(low, ends.count - 1)
    }
    public func frameStart(_ index: Int) -> TimeInterval { index > 0 ? ends[index - 1] : 0 }
    public func timeUntilNextFrame(at elapsed: TimeInterval) -> TimeInterval {
        ends[frameIndex(at: elapsed)] - position(elapsed)
    }
    private func position(_ elapsed: TimeInterval) -> TimeInterval {
        guard elapsed.isFinite, elapsed >= 0 else { return 0 }
        return elapsed.truncatingRemainder(dividingBy: duration)
    }
}

private actor AnimationFrameDecoder {
    private let url: URL
    private var source: CGImageSource?
    init(url: URL) { self.url = url }
    func frame(at index: Int) throws -> CGImage {
        if source == nil {
            // ImageIO composes GIF/APNG/WebP partial frames and disposal internally.
            source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let source,
              let image = CGImageSourceCreateImageAtIndex(source, index,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ImageFailure.unreadable }
        return image
    }
}

@MainActor
public final class ImagePlayback: ObservableObject {
    @Published public private(set) var frame: CGImage?
    @Published public private(set) var frameIndex = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var error: String?
    private var metadata: AnimationMetadata?
    private var decoder: AnimationFrameDecoder?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    public init() {}
    deinit { task?.cancel() }

    public func configure(url: URL, poster: CGImage, animation: AnimationMetadata?) {
        clear()
        guard let animation else { return }
        metadata = animation
        decoder = AnimationFrameDecoder(url: url)
        frame = poster
        play()
    }
    public func pause() {
        generation = UUID()
        task?.cancel()
        task = nil
        isPlaying = false
    }
    public func play() {
        guard !isPlaying, let metadata, let decoder else { return }
        error = nil
        isPlaying = true
        let token = UUID()
        generation = token
        let timeline = AnimationTimeline(metadata)
        let started = ProcessInfo.processInfo.systemUptime - timeline.frameStart(frameIndex)
        task = Task { [weak self] in
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let index = timeline.frameIndex(at: elapsed)
                do {
                    let image = try await decoder.frame(at: index)
                    // Old-file decodes must not replace a new file, or advance a paused frame.
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.frame = image
                    self.frameIndex = index
                    let now = ProcessInfo.processInfo.systemUptime - started
                    let delay = max(0.001, timeline.timeUntilNextFrame(at: now))
                    try await Task.sleep(for: .seconds(delay))
                } catch is CancellationError { return }
                catch {
                    guard let self, self.generation == token else { return }
                    self.isPlaying = false
                    self.error = "动图播放失败：" + error.localizedDescription
                    return
                }
            }
        }
    }
    public func restart() { pause(); frameIndex = 0; play() }
    public func toggle() { if isPlaying { pause() } else { play() } }
    public func clear() {
        pause()
        metadata = nil
        decoder = nil
        frame = nil
        frameIndex = 0
        error = nil
    }
}
