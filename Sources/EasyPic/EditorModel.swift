import AppKit
import SwiftUI
import UniformTypeIdentifiers
import EasyPicCore
import AVFoundation

@MainActor
final class EditorModel: ObservableObject {
    @Published var documentHistory: DocumentHistory?
    @Published var selectedLayerID: UUID?
    @Published var brushTarget = "base"
    @Published var sidePanel: ViewerPanel?
    @Published var activeEditorTool: EditorTool?
    var pendingEditorAction: (() -> Void)?
    @Published var recognizedText = ""
    @Published var recognizingText = false
    @Published var recognitionError: String?
    var recognitionTask: Task<Void, Never>?
    var recognitionID = UUID()
    var recognitionSource: CGImage?
    @Published var brushMode = false
    @Published var brushTool: BrushTool = .solid
    static let brushSizeRange = 10.0...100.0
    @Published var brushSize = 40.0
    @Published var brushCanvasScale = 1.0
    var brushPreviewDiameter: Double { min(200, max(2, brushSize * brushCanvasScale)) }
    @Published var brushHardness = 1.0
    @Published var brushOpacity = 1.0
    @Published var brushStrength = 16.0
    @Published var brushColor = TextColor(1,0,0)
    @Published var brushRectangle = false
    @Published var brushPoints: [CGPoint] = []
    @Published var cloneSource: CGPoint?
    @Published var textEditing = false
    @Published var draftLayer: StickerLayer?
    @Published var documentPreview: CGImage?
    var resources: [UUID: CGImage] = [:]
    var baseImage: CGImage?
    var savedDocument: EditorDocument?
    var projectURL: URL?
    var previewTask: Task<Void, Never>?
    var document: EditorDocument? { documentHistory?.document }
    var selectedLayer: StickerLayer? { draftLayer ?? document?.layers.first { $0.id == selectedLayerID } }
    var canUseLayers: Bool { canTransform }
    @Published var image: CGImage?
    @Published var fileURL: URL?
    @Published var busy = false {
        didSet {
            guard busy != oldValue else { return }
            if busy { clearRecognition() }
            else { recognizeText() }
        }
    }
    @Published var error: String?
    @Published var status = L10n.text("本地编辑 · 保留原图")
    @Published var zoom: Double = 1
    @Published var viewportReset = UUID()
    @Published var actualSize = false
    @Published var cropping = false
    @Published var cropRect: CGRect?
    @Published var cropRatio: CropRatio = .free
    @Published var exportSheet = false
    @Published var choosingExportLocation = false
    @Published var choosingOpenLocation = false
    @Published var pendingOriginalReplacement: URL?
    @Published var confirmingEditorExit = false
    var editorExitUsesReplacement = false
    var editorSession: EditorSessionSnapshot?
    var pendingEditorExitAction: (() -> Void)?
    @Published var exportFormat: ExportFormat = .png
    @Published var jpegQuality = 0.92
    @Published var browsingFiles: [URL] = []
    @Published var mediaInfo: ImageMediaInfo?
    @Published var originalTypeIdentifier: String?
    @Published var livePhoto: LivePhotoAsset?
    @Published var liveHistory = LivePhotoHistory()
    @Published var missingLivePair = false
    let playback = ImagePlayback()
    let livePlayback = LivePhotoPlayback()
    var exportedLiveEdits = LivePhotoEdits()
    var original: CGImage?
    var pendingAfterExport: (() -> Void)?
    var isReadOnly: Bool { missingLivePair || mediaInfo?.isReadOnly == true }
    var dirty: Bool { !isReadOnly && image != nil && (livePhoto != nil ? liveHistory.edits != exportedLiveEdits : document != savedDocument) }
    var canUndo: Bool { livePhoto != nil ? liveHistory.canUndo : documentHistory?.canUndo == true }
    var canRedo: Bool { livePhoto != nil ? liveHistory.canRedo : documentHistory?.canRedo == true }
    var canTransform: Bool { canEdit && livePhoto == nil }
    var dimensions: String { image.map { "\($0.width) × \($0.height)" } ?? "" }
    var canBrowse: Bool { !busy && !cropping && !exportSheet && !choosingExportLocation && !choosingOpenLocation && !textEditing && pendingOriginalReplacement == nil && !confirmingEditorExit && error == nil }
    var canEdit: Bool { image != nil && !isReadOnly && canBrowse }
    var currentIndex: Int? { fileURL.flatMap { browsingFiles.firstIndex(of: $0) } }

    func openPanel() {
        guard canBrowse else { return }
        let panel = NSOpenPanel(); EasyPicGlass.prepareFilePanel(panel)
        panel.allowedContentTypes = [.image, .quickTimeMovie, UTType(importedAs: "local.jyikove.easypic.project")]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.text("选择图片、Live Photo 配套 MOV，或文件夹。Live Photo 原片和视频需在同一文件夹。")
        choosingOpenLocation = true
        panel.begin { [weak self] response in
            guard let self else { return }
            self.choosingOpenLocation = false
            if response == .OK, let url = panel.url { self.open(url, viewingOnly: true) }
        }
    }

    func open(_ url: URL, viewingOnly: Bool = false) {
        guard !busy, !exportSheet, !choosingExportLocation, !choosingOpenLocation, !textEditing, pendingOriginalReplacement == nil, !confirmingEditorExit, error == nil else { return }
        guard url.isFileURL else { error = L10n.text("请打开本机图片文件。"); return }
        guard !cropping else { error = L10n.text("请先应用或取消当前裁剪。"); return }
        requestLeave { [weak self] in
            guard let self else { return }
            if viewingOnly { self.sidePanel = nil }
            self.activeEditorTool = nil
            self.clearRecognition()
            self.load(url)
        }
    }

    private func load(_ input: URL) {
        editorSession = nil
        if input.pathExtension.lowercased() == "easypic" { loadProject(input); return }
        busy = true
        Task {
            do {
                let (loaded, target, siblings, live, missing) = try await Task.detached(priority: .userInitiated) {
                    let isFolder = (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    let pictures = isFolder ? Self.pictures(in: input) : [input]
                    guard let target = isFolder ? pictures.first : input else { throw ImageFailure.unreadable }
                    var live: LivePhotoAsset?
                    var missing = false
                    do { live = try await LivePhotoEngine.discover(target) }
                    catch LivePhotoFailure.missingPair {
                        guard target.pathExtension.lowercased() != "mov" else { throw LivePhotoFailure.missingPair }
                        missing = true
                    }
                    let photo = live?.photoURL ?? target
                    return (try ImageEngine.load(photo), photo, pictures, live, missing)
                }.value
                playback.clear()
                livePlayback.clear()
                livePhoto = live
                missingLivePair = missing
                liveHistory = LivePhotoHistory()
                exportedLiveEdits = LivePhotoEdits()
                cancelBrush(); previewTask?.cancel(); draftLayer = nil; selectedLayerID = nil; projectURL = nil
                let id = UUID()
                let doc = EditorDocument(baseResourceID: id, size: CGSize(width: loaded.image.width, height: loaded.image.height))
                resources = [id: loaded.image]; documentHistory = DocumentHistory(doc); savedDocument = doc
                baseImage = loaded.image; documentPreview = loaded.image
                original = loaded.image
                image = loaded.image
                mediaInfo = loaded.mediaInfo
                originalTypeIdentifier = loaded.typeIdentifier
                fileURL = target
                browsingFiles = siblings
                zoom = 1
                actualSize = false
                cropRect = nil
                if let live {
                    let composition = try await LivePhotoEngine.composition(for: live, edits: LivePhotoEdits())
                    livePlayback.configure(live, composition: composition)
                    livePlayback.restart()
                    status = live.kind + L10n.text(" · 裁剪与封面 · 原件保留")
                } else if missing { status = L10n.text("Live Photo 原片 · 缺少配套 MOV，仅可查看") }
                else if loaded.mediaInfo.animation != nil { status = L10n.text("动图 · 只读播放") }
                else if loaded.mediaInfo.isGIF { status = L10n.text("GIF · 只读查看") }
                else { status = loaded.frameCount > 1 ? L10n.text("多页图片 · 当前查看和编辑首页") : L10n.text("本地编辑 · 保留原图") }
                playback.configure(url: target, poster: loaded.image, animation: loaded.mediaInfo.animation)
                // Opening one file must not wait for macOS permission to enumerate its parent.
                Task {
                    let files = await Task.detached { Self.pictures(in: target.deletingLastPathComponent()) }.value
                    guard self.fileURL == target else { return }
                    if !files.isEmpty { self.browsingFiles = files }
                }
            } catch { self.error = error.localizedDescription }
            busy = false

        }
    }

    private nonisolated static func pictures(in directory: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        return files.filter {
            guard let values = try? $0.resourceValues(forKeys: keys), values.isRegularFile == true else { return false }
            return values.contentType?.conforms(to: .image) == true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func navigate(_ direction: Int) {
        guard viewerControlsEnabled, let index = currentIndex else { return }
        let next = index + direction
        if browsingFiles.indices.contains(next) { open(browsingFiles[next]) }
    }

    func apply(_ operation: EditOperation) {
        guard canTransform else { return }
        guard var doc = document else { return }
        do { try doc.apply(operation); commitDocument(doc) } catch { self.error = error.localizedDescription }
    }

    func undo() {
        guard canEdit, canUndo else { return }
        if livePhoto != nil { var next = liveHistory; next.undo(); renderLive(next); return }
        guard var next = documentHistory else { return }; next.undo(); renderDocument(next)
    }

    func redo() {
        guard canEdit, canRedo else { return }
        if livePhoto != nil { var next = liveHistory; next.redo(); renderLive(next); return }
        guard var next = documentHistory else { return }; next.redo(); renderDocument(next)
    }

    func beginCrop() {
        guard canEdit else { return }
        startEditorSessionIfNeeded()
        sidePanel = .edit; activeEditorTool = .crop; cancelBrush(); livePlayback.showCover()
        cropping = true; cropRatio = .free; cropRect = CGRect(origin: .zero, size: cropImageSize)
        resetZoom()
    }
    func cancelCrop() { cropping = false; cropRect = nil }
    func commitCrop() {
        guard canApplyCrop, let cropRect = cropPixelRect else { return }
        cropping = false
        if livePhoto != nil, let image {
            do {
                var edits = liveHistory.edits
                try edits.cropFurther(cropRect, displayedSize: CGSize(width: image.width, height: image.height))
                var next = liveHistory; next.apply(edits); renderLive(next)
            } catch { self.error = error.localizedDescription }
        } else { apply(.crop(cropRect)) }
    }

    private func renderLive(_ next: LivePhotoHistory) {
        guard let livePhoto, let original else { return }
        livePlayback.showCover()
        busy = true
        let edits = next.edits
        Task {
            var succeeded = false
            do {
                let (preview, composition) = try await Task.detached(priority: .userInitiated) {
                    (try await LivePhotoEngine.preview(livePhoto, original: original, edits: edits),
                     try await LivePhotoEngine.composition(for: livePhoto, edits: edits))
                }.value
                image = preview; liveHistory = next; cropRect = nil
                livePlayback.configure(livePhoto, composition: composition, coverTime: edits.coverTime)
                status = livePhoto.kind + L10n.text(" · 裁剪与封面 · 原件保留")
                succeeded = true
            } catch { self.error = error.localizedDescription }
            busy = false
            let continuation = pendingEditorAction; pendingEditorAction = nil
            if succeeded { continuation?() }
        }
    }

    func setLiveCover() {
        guard canEdit, let livePhoto else { return }
        var edits = liveHistory.edits
        edits.coverTime = min(livePhoto.lastFrameTime, max(0, livePlayback.position))
        var next = liveHistory; next.apply(edits); renderLive(next)
    }

    func restoreLiveCover() {
        guard canEdit, livePhoto != nil else { return }
        var edits = liveHistory.edits; edits.coverTime = nil
        var next = liveHistory; next.apply(edits); renderLive(next)
    }

    func resetZoom() { zoom = 1; actualSize = false; viewportReset = UUID() }
    func showExport() { guard canEdit else { return }; exportSheet = true }

    func export() {
        if livePhoto != nil { exportLive(); return }
        guard let image, let fileURL, !isReadOnly, !busy, !choosingExportLocation else { return }
        let panel = NSSavePanel(); EasyPicGlass.prepareFilePanel(panel)
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.allowedContentTypes = [exportFormat.type]
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + "-edited." + exportFormat.rawValue
        panel.canCreateDirectories = true
        choosingExportLocation = true
        // Keep the main actor available for AppKit's asynchronous path validation.
        panel.begin { [weak self] response in
            guard let self else { return }
            self.choosingExportLocation = false
            guard response == .OK, let url = panel.url else { return }
            self.writeExport(image, source: fileURL, destination: url)
        }
    }

    func writeExport(_ image: CGImage, source fileURL: URL, destination url: URL) {
        guard !isReadOnly else { return }
        // Even a user-selected export path must never silently replace the source.
        guard url.resolvingSymlinksInPath().standardizedFileURL != fileURL.resolvingSymlinksInPath().standardizedFileURL else {
            error = L10n.text("请使用新的文件名导出，以保留原图。"); return
        }
        let format = exportFormat, quality = jpegQuality, snapshot = document, assets = resources
        busy = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let result = try snapshot.map { try DocumentEngine.render($0, resources: assets) } ?? image
                    let data = try ImageEngine.encode(result, format: format, quality: quality)
                    try data.write(to: url, options: .atomic)
                    return result
                }.value
                if let snapshot { finishSavingImage(snapshot, rendered: result) }
                status = L10n.text("已导出 · ") + url.lastPathComponent
                exportSheet = false
                busy = false
                let continuation = pendingAfterExport
                pendingAfterExport = nil
                continuation?()
            } catch {
                self.error = error.localizedDescription
                busy = false
                pendingAfterExport = nil
            }
        }
    }

    private func exportLive() {
        guard let livePhoto, let original, !busy, !choosingExportLocation else { return }
        let panel = NSSavePanel(); EasyPicGlass.prepareFilePanel(panel)
        panel.directoryURL = livePhoto.photoURL.deletingLastPathComponent()
        panel.nameFieldStringValue = livePhoto.photoURL.deletingPathExtension().lastPathComponent + "-edited-live"
        panel.title = L10n.text("保存 Live Photo 配对文件夹")
        panel.message = L10n.text("会创建新的文件夹，内含配对 JPG 与 MOV，保留动态内容和声音。")
        panel.canCreateDirectories = true
        choosingExportLocation = true
        panel.begin { [weak self] response in
            guard let self else { return }
            self.choosingExportLocation = false
            guard response == .OK, let url = panel.url else { return }
            let snapshot = self.liveHistory.edits
            self.busy = true; self.livePlayback.pause()
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try await LivePhotoEngine.export(livePhoto, original: original, edits: snapshot, to: url)
                    }.value
                    self.exportedLiveEdits = snapshot
                    self.checkpointEditorSession()
                    self.status = L10n.text("Live Photo 已导出 · ") + url.lastPathComponent
                    self.exportSheet = false; self.busy = false
                    let continuation = self.pendingAfterExport; self.pendingAfterExport = nil; continuation?()
                } catch { self.error = error.localizedDescription; self.busy = false; self.pendingAfterExport = nil }
            }
        }
    }

    func cancelExport() { exportSheet = false; pendingAfterExport = nil }

    func requestLeave(_ continuation: @escaping () -> Void) {
        guard !busy else { return }
        guard dirty else { continuation(); return }
        let response = GlassUtilityPresenter.askToLeave(
            title: L10n.text("当前图片还有未保存的修改"),
            message: L10n.text("保存项目后可继续编辑；也可以导出图片或放弃修改。"),
            saveTitle: canUseLayers ? L10n.text("保存项目后继续") : L10n.text("导出后继续"))
        switch response {
        case .alertFirstButtonReturn: pendingAfterExport = continuation; if canUseLayers { saveProject() } else { exportSheet = true }
        case .alertSecondButtonReturn: continuation()
        default: break
        }
    }
}
