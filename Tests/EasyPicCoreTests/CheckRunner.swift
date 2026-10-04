import Foundation
import EasyPicCore
import CoreGraphics

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
func expect(_ condition: Bool, file: String = #filePath, line: Int = #line) throws {
    if !condition { throw CheckFailure(description: "\(file):\(line): condition failed") }
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #filePath, line: Int = #line) throws {
    if actual != expected { throw CheckFailure(description: "\(file):\(line): expected \(expected), got \(actual)") }
}
func unwrap<T>(_ value: T?, file: String = #filePath, line: Int = #line) throws -> T {
    guard let value else { throw CheckFailure(description: "\(file):\(line): unexpected nil") }
    return value
}
func expectThrows(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw CheckFailure(description: "expected error was not thrown")
}

@main
struct CheckRunner {
    @MainActor static func main() async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--inspect-live"), CommandLine.arguments.indices.contains(index + 1) {
            var url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                url = try unwrap(FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first)
            }
            let live = try unwrap(try await LivePhotoEngine.discover(url))
            print("\(live.kind) · \(Int(live.photoSize.width))×\(Int(live.photoSize.height)) · \(live.duration)s · cover=\(live.originalCoverTime)s · \(live.frameRate)fps")
            let frame = try await LivePhotoEngine.frame(live, edits: LivePhotoEdits(), at: live.originalCoverTime)
            print("视频帧 \(frame.image.width)×\(frame.image.height)，解码成功")
            if CommandLine.arguments.indices.contains(index + 2) {
                var edits = LivePhotoEdits()
                try edits.cropFurther(CGRect(x: live.photoSize.width / 4, y: live.photoSize.height / 4, width: live.photoSize.width / 2, height: live.photoSize.height / 2), displayedSize: live.photoSize)
                edits.coverTime = min(live.lastFrameTime, 0.8)
                let destination = URL(fileURLWithPath: CommandLine.arguments[index + 2])
                try await LivePhotoEngine.export(live, original: ImageEngine.load(url).image, edits: edits, to: destination)
                let pair = try unwrap(try await LivePhotoEngine.discover(destination.appendingPathComponent("LivePhoto.JPG")))
                print("真实样本裁剪/新封面导出重开成功：\(pair.photoSize) · cover=\(pair.originalCoverTime)s")
            }
            return
        }
        if CommandLine.arguments.contains("--live-fixtures") {
            try await LivePhotoTests.makeFixtures(at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/LivePhotoFixtures"))
            print("已生成 build/LivePhotoFixtures")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--ai-smoke"), CommandLine.arguments.indices.contains(index + 1) {
            try await AIJobTests.smoke(directory: URL(fileURLWithPath: CommandLine.arguments[index+1]), selected: CommandLine.arguments.contains("--selected")); return
        }
        let tests = ImageEngineTests()
        let cases: [(String, () throws -> Void)] = [
            ("顺时针像素方向", tests.testClockwisePixels),
            ("逆时针与四次旋转", tests.testCounterclockwiseAndRoundTrip),
            ("水平与垂直镜像", tests.testMirrorPixels),
            ("左上角裁剪及旋转后裁剪", tests.testTopLeftCropAndCropAfterRotation),
            ("非法裁剪拒绝", tests.testInvalidCropRejected),
            ("撤销重做与历史分支", tests.testHistoryBranches),
            ("PNG/JPG 编码与尺寸", tests.testPNGAndJPEGRoundTrip),
            ("透明度与 JPG 白底", tests.testTransparencyAndJPEGWhiteBackground),
            ("EXIF 照片方向", tests.testEXIFOrientationOnLoad)
        ]
        for (name, operation) in cases { try operation(); print("PASS · \(name)") }
        let animations = AnimationTests()
        try animations.testReadOnlyDetection(); print("PASS · 动图识别、静态 GIF 只读、多页 TIFF 区分")
        try animations.testTimingAndLoop(); print("PASS · 原始帧时长与循环时间线")
        try await animations.testDecodedPlaybackAndDisposal(); print("PASS · GIF/APNG/WebP 逐帧像素、透明与帧恢复")
        try await animations.testPauseResumeAndSwitch(); print("PASS · 暂停、继续、重播、切换文件取消旧播放")
        try await Task.detached { try await LivePhotoTests().run() }.value
        try await Task.detached { try await LivePhotoTests().testMotionPhotos() }.value
        try await LivePhotoTests().testPlayback()
        try DocumentTests().run()
        try TextTests().run()
        try BrushTests().run()
        try await AIJobTests().run()
        print("\(cases.count + 24) 项验证通过")
    }
}
