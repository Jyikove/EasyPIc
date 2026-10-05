import Foundation
import CoreGraphics
import EasyPicCore

extension EditorModel {
    var canReplaceOriginal: Bool {
        guard canPerformEditorActions, !cropping, livePhoto == nil, mediaInfo?.frameCount == 1,
              let originalTypeIdentifier, let fileURL, fileURL.pathExtension.lowercased() != "easypic" else { return false }
        return ImageEngine.canEncode(typeIdentifier: originalTypeIdentifier)
    }
    func requestOriginalReplacement() {
        guard canReplaceOriginal else { return }
        pendingOriginalReplacement = fileURL
    }
    func cancelOriginalReplacement() { pendingOriginalReplacement = nil }
    func confirmOriginalReplacement() {
        guard let target = pendingOriginalReplacement else { return }
        pendingOriginalReplacement = nil
        guard fileURL == target else { return }
        saveReplacingOriginal()
    }
    func saveReplacingOriginal() {
        guard canReplaceOriginal, let doc = document, let url = fileURL else { return }
        let assets = resources, quality = jpegQuality
        busy = true
        Task {
            var succeeded = false
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let result = try DocumentEngine.render(doc, resources: assets)
                    try ImageEngine.replaceExisting(result, at: url, quality: quality)
                    return result
                }.value
                finishSavingImage(doc, rendered: result)
                status = L10n.text("已保存并替换原图")
                succeeded = true
            } catch { self.error = error.localizedDescription; pendingAfterExport = nil }
            busy = false
            if succeeded {
                let continuation = pendingAfterExport; pendingAfterExport = nil
                continuation?()
            }
        }
    }
    func finishSavingImage(_ snapshot: EditorDocument, rendered: CGImage) {
        guard !snapshot.layers.isEmpty, var history = documentHistory else {
            savedDocument = snapshot
            checkpointEditorSession()
            return
        }
        let id = UUID()
        resources[id] = rendered
        let flattened = EditorDocument(baseResourceID: id, size: CGSize(width: rendered.width, height: rendered.height))
        history.apply(flattened)
        previewTask?.cancel(); draftLayer = nil; textEditing = false; selectedLayerID = nil
        documentHistory = history; savedDocument = flattened
        baseImage = rendered; image = rendered; documentPreview = rendered
        checkpointEditorSession()
    }
}
