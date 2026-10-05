import AppKit
import EasyPicCore

struct FullResolutionChecks {
    @MainActor static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = CGContext(data: nil, width: 2400, height: 1800, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1800))
        let url = folder.appendingPathComponent("Large.png")
        try ImageEngine.encode(context.makeImage()!, format: .png).write(to: url)
        let model = try await ViewerModelChecks.loaded(url)
        func check(_ label: String) throws {
            try ViewerModelChecks.expect(model.documentPreview?.width == 2400 && model.documentPreview?.height == 1800,
                                         label + " lowered canvas resolution")
        }
        try check("Open")
        model.beginTextEditing()
        var draft = model.draftLayer!
        draft.text?.content = "Full resolution"
        draft.size = draft.text!.naturalSize
        let previous = model.documentPreview
        model.updateLayer(draft, commit: false)
        try await ViewerModelChecks.wait { model.documentPreview !== previous }
        try check("Draft")
        model.textEditing = false
        model.updateLayer(draft, commit: true)
        try await ViewerModelChecks.wait { !model.busy }
        try check("Commit")
        let project = folder.appendingPathComponent("Large.easypic")
        try DocumentEngine.save(model.document!, resources: model.resources, to: project)
        model.loadProject(project)
        try await ViewerModelChecks.wait { !model.busy }
        try check("Project")
        print("PASS · 2400×1800 原图、文字草稿、提交及项目重开均保留完整画布分辨率")
    }
}
