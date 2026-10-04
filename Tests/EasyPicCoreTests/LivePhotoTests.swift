import Foundation
import AVFoundation
import CoreGraphics
import AudioToolbox
import Combine
import EasyPicCore

final class LivePhotoTests {
    func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EasyPic-LiveTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.makeFixtures(at: root)
        let photo = root.appendingPathComponent("Landscape.JPG"), movie = root.appendingPathComponent("Motion-renamed.MOV")
        let live = try unwrap(try await LivePhotoEngine.discover(photo))
        try expectEqual(live.videoURL.resolvingSymlinksInPath(), movie.resolvingSymlinksInPath())
        try expectEqual(try await LivePhotoEngine.discover(movie)?.photoURL.resolvingSymlinksInPath(), photo.resolvingSymlinksInPath())
        try expect(abs(live.originalCoverTime - 0.4) < 0.04)
        try expectEqual(try await LivePhotoEngine.discover(root.appendingPathComponent("Static.png"))?.identifier, nil)
        let missing = root.appendingPathComponent("Missing.JPG")
        try LivePhotoEngine.writePhoto(try ImageEngine.load(photo).image, identifier: "unpaired", to: missing)
        do { _ = try await LivePhotoEngine.discover(missing); throw CheckFailure(description: "missing pair accepted") }
        catch LivePhotoFailure.missingPair {}
        print("PASS · Live Photo 标识配对、重命名 MOV、MOV 入口与缺失配对")

        var edits = LivePhotoEdits()
        try edits.cropFurther(CGRect(x: 48, y: 0, width: 48, height: 36), displayedSize: live.photoSize)
        let original = try ImageEngine.load(photo).image
        let preview = try await LivePhotoEngine.preview(live, original: original, edits: edits)
        try expectEqual(preview.width, 48); try expectEqual(preview.height, 36)
        let videoFrame = try await LivePhotoEngine.frame(live, edits: edits, at: 0.2).image
        try expectEqual(videoFrame.width, 32); try expectEqual(videoFrame.height, 24)
        let green = try Self.centerPixel(videoFrame)
        try expect(green[1] > 160 && green[0] < 80 && green[2] < 80)
        let portrait = try unwrap(try await LivePhotoEngine.discover(root.appendingPathComponent("Portrait.JPG")))
        var rotatedCrop = LivePhotoEdits()
        try rotatedCrop.cropFurther(CGRect(x: 0, y: 0, width: 36, height: 48), displayedSize: portrait.photoSize)
        let rotated = try await LivePhotoEngine.frame(portrait, edits: rotatedCrop, at: 0.2).image
        try expectEqual(rotated.width, 24); try expectEqual(rotated.height, 32)
        let blue = try Self.centerPixel(rotated)
        try expect(blue[2] > 160 && blue[0] < 80 && blue[1] < 80)
        print("PASS · Live Photo 照片/视频同步裁剪、像素区域与竖拍方向")

        edits.coverTime = 0.8
        let output = root.appendingPathComponent("Edited")
        try await LivePhotoEngine.export(live, original: original, edits: edits, to: output)
        let reopened = try unwrap(try await LivePhotoEngine.discover(output.appendingPathComponent("LivePhoto.JPG")))
        try expect(reopened.identifier != live.identifier)
        try expect(abs(reopened.originalCoverTime - 0.8) < 0.04)
        try expect(abs(reopened.duration - live.duration) < 0.1)
        let exportedPhoto = try ImageEngine.load(reopened.photoURL).image
        try expectEqual(exportedPhoto.width, 32); try expectEqual(exportedPhoto.height, 24)
        let cover = try await LivePhotoEngine.frame(reopened, edits: LivePhotoEdits(), at: reopened.originalCoverTime).image
        try expectEqual(cover.width, exportedPhoto.width)
        let color = try Self.centerPixel(exportedPhoto)
        try expect(color[0] > 170 && color[1] > 170 && color[2] < 90)
        let exportedAsset = AVURLAsset(url: reopened.videoURL)
        let sound = try await exportedAsset.loadTracks(withMediaType: .audio)
        try expectEqual(sound.count, 1)
        let audioReader = try AVAssetReader(asset: exportedAsset)
        let audioOutput = AVAssetReaderTrackOutput(track: sound[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        audioReader.add(audioOutput); try expect(audioReader.startReading())
        try expect(audioOutput.copyNextSampleBuffer() != nil); audioReader.cancelReading()
        try expectEqual(LivePhotoEngine.photoIdentifier(photo), live.identifier)
        do { try await LivePhotoEngine.export(live, original: original, edits: edits, to: output); throw CheckFailure(description: "overwrote directory") }
        catch LivePhotoFailure.export {}
        print("PASS · Live Photo 导出重开、封面帧/时间、配对标识、时长与可解码声音")

        var history = LivePhotoHistory()
        history.apply(edits); history.undo(); try expectEqual(history.edits, LivePhotoEdits())
        history.redo(); try expectEqual(history.edits, edits)
        var second = edits
        try second.cropFurther(CGRect(x: 0, y: 0, width: 24, height: 36), displayedSize: CGSize(width: 48, height: 36))
        history.apply(second); try expect(abs(history.edits.crop.width - 0.25) < 0.0001)
        history.undo(); history.apply(LivePhotoEdits()); try expect(!history.canRedo)
        var invalid = LivePhotoEdits(); invalid.coverTime = .nan
        do { _ = try await LivePhotoEngine.preview(live, original: original, edits: invalid); throw CheckFailure(description: "invalid cover accepted") }
        catch LivePhotoFailure.invalidEdit {}
        try expectThrows { try invalid.cropFurther(CGRect(x: 0, y: 0, width: 1, height: 1), displayedSize: live.photoSize) }
        let cancelled = root.appendingPathComponent("Cancelled")
        let task = Task { try Task.checkCancellation(); try await LivePhotoEngine.export(live, original: original, edits: edits, to: cancelled) }
        task.cancel()
        do { try await task.value; throw CheckFailure(description: "cancelled export succeeded") } catch is CancellationError {}
        try expect(!FileManager.default.fileExists(atPath: cancelled.path))
        print("PASS · Live Photo 连续裁剪、封面撤销/重做、非法输入和取消不落盘")
    }

    @MainActor func testPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EasyPic-LivePlayback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.makeFixtures(at: root)
        let live = try unwrap(try await LivePhotoEngine.discover(root.appendingPathComponent("Landscape.JPG")))
        let composition = try await LivePhotoEngine.composition(for: live, edits: LivePhotoEdits())
        let playback = LivePhotoPlayback()
        var delivered = 0
        let observation = playback.$frame.sink { _ in delivered += 1 }
        defer { playback.clear(); observation.cancel() }
        playback.configure(live, composition: composition)
        playback.restart()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while (playback.frame == nil || playback.position < 0.1) && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(playback.frame != nil && playback.position > 0 && playback.error == nil)
        playback.pause()
        let paused = delivered, position = playback.position
        try await Task.sleep(for: .milliseconds(150))
        try expectEqual(delivered, paused); try expectEqual(playback.position, position)
        playback.seek(0.8)
        let seekDeadline = ProcessInfo.processInfo.systemUptime + 2
        while delivered == paused && ProcessInfo.processInfo.systemUptime < seekDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try expect(delivered > paused && !playback.isPlaying)
        let pixels = try Self.centerPixel(ImageEngine.render(try unwrap(playback.frame), operations: [.crop(CGRect(x: 32, y: 0, width: 32, height: 24))]))
        try expect(pixels[0] > 170 && pixels[1] > 170 && pixels[2] < 90)
        playback.showCover(); try expect(!playback.showingMotion)
        playback.restart()
        try await Task.sleep(for: .milliseconds(80))
        playback.clear()
        let cleared = delivered
        try await Task.sleep(for: .milliseconds(120))
        try expectEqual(delivered, cleared)
        try expect(playback.frame == nil && !playback.isPlaying)
        print("PASS · Live Photo 实际视频帧播放、暂停、时间轴定位、封面查看与清理")
    }

    func testMotionPhotos() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EasyPic-MotionTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.makeFixtures(at: root)
        let url = root.appendingPathComponent("Motion.jpg")
        let data = try Data(contentsOf: url)
        let payload = try unwrap(try MotionPhotoEngine.payload(in: data))
        try expectEqual(payload.videoRange.count, try Data(contentsOf: root.appendingPathComponent("Motion-renamed.MOV")).count)
        let live = try unwrap(try await LivePhotoEngine.discover(url))
        try expect(live.embeddedVideo != nil)
        try expect(abs(live.originalCoverTime - 0.4) < 0.001)
        let preview = try await LivePhotoEngine.frame(live, edits: LivePhotoEdits(), at: 0.2)
        try expectEqual(preview.image.width, 64)
        let output = root.appendingPathComponent("Motion-export")
        var edits = LivePhotoEdits(); edits.coverTime = 0.8
        try await LivePhotoEngine.export(live, original: ImageEngine.load(url).image, edits: edits, to: output)
        let pair = try unwrap(try await LivePhotoEngine.discover(output.appendingPathComponent("LivePhoto.JPG")))
        try expect(abs(pair.originalCoverTime - 0.8) < 0.04)
        let movie = try Data(contentsOf: root.appendingPathComponent("Motion-renamed.MOV"))
        let plain = try ImageEngine.encode(Self.pattern(time: 0), format: .jpg)
        try expect(try MotionPhotoEngine.payload(in: plain + movie) == nil)
        let legacy = Self.embed(plain, video: movie, xml: Self.legacyXML(length: movie.count))
        try expectEqual(try MotionPhotoEngine.payload(in: legacy)?.videoRange.count, movie.count)
        let disabled = Self.embed(plain, video: movie, xml: Self.legacyXML(length: movie.count).replacingOccurrences(of: "c:MicroVideo=", with: "c:MotionPhoto=\"0\" c:MicroVideo="))
        try expect(try MotionPhotoEngine.payload(in: disabled) == nil)
        let invalid = Self.embed(plain, video: movie, xml: Self.legacyXML(length: Int.max))
        try expectThrows { _ = try MotionPhotoEngine.payload(in: invalid) }
        var owner: MotionPhotoResource? = try MotionPhotoEngine.extract(url)?.resource
        let temporary = try unwrap(owner?.url)
        try expect(FileManager.default.fileExists(atPath: temporary.path))
        owner = nil
        try expect(!FileManager.default.fileExists(atPath: temporary.path))
        print("PASS · Motion Photo XMP/容器、GainMap、旧版偏移、误判/越界拒绝、导出与临时视频清理")
    }

    private static func legacyXML(length: Int) -> String {
        "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:c=\"http://ns.google.com/photos/1.0/camera/\" c:MicroVideo=\"1\" c:MicroVideoOffset=\"\(length)\" c:MicroVideoPresentationTimestampUs=\"400000\"/></rdf:RDF></x:xmpmeta>"
    }
    private static func embed(_ jpeg: Data, video: Data, xml: String, gainMap: Data = Data()) -> Data {
        let app1 = Data("http://ns.adobe.com/xap/1.0/\0".utf8) + Data(xml.utf8)
        let size = app1.count + 2
        return Data([0xff, 0xd8, 0xff, 0xe1, UInt8(size >> 8), UInt8(size & 255)]) + app1 + jpeg.dropFirst(2) + gainMap + video
    }

    static func makeFixtures(at root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for portrait in [false, true] {
            let identifier = UUID().uuidString
            let movie = root.appendingPathComponent(portrait ? "Portrait.MOV" : "Motion-renamed.MOV")
            try await makeMovie(to: movie, identifier: identifier, portrait: portrait)
            // Photos are larger than the video, like an actual Live Photo pair.
            let image = try pattern(time: 0.4)
            let oriented = try ImageEngine.render(image, operations: portrait ? [.clockwise] : [])
            let width = portrait ? 72 : 96, height = portrait ? 96 : 72
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none
            context.draw(oriented, in: CGRect(x: 0, y: 0, width: width, height: height))
            try LivePhotoEngine.writePhoto(context.makeImage()!, identifier: identifier,
                         to: root.appendingPathComponent(portrait ? "Portrait.JPG" : "Landscape.JPG"))
        }
        let staticURL = root.appendingPathComponent("Static.png")
        try ImageEngine.encode(pattern(time: 0), format: .png).write(to: staticURL)
        let movie = try Data(contentsOf: root.appendingPathComponent("Motion-renamed.MOV"))
        let gain = try ImageEngine.encode(pattern(time: 0), format: .jpg)
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description xmlns:c="http://ns.google.com/photos/1.0/camera/" xmlns:box="http://ns.google.com/photos/1.0/container/" xmlns:i="http://ns.google.com/photos/1.0/container/item/" c:MotionPhoto="1" c:MotionPhotoVersion="1" c:MotionPhotoPresentationTimestampUs="400000">
        <box:Directory><rdf:Seq>
        <rdf:li><box:Item i:Mime="image/jpeg" i:Semantic="Primary"/></rdf:li>
        <rdf:li><box:Item i:Mime="image/jpeg" i:Semantic="GainMap" i:Length="\(gain.count)"/></rdf:li>
        <rdf:li><box:Item i:Semantic="MotionPhoto" i:Length="\(movie.count)" i:Mime="video/quicktime"/></rdf:li>
        </rdf:Seq></box:Directory></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let motion = embed(try ImageEngine.encode(pattern(time: 0.4), format: .jpg), video: movie, xml: xml, gainMap: gain)
        try motion.write(to: root.appendingPathComponent("Motion.jpg"))
    }

    private static func pattern(time: Double) throws -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Quartz origin bottom-left; video top-right is green, bottom-left is blue.
        for (rect, color) in [(CGRect(x: 0, y: 24, width: 32, height: 24), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: 32, y: 24, width: 32, height: 24), CGColor(red: time >= 0.6 ? 1 : 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: 32, height: 24), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: 32, y: 0, width: 32, height: 24), CGColor(gray: 1, alpha: 1))] {
            context.setFillColor(color); context.fill(rect)
        }
        return context.makeImage()!
    }

    private static func makeMovie(to url: URL, identifier: String, portrait: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let id = AVMutableMetadataItem(); id.identifier = .quickTimeMetadataContentIdentifier
        id.value = identifier as NSString; id.dataType = kCMMetadataBaseDataType_UTF8 as String; writer.metadata = [id]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        if portrait { video.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0) }
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
             sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(video)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000, AVEncoderBitRateKey: 64000])
        writer.add(audio)
        var format: CMFormatDescription?
        let spec = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String]
        try expectEqual(CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                     metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &format), noErr)
        let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata); writer.add(metadata)
        try expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let marker = AVMutableMetadataItem(); marker.keySpace = .quickTimeMetadata
        marker.key = "com.apple.quicktime.still-image-time" as NSString; marker.value = NSNumber(value: Int8(0)); marker.dataType = kCMMetadataBaseDataType_SInt8 as String
        try expect(adaptor.append(AVTimedMetadataGroup(items: [marker], timeRange: CMTimeRange(start: CMTime(value: 12, timescale: 30), duration: CMTime(value: 1, timescale: 30)))))
        metadata.markAsFinished()
        while !audio.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        try expect(audio.append(try sineSample())); audio.markAsFinished()
        for index in 0..<36 {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            try expectEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixels.pixelBufferPool!, &buffer), kCVReturnSuccess)
            let pixel = try unwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 64, height: 48, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.draw(try pattern(time: Double(index) / 30), in: CGRect(x: 0, y: 0, width: 64, height: 48))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            try expect(pixels.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        video.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? LivePhotoFailure.invalidVideo }
    }

    private static func sineSample() throws -> CMSampleBuffer {
        let count = 57600
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        try expectEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        try expectEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count * 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count * 4, flags: 0, blockBufferOut: &block), noErr)
        let samples = (0..<count).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000) * 0.2) }
        try samples.withUnsafeBytes { bytes in try expectEqual(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: count * 4), noErr) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try expectEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                        sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        return try unwrap(sample)
    }

    private static func centerPixel(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { memory in
            let context = CGContext(data: memory.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (image.height / 2 * image.width + image.width / 2) * 4
        return Array(bytes[offset..<offset + 4])
    }
}
