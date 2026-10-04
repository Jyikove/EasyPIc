import Foundation
import EasyPicCore

@main
struct ViewerModelChecks {
    @MainActor static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "EasyPic.ViewerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            try expect(Date() < deadline, "等待查看器操作超时")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor static func main() async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/ViewerFixtures")
        let photo = folder.appendingPathComponent("TextSample.png")
        let model = EditorModel()
        model.sidePanel = .edit
        model.open(photo, viewingOnly: true)
        try await wait { !model.busy && model.browsingFiles.count == 2 }
        try expect(model.error == nil && model.image?.width == 960, "打开图片失败")
        try expect(model.sidePanel == nil, "Finder 打开图片未收起右侧栏")
        try expect(model.canNavigatePrevious && !model.canNavigateNext, "最后一张的导航状态不正确")
        print("PASS · 打开图片默认收起右侧栏、同文件夹浏览与边界状态")

        model.togglePanel(.thumbnails)
        model.navigate(-1)
        try await wait { !model.busy }
        try expect(model.sidePanel == .thumbnails && model.fileURL?.lastPathComponent == "RotatedSample.jpg", "预览导航丢失面板或目标图片")
        try expect(!model.canNavigatePrevious && model.canNavigateNext, "第一张的导航状态不正确")
        model.navigate(1)
        try await wait { !model.busy }
        model.togglePanel(.text)
        try await wait { !model.recognizingText }
        try expect(model.sidePanel == .text && model.recognizedText.contains("你好世界"), "OCR 未识别当前图片")
        model.togglePanel(.text)
        try expect(model.sidePanel == nil && model.recognizedText.isEmpty, "再次点击 OCR 未收起并清空结果")
        print("PASS · 预览前后跳转、面板互斥和 OCR 展开/收起")

        model.togglePanel(.text)
        model.togglePanel(.thumbnails)
        try await Task.sleep(for: .milliseconds(500))
        try expect(model.sidePanel == .thumbnails && model.recognizedText.isEmpty && !model.recognizingText, "关闭 OCR 后旧任务污染结果")
        model.togglePanel(.text)
        try await wait { !model.recognizingText }
        model.open(photo)
        try await wait { !model.busy && !model.recognizingText }
        try expect(model.sidePanel == .text && model.recognizedText.contains("EasyPic 2026"), "换图后 OCR 未刷新")
        print("PASS · OCR 旧结果取消、保留 OCR 面板并重新加载识别")

        model.togglePanel(.edit)
        model.apply(.counterclockwise)
        try await wait { !model.busy }
        try expect(model.image?.width == 360 && model.image?.height == 960 && model.canUndo, "逆时针旋转没有形成可撤销编辑")
        model.undo()
        try await wait { !model.busy }
        try expect(model.image?.width == 960 && model.image?.height == 360 && !model.dirty && model.canRedo, "撤销旋转失败")
        model.beginCrop(); model.togglePanel(.thumbnails)
        try expect(model.sidePanel == .edit, "裁剪时隐藏了操作面板")
        model.cancelCrop(); model.beginBrush(); model.togglePanel(.edit)
        try expect(model.sidePanel == nil && !model.brushMode, "关闭编辑栏未退出画笔模式")
        print("PASS · 旋转/撤销、裁剪期间面板保护、关闭编辑栏退出画笔")
        model.clearRecognition(); model.playback.clear(); model.livePlayback.clear()
        print("4 项查看器模型验证通过")
    }
}
