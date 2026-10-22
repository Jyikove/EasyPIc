import Foundation
import AVFoundation
import CoreImage
import Combine

private actor LiveFrameRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    func render(_ pixel: CVPixelBuffer) throws -> CGImage {
        let image = CIImage(cvPixelBuffer: pixel)
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw ImageFailure.renderFailed }
        return result
    }
}

@MainActor
public final class LivePhotoPlayback: ObservableObject {
    public let player = AVPlayer()
    @Published public private(set) var frame: CGImage?
    @Published public private(set) var position = 0.0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var showingMotion = false
    @Published public private(set) var error: String?
    @Published public var muted = true { didSet { player.isMuted = muted } }
    private var live: LivePhotoAsset?
    private var output: AVPlayerItemVideoOutput?
    private var frameTask: Task<Void, Never>?
    private let renderer = LiveFrameRenderer()
    private var ended: NSObjectProtocol?
    private var generation = UUID()
    public init() { player.isMuted = true }
    deinit {
        frameTask?.cancel()
        if let ended { NotificationCenter.default.removeObserver(ended) }
    }
    public func configure(_ live: LivePhotoAsset, composition: AVVideoComposition, coverTime: Double? = nil) {
        clear()
        self.live = live
        let item = AVPlayerItem(url: live.videoURL)
        item.videoComposition = composition
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.suppressesPlayerRendering = false
        item.add(videoOutput); output = videoOutput
        player.replaceCurrentItem(with: item)
        ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.showCover()
            }
        }
        position = coverTime ?? live.originalCoverTime
    }
    public func seek(_ time: Double) {
        guard let live, time.isFinite else { return }
        pause()
        position = min(live.lastFrameTime, max(0, time))
        showingMotion = true
        let token = generation
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: position, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished, self.generation == token else { return }
                self.startFrames()
            }
        }
    }
    public func play() {
        guard live != nil, !isPlaying else { return }
        showingMotion = true; isPlaying = true; error = nil
        player.play(); startFrames()
    }
    public func restart() {
        guard live != nil else { return }
        pause(); position = 0; showingMotion = true
        let token = generation
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished, self.generation == token else { return }
                self.play()
            }
        }
    }
    public func toggle() { if isPlaying { pause() } else if showingMotion { play() } else { restart() } }
    public func pause() {
        generation = UUID(); frameTask?.cancel(); frameTask = nil
        player.pause(); isPlaying = false
    }
    public func showCover() { pause(); showingMotion = false }
    public func clear() {
        pause()
        if let ended { NotificationCenter.default.removeObserver(ended) }; ended = nil
        player.replaceCurrentItem(with: nil); live = nil; output = nil
        frame = nil; showingMotion = false; position = 0; error = nil
    }
    private func startFrames() {
        frameTask?.cancel()
        guard let output, let item = player.currentItem, let live else { return }
        let token = UUID(); generation = token
        frameTask = Task { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                guard let self, self.generation == token, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.error = item.error?.localizedDescription ?? L10n.text("动态照片播放失败。")
                    self.pause(); return
                }
                let time = self.player.currentTime()
                if self.isPlaying, time.seconds.isFinite { self.position = min(live.lastFrameTime, max(0, time.seconds)) }
                do {
                    // Native AVPlayerLayer owns continuous playback. Extract a bitmap
                    // only for the initial frame and an explicitly paused cover seek.
                    var displayedTime = CMTime.invalid
                    if (!self.isPlaying || self.frame == nil), output.hasNewPixelBuffer(forItemTime: time), let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayedTime) {
                        if !self.isPlaying, displayedTime.isValid,
                           abs(displayedTime.seconds - time.seconds) > 1.5 / live.frameRate {
                            try await Task.sleep(for: .milliseconds(16)); continue
                        }
                        let image = try await self.renderer.render(pixel)
                        guard self.generation == token, !Task.isCancelled else { return }
                        self.frame = image
                        if !self.isPlaying { return }
                    }
                    if !self.isPlaying, ProcessInfo.processInfo.systemUptime - started > 1 { return }
                    try await Task.sleep(for: .milliseconds(self.isPlaying ? 33 : 16))
                } catch is CancellationError { return }
                catch { self.error = error.localizedDescription; self.pause(); return }
            }
        }
    }
}
