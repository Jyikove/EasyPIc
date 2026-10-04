import Foundation
import EasyPicCore

extension EditorModel {
    var canReplaceOriginal: Bool {
        guard canPerformEditorActions, !cropping, livePhoto == nil, mediaInfo?.frameCount == 1,
              let originalTypeIdentifier, let fileURL, fileURL.pathExtension.lowercased() != "easypic" else { return false }
        return ImageEngine.canEncode(typeIdentifier: originalTypeIdentifier)
    }
    func saveReplacingOriginal() {
        guard canReplaceOriginal, let doc = document, let url = fileURL else { return }
        let assets = resources, quality = jpegQuality
        busy = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let result = try DocumentEngine.render(doc, resources: assets)
                    try ImageEngine.replaceExisting(result, at: url, quality: quality)
                }.value
                savedDocument = doc; status = "已保存并替换原图"
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
