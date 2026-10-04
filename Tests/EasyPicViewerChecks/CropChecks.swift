import Foundation
import EasyPicCore

@MainActor
enum CropChecks {
    private static func expect(_ value: Bool, _ message: String) throws { try ViewerModelChecks.expect(value, message) }
    private static func bounded(_ r: CGRect, in size: CGSize) -> Bool {
        r.minX >= -0.000001 && r.minY >= -0.000001 && r.maxX <= size.width + 0.000001 &&
        r.maxY <= size.height + 0.000001 && r.width > 0 && r.height > 0
    }
    static func run(photo: URL, liveURL: URL) async throws {
        let size = CGSize(width: 800, height: 600), initial = CGRect(x: 100, y: 80, width: 200, height: 120)
        let points: [(CropHandle, CGPoint, CGRect)] = [
            (.topLeft, CGPoint(x: 100, y: 80), CGRect(x: 130, y: 100, width: 170, height: 100)),
            (.top, CGPoint(x: 200, y: 80), CGRect(x: 100, y: 100, width: 200, height: 100)),
            (.topRight, CGPoint(x: 300, y: 80), CGRect(x: 100, y: 100, width: 230, height: 100)),
            (.right, CGPoint(x: 300, y: 140), CGRect(x: 100, y: 80, width: 230, height: 120)),
            (.bottomRight, CGPoint(x: 300, y: 200), CGRect(x: 100, y: 80, width: 230, height: 140)),
            (.bottom, CGPoint(x: 200, y: 200), CGRect(x: 100, y: 80, width: 200, height: 140)),
            (.bottomLeft, CGPoint(x: 100, y: 200), CGRect(x: 130, y: 80, width: 170, height: 140)),
            (.left, CGPoint(x: 100, y: 140), CGRect(x: 130, y: 80, width: 170, height: 120))
        ]
        for (handle, point, expected) in points {
            try expect(CropGeometry.handle(at: point, rect: initial, tolerance: 10) == handle, "选框边缘/角点命中错误")
            let resized = CropGeometry.adjust(initial, handle: handle, delta: CGSize(width: 30, height: 20), in: size, ratio: nil)
            try expect(resized == expected, "自由比例拖拽调整了错误的边")
        }
        try expect(CropGeometry.handle(at: CGPoint(x: 200, y: 140), rect: initial, tolerance: 10) == .move, "选框内部未用于移动")
        try expect(CropGeometry.handle(at: .zero, rect: initial, tolerance: 10) == nil, "框外点击错误地创建或移动选区")
        let moved = CropGeometry.adjust(initial, handle: .move, delta: CGSize(width: -10000, height: 10000), in: size, ratio: nil)
        try expect(moved == CGRect(x: 0, y: 480, width: 200, height: 120), "移动越界或改变了选框大小")
        let crossed = CropGeometry.adjust(initial, handle: .topLeft, delta: CGSize(width: 10000, height: 10000), in: size, ratio: nil)
        try expect(crossed == CGRect(x: 299, y: 199, width: 1, height: 1), "越过对边后选框翻转或消失")
        print("PASS · 裁剪四边/四角命中、自由调整、内部移动、边界与最小尺寸")

        let ratios: [(CropRatio, CGFloat?)] = [(.free, nil), (.original, 4 / 3), (.square, 1), (.portrait3x4, 0.75),
            (.landscape4x3, 4 / 3), (.wide16x9, 16 / 9), (.tall9x16, 9 / 16), (.portrait2x3, 2 / 3),
            (.landscape3x2, 1.5), (.wide18x9, 2), (.tall9x18, 0.5), (.cinema, 2.39)]
        for (choice, expected) in ratios { try expect(choice.value(in: size) == expected, "裁剪预设比例不正确：" + choice.title) }
        for bounds in [size, CGSize(width: 360, height: 960), CGSize(width: 97, height: 83)] {
            for choice in CropRatio.allCases {
                guard let ratio = choice.value(in: bounds) else { continue }
                let fitted = CropGeometry.fit(CGRect(x: 10, y: 12, width: bounds.width / 2, height: bounds.height / 2), ratio: ratio, in: bounds)
                for handle in CropHandle.allCases {
                    for delta in [CGSize.zero, CGSize(width: 35, height: -17), CGSize(width: -91, height: 80),
                                  CGSize(width: 10000, height: 10000), CGSize(width: -10000, height: -10000)] {
                        let result = CropGeometry.adjust(fitted, handle: handle, delta: delta, in: bounds, ratio: ratio)
                        try expect(bounded(result, in: bounds), "固定比例调整越出图片：" + choice.title)
                        try expect(abs(result.width / result.height - ratio) < 0.000001, "边缘/角点拖动破坏固定比例：" + choice.title)
                        if handle == .move { try expect(result.size == fitted.size, "固定比例移动改变大小") }
                    }
                }
            }
        }
        let anchor = CropGeometry.adjust(CGRect(x: 100, y: 80, width: 200, height: 200), handle: .topLeft,
                                         delta: CGSize(width: 30, height: 40), in: size, ratio: 1)
        try expect(anchor.maxX == 300 && anchor.maxY == 280, "固定比例角点没有保持对角锚点")
        print("PASS · 全部预设比例、横竖图、固定比例四边/四角调整与越界约束")

        let model = try await ViewerModelChecks.loaded(photo)
        let source = model.image!, viewport = model.viewportReset
        model.chooseEditorTool(.crop)
        try expect(model.cropRatio == .free && model.cropRect == CGRect(x: 0, y: 0, width: 960, height: 360), "进入裁剪没有默认覆盖整图的自由选框")
        try expect(!model.dirty && model.viewportReset != viewport, "进入裁剪形成了修改或没有重置视口")
        model.selectCropRatio(.portrait3x4)
        try expect(abs(model.cropRect!.width / model.cropRect!.height - 0.75) < 0.000001, "实际模型未应用 3:4")
        let fitted = model.cropRect!
        model.selectCropRatio(.free)
        try expect(model.cropRect == fitted, "切回自由比例改变了已有选区")
        model.adjustCrop(from: fitted, handle: .move, delta: CGSize(width: 500, height: 90))
        model.adjustCrop(from: model.cropRect!, handle: .bottom, delta: CGSize(width: 0, height: -180))
        let selected = model.cropPixelRect!
        try expect(selected == CGRect(x: 690, y: 0, width: 270, height: 180), "选区移动/自由缩放与实际像素不一致")
        let expected = try ImageEngine.render(source, operations: [.crop(selected)])
        model.commitCrop(); try await ViewerModelChecks.wait { !model.busy }
        try expect(model.image?.width == 270 && model.image?.height == 180 && !model.cropping, "应用选框未按正确像素裁剪")
        try expect(model.image?.dataProvider?.data == expected.dataProvider?.data, "实际裁剪像素与选框位置不一致")
        model.chooseEditorTool(.undo); try await ViewerModelChecks.wait { !model.busy }
        try expect(model.image?.width == 960 && model.image?.height == 360 && !model.dirty && model.activeEditorTool == nil, "撤销裁剪未恢复原图或打开了二级窗口")
        model.chooseEditorTool(.redo); try await ViewerModelChecks.wait { !model.busy }
        try expect(model.image?.width == 270 && model.image?.height == 180 && model.activeEditorTool == nil, "重做裁剪失败或打开了二级窗口")
        model.chooseEditorTool(.crop)
        try expect(model.cropRatio == .free, "再次进入裁剪未默认自由比例")
        model.selectCropRatio(.original)
        try expect(abs(model.cropAspectRatio! - 1.5) < 0.000001, "原图比例未使用当前图片方向与尺寸")
        model.cancelCrop(); model.playback.clear()
        print("PASS · 裁剪默认选框、比例切换、真实像素裁剪、撤销重做及重新进入")

        let live = try await ViewerModelChecks.loaded(liveURL)
        live.chooseEditorTool(.crop); live.selectCropRatio(.square)
        let crop = live.cropPixelRect!
        live.commitCrop(); try await ViewerModelChecks.wait { !live.busy }
        try expect(live.error == nil && live.image?.width == live.image?.height && live.liveHistory.canUndo, "Live Photo 九宫格选框裁剪失败")
        let originalSize = live.livePhoto!.photoSize
        try expect(abs(live.liveHistory.edits.crop.minY - crop.minY / originalSize.height) < 0.000001, "Live Photo 选框坐标没有同步到动态照片")
        live.chooseEditorTool(.undo); try await ViewerModelChecks.wait { !live.busy }
        try expect(live.image?.width == Int(originalSize.width) && live.image?.height == Int(originalSize.height) && live.activeEditorTool == nil, "Live Photo 裁剪撤销失败")
        live.playback.clear(); live.livePlayback.clear()
        print("PASS · Live Photo 固定比例选框、同步裁剪及撤销")
    }
}
