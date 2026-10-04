import Foundation

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
        print("\(cases.count + 4) 项验证通过")
    }
}
