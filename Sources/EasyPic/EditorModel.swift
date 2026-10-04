import AppKit
import SwiftUI
import UniformTypeIdentifiers
import EasyPicCore
import AVFoundation

@MainActor
final class EditorModel: ObservableObject {
    @Published var image: CGImage?
    @Published var fileURL: URL?
    @Published var history = EditHistory()
    @Published var busy = false
    @Published var error: String?
    @Published var status = "本地编辑 · 保留原图"
    @Published var zoom: Double = 1
    @Published var actualSize = false
    @Published var cropping = false
    @Published var cropRect: CGRect?
    @Published var exportSheet = false
    @Published var choosingExportLocation = false
    @Published var exportFormat: ExportFormat = .png
    @Published var jpegQuality = 0.92
    @Published var browsingFiles: [URL] = []
    @Published private(set) var mediaInfo: ImageMediaInfo?
    @Published private(set) var livePhoto: LivePhotoAsset?
    @Published private(set) var liveHistory = LivePhotoHistory()
    @Published private(set) var missingLivePair = false
    let playback = ImagePlayback()
    let livePlayback = LivePhotoPlayback()
    private var exportedLiveEdits = LivePhotoEdits()
    private var original: CGImage?
    private var exportedOperations: [EditOperation] = []
    private var pendingAfterExport: (() -> Void)?
    var isReadOnly: Bool { missingLivePair || mediaInfo?.isReadOnly == true }
    var dirty: Bool { !isReadOnly && image != nil && (livePhoto != nil ? liveHistory.edits != exportedLiveEdits : history.operations != exportedOperations) }
    var canUndo: Bool { livePhoto != nil ? liveHistory.canUndo : history.canUndo }
    var canRedo: Bool { livePhoto != nil ? liveHistory.canRedo : history.canRedo }
    var canTransform: Bool { canEdit && livePhoto == nil }
    var dimensions: String { image.map { "\($0.width) × \($0.height)" } ?? "" }
    var canBrowse: Bool { !busy && !cropping && !exportSheet && !choosingExportLocation }
    var canEdit: Bool { image != nil && !isReadOnly && canBrowse }
    var currentIndex: Int? { fileURL.flatMap { browsingFiles.firstIndex(of: $0) } }

    func openPanel() {
        guard !busy, !exportSheet, !choosingExportLocation else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .quickTimeMovie]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择图片、Live Photo 配套 MOV，或文件夹。Live Photo 原片和视频需在同一文件夹。"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        guard !busy, !exportSheet, !choosingExportLocation else { return }
        guard url.isFileURL else { error = "请打开本机图片文件。"; return }
        guard !cropping else { error = "请先应用或取消当前裁剪。"; return }
        requestLeave { [weak self] in self?.load(url) }
    }

    private func load(_ input: URL) {
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
                original = loaded.image
                image = loaded.image
                mediaInfo = loaded.mediaInfo
                fileURL = target
                browsingFiles = siblings
                history = EditHistory()
                exportedOperations = []
                zoom = 1
                actualSize = false
                cropRect = nil
                if let live {
                    let composition = try await LivePhotoEngine.composition(for: live, edits: LivePhotoEdits())
                    livePlayback.configure(live, composition: composition)
                    livePlayback.restart()
                    status = live.kind + " · 裁剪与封面 · 原件保留"
                } else if missing { status = "Live Photo 原片 · 缺少配套 MOV，仅可查看" }
                else if loaded.mediaInfo.animation != nil { status = "动图 · 只读播放" }
                else if loaded.mediaInfo.isGIF { status = "GIF · 只读查看" }
                else { status = loaded.frameCount > 1 ? "多页图片 · 当前查看和编辑首页" : "本地编辑 · 保留原图" }
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
        guard canBrowse, let index = currentIndex else { return }
        let next = index + direction
        if browsingFiles.indices.contains(next) { open(browsingFiles[next]) }
    }

    func apply(_ operation: EditOperation) {
        guard canTransform else { return }
        var next = history
        next.apply(operation)
        render(next)
    }

    func undo() {
        guard canEdit, canUndo else { return }
        if livePhoto != nil { var next = liveHistory; next.undo(); renderLive(next); return }
        var next = history; next.undo(); render(next)
    }

    func redo() {
        guard canEdit, canRedo else { return }
        if livePhoto != nil { var next = liveHistory; next.redo(); renderLive(next); return }
        var next = history; next.redo(); render(next)
    }

    private func render(_ next: EditHistory) {
        guard let original else { return }
        busy = true
        Task {
            do {
                image = try await Task.detached(priority: .userInitiated) {
                    try ImageEngine.render(original, operations: next.operations)
                }.value
                history = next
                cropRect = nil
                status = "本地编辑 · 保留原图"
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    func beginCrop() { guard canEdit else { return }; livePlayback.showCover(); cropping = true; cropRect = nil; zoom = 1; actualSize = false }
    func cancelCrop() { cropping = false; cropRect = nil }
    func commitCrop() {
        guard let cropRect, cropRect.width >= 1, cropRect.height >= 1 else { return }
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
            do {
                let (preview, composition) = try await Task.detached(priority: .userInitiated) {
                    (try await LivePhotoEngine.preview(livePhoto, original: original, edits: edits),
                     try await LivePhotoEngine.composition(for: livePhoto, edits: edits))
                }.value
                image = preview; liveHistory = next; cropRect = nil
                livePlayback.configure(livePhoto, composition: composition, coverTime: edits.coverTime)
                status = livePhoto.kind + " · 裁剪与封面 · 原件保留"
            } catch { self.error = error.localizedDescription }
            busy = false
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

    func setCenteredCrop(ratio: Double) {
        guard let image, cropping, !isReadOnly, !busy else { return }
        let w = Double(image.width), h = Double(image.height)
        let width = min(w, h * ratio), height = width / ratio
        cropRect = CGRect(x: floor((w - width) / 2), y: floor((h - height) / 2), width: floor(width), height: floor(height))
    }

    func resetZoom() { zoom = 1; actualSize = false }
    func showExport() { guard canEdit else { return }; exportSheet = true }

    func export() {
        if livePhoto != nil { exportLive(); return }
        guard let image, let fileURL, !isReadOnly, !busy, !choosingExportLocation else { return }
        let panel = NSSavePanel()
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

    private func writeExport(_ image: CGImage, source fileURL: URL, destination url: URL) {
        guard !isReadOnly else { return }
        // Even a user-selected export path must never silently replace the source.
        guard url.resolvingSymlinksInPath().standardizedFileURL != fileURL.resolvingSymlinksInPath().standardizedFileURL else {
            error = "请使用新的文件名导出，以保留原图。"; return
        }
        let format = exportFormat, quality = jpegQuality, snapshot = history.operations
        busy = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let data = try ImageEngine.encode(image, format: format, quality: quality)
                    try data.write(to: url, options: .atomic)
                }.value
                exportedOperations = snapshot
                status = "已导出 · " + url.lastPathComponent
                exportSheet = false
                busy = false
                let continuation = pendingAfterExport
                pendingAfterExport = nil
                continuation?()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    private func exportLive() {
        guard let livePhoto, let original, !busy, !choosingExportLocation else { return }
        let panel = NSSavePanel()
        panel.directoryURL = livePhoto.photoURL.deletingLastPathComponent()
        panel.nameFieldStringValue = livePhoto.photoURL.deletingPathExtension().lastPathComponent + "-edited-live"
        panel.title = "保存 Live Photo 配对文件夹"
        panel.message = "会创建新的文件夹，内含配对 JPG 与 MOV，保留动态内容和声音。"
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
                    self.status = "Live Photo 已导出 · " + url.lastPathComponent
                    self.exportSheet = false; self.busy = false
                    let continuation = self.pendingAfterExport; self.pendingAfterExport = nil; continuation?()
                } catch { self.error = error.localizedDescription; self.busy = false }
            }
        }
    }

    func cancelExport() { exportSheet = false; pendingAfterExport = nil }

    func requestLeave(_ continuation: @escaping () -> Void) {
        guard !busy else { return }
        guard dirty else { continuation(); return }
        let alert = NSAlert()
        alert.messageText = "当前图片还有未导出的修改"
        alert.informativeText = "导出后继续，或放弃本次修改。原始图片始终保留。"
        alert.addButton(withTitle: "导出后继续")
        alert.addButton(withTitle: "放弃修改")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: pendingAfterExport = continuation; exportSheet = true
        case .alertSecondButtonReturn: continuation()
        default: break
        }
    }
}
