import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import EasyPicCore

struct ViewerToolsTests {
    func sample(withText: Bool) throws -> CGImage {
        let context = try unwrap(CGContext(data: nil, width: 960, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 360))
        if withText {
            let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 58, nil)
            for (text, y) in [("EasyPic 2026", 235.0), ("你好世界 图片文字", 110.0)] {
                let string = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
                ])
                context.textPosition = CGPoint(x: 55, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            }
        }
        return try unwrap(context.makeImage())
    }

    func run() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/ViewerFixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try sample(withText: true)
        let fixture = directory.appendingPathComponent("TextSample.png")
        try ImageEngine.encode(image, format: .png).write(to: fixture)
        let jpeg = directory.appendingPathComponent("RotatedSample.jpg")
        let destination = try unwrap(CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        try expect(CGImageDestinationFinalize(destination))
        let thumbnail = try ViewerTools.thumbnail(jpeg, maxDimension: 120)
        try expectEqual(thumbnail.width, 45); try expectEqual(thumbnail.height, 120)
        print("PASS · 缩略图尺寸上限、长宽比与 EXIF 方向")
        try expectThrows { _ = try ViewerTools.thumbnail(directory.appendingPathComponent("Missing.png")) }
        try expectThrows { _ = try ViewerTools.thumbnail(fixture, maxDimension: 0) }
        print("PASS · 无法读取的缩略图和非法尺寸拒绝")
        let text = try ViewerTools.recognizeText(in: image)
        try expect(text.contains("EasyPic 2026")); try expect(text.contains("你好世界"))
        try expect(text.contains("\n"))
        print("PASS · 本地 OCR 中英文、多行识别")
        try expectEqual(try ViewerTools.recognizeText(in: sample(withText: false)), "")
        print("PASS · 空白图片 OCR 无文字结果")
    }
}
