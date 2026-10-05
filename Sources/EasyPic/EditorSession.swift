import AppKit
import AVFoundation
import EasyPicCore

struct EditorSessionSnapshot {
    let fileURL: URL?
    let history: DocumentHistory?
    let savedDocument: EditorDocument?
    let resources: [UUID: CGImage]
    let image: CGImage?
    let baseImage: CGImage?
    let preview: CGImage?
    let selectedLayerID: UUID?
    let liveHistory: LivePhotoHistory
    let exportedLiveEdits: LivePhotoEdits
    let composition: AVVideoComposition?
    let status: String

    @MainActor init(_ model: EditorModel) {
        fileURL = model.fileURL; history = model.documentHistory; savedDocument = model.savedDocument
        resources = model.resources; image = model.image; baseImage = model.baseImage
        preview = model.documentPreview; selectedLayerID = model.selectedLayerID
        liveHistory = model.liveHistory; exportedLiveEdits = model.exportedLiveEdits
        composition = model.livePlayback.player.currentItem?.videoComposition; status = model.status
    }
}

extension EditorModel {
    func startEditorSessionIfNeeded() {
        if editorSession == nil || sidePanel != .edit || editorSession?.fileURL != fileURL {
            editorSession = EditorSessionSnapshot(self)
        }
    }
    func checkpointEditorSession() {
        if sidePanel == .edit { editorSession = EditorSessionSnapshot(self) }
    }
    var editorSessionHasChanges: Bool {
        guard let session = editorSession, session.fileURL == fileURL else { return dirty || hasTextDraftChanges }
        return document != session.history?.document || hasTextDraftChanges || liveHistory.edits != session.liveHistory.edits
    }
    func requestEditorExit(then continuation: (() -> Void)? = nil, includingEarlierChanges: Bool = false) {
        guard canPerformEditorActions else { return }
        if cropping {
            finishCrop { [weak self] in
                self?.requestEditorExit(then: continuation, includingEarlierChanges: includingEarlierChanges)
            }
            return
        }
        pendingEditorExitAction = continuation
        guard editorSessionHasChanges || (includingEarlierChanges && dirty) else { finishEditorExit(); return }
        editorExitUsesReplacement = canReplaceOriginal
        confirmingEditorExit = true
    }
    func requestApplicationExit(then continuation: @escaping () -> Void) {
        requestEditorExit(then: continuation, includingEarlierChanges: true)
    }
    func cancelEditorExit() { confirmingEditorExit = false; pendingEditorExitAction = nil }
    func finishEditorExit() {
        let continuation = pendingEditorExitAction; pendingEditorExitAction = nil
        confirmingEditorExit = false; editorSession = nil
        previewTask?.cancel(); previewTask = nil; draftLayer = nil; textEditing = false
        cancelCrop(); cancelBrush(); activeEditorTool = nil; sidePanel = nil
        clearRecognition()
        continuation?()
    }
    func discardEditorSession() {
        confirmingEditorExit = false
        guard let session = editorSession, session.fileURL == fileURL else { finishEditorExit(); return }
        previewTask?.cancel(); previewTask = nil; draftLayer = nil; textEditing = false
        pendingEditorAction = nil; pendingAfterExport = nil
        documentHistory = session.history; savedDocument = session.savedDocument; resources = session.resources
        image = session.image; baseImage = session.baseImage; documentPreview = session.preview
        selectedLayerID = session.selectedLayerID; liveHistory = session.liveHistory
        exportedLiveEdits = session.exportedLiveEdits; status = session.status
        if let livePhoto, let composition = session.composition {
            livePlayback.configure(livePhoto, composition: composition, coverTime: session.liveHistory.edits.coverTime)
        }
        finishEditorExit(); resetZoom()
    }
    func saveAndExitEditor() {
        guard confirmingEditorExit else { return }
        let replace = editorExitUsesReplacement
        let continuation = pendingEditorExitAction; pendingEditorExitAction = nil
        confirmingEditorExit = false
        cancelCrop(); cancelBrush()
        finishInlineText { [weak self] in
            guard let self else { return }
            self.pendingAfterExport = { [weak self] in
                self?.finishEditorExit()
                continuation?()
            }
            if replace { self.saveReplacingOriginal() }
            else { self.showExport() }
        }
    }
}
