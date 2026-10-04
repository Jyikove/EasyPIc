import Foundation
import CoreGraphics
import Combine
import EasyPicCore

@MainActor
final class AnimationTests {
    private let formats = ["Animated.gif", "Animated.png", "Animated.webp"]
    private let delays = [[0.08, 0.18, 0.32], [0.06, 0.13, 0.21], [0.08, 0.15, 0.30]]
    func url(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
    }
    func testReadOnlyDetection() throws {
        for name in formats + ["Renamed.jpg"] {
            let loaded = try ImageEngine.load(url(name))
            try expect(loaded.mediaInfo.isReadOnly)
            try expectEqual(loaded.mediaInfo.animation?.frameCount, 3)
        }
        let gif = try ImageEngine.load(url("Static.gif"))
        try expect(gif.mediaInfo.isReadOnly)
        try expect(gif.mediaInfo.animation == nil)
        let png = try ImageEngine.load(url("Static.png"))
        try expect(!png.mediaInfo.isReadOnly)
        let tiff = try ImageEngine.load(url("Pages.tiff"))
        try expectEqual(tiff.frameCount, 2)
        try expect(!tiff.mediaInfo.isReadOnly)
        try expect(tiff.mediaInfo.animation == nil)
    }
    func testTimingAndLoop() throws {
        for (name, expected) in zip(formats, delays) {
            let metadata = try unwrap(try ImageEngine.load(url(name)).mediaInfo.animation)
            for (actual, wanted) in zip(metadata.frameDurations, expected) { try expect(abs(actual - wanted) < 0.0001) }
            let timeline = AnimationTimeline(metadata)
            var start = 0.0
            for (index, delay) in expected.enumerated() {
                try expectEqual(timeline.frameIndex(at: start + delay * 0.5), index)
                try expect(abs(timeline.timeUntilNextFrame(at: start + delay * 0.5) - delay * 0.5) < 0.0001)
                start += delay
            }
            try expectEqual(timeline.frameIndex(at: metadata.duration + expected[0] / 2), 0)
            try expectEqual(timeline.frameIndex(at: metadata.duration * 12 + expected[0] + expected[1] / 2), 1)
            try expectEqual(timeline.frameIndex(at: -.infinity), 0)
        }
    }
    func testDecodedPlaybackAndDisposal() async throws {
        for name in formats {
            let loaded = try ImageEngine.load(url(name))
            let player = ImagePlayback()
            var seen: [Int: [[UInt8]]] = [:]
            let observation = player.$frameIndex.sink { index in
                if let frame = player.frame { seen[index] = self.pixels(frame) }
            }
            player.configure(url: url(name), poster: loaded.image, animation: loaded.mediaInfo.animation)
            defer { player.clear(); observation.cancel() }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while seen.count < 3 && player.error == nil && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try expect(player.error == nil)
            try expectEqual(seen.count, 3)
            for index in 0..<3 {
                let reference = try ImageEngine.load(url("\(name)-frame\(index).png"))
                try expectEqual(seen[index], pixels(reference.image))
            }
        }
    }
    func testPauseResumeAndSwitch() async throws {
        let loaded = try ImageEngine.load(url("Animated.gif"))
        let player = ImagePlayback()
        var delivered = 0
        let observation = player.$frame.sink { _ in delivered += 1 }
        defer { player.clear(); observation.cancel() }
        player.configure(url: url("Animated.gif"), poster: loaded.image, animation: loaded.mediaInfo.animation)
        try await Task.sleep(for: .milliseconds(130))
        player.pause()
        let paused = delivered
        let pausedFrame = player.frameIndex
        try await Task.sleep(for: .milliseconds(360))
        try expectEqual(delivered, paused)
        try expectEqual(player.frameIndex, pausedFrame)
        try expect(!player.isPlaying)
        player.play()
        try await Task.sleep(for: .milliseconds(50))
        try expect(player.isPlaying && delivered > paused)
        player.restart()
        try expectEqual(player.frameIndex, 0)
        // Switch to a static image while a frame may still be decoding.
        let staticImage = try ImageEngine.load(url("Static.png"))
        player.configure(url: url("Static.png"), poster: staticImage.image, animation: nil)
        try await Task.sleep(for: .milliseconds(400))
        try expect(!player.isPlaying && player.frame == nil && player.error == nil)
        // A file switch starts a fresh animation without stale frames from the GIF.
        let webP = try ImageEngine.load(url("Animated.webp"))
        player.configure(url: url("Animated.webp"), poster: webP.image, animation: webP.mediaInfo.animation)
        try await Task.sleep(for: .milliseconds(110))
        try expect(player.isPlaying && player.error == nil)
        player.clear()
        let cleared = delivered
        try await Task.sleep(for: .milliseconds(350))
        try expectEqual(delivered, cleared)
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
}
