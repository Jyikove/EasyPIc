import AppKit
import EasyPicCore

struct CropLeaveChecks {
    @MainActor static func run(photo: URL) async throws {
        for action in 0..<4 {
            let model = try await ViewerModelChecks.loaded(photo)
            model.beginCrop()
            model.cropRect = CGRect(x: 10, y: 20, width: 200, height: 100)
            switch action {
            case 0: model.closeToolDetails()
            case 1: model.chooseEditorTool(.sticker)
            case 2: model.toggleEditor()
            default: model.chooseEditorTool(.crop)
            }
            try await ViewerModelChecks.wait { !model.busy }
            try ViewerModelChecks.expect(model.image?.width == 200 && model.image?.height == 100 && model.canUndo && !model.cropping,
                                         "离开裁剪未保留范围")
            if action == 2 {
                try ViewerModelChecks.expect(model.confirmingEditorExit, "退出编辑未提示保存裁剪")
                model.cancelEditorExit()
            }
            model.undo()
            try await ViewerModelChecks.wait { !model.busy }
            try ViewerModelChecks.expect(model.image?.width == 960 && model.image?.height == 360, "自动裁剪不能撤销")
        }
        let unchanged = try await ViewerModelChecks.loaded(photo)
        unchanged.beginCrop(); unchanged.closeToolDetails()
        try ViewerModelChecks.expect(!unchanged.canUndo && !unchanged.cropping, "全图选区产生多余历史")
        print("PASS · 关闭裁剪、切换工具、退出编辑、重复点击裁剪均应用范围，支持撤销，全图不产生历史")
    }
}
