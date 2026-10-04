import AppKit
import SwiftUI
import UniformTypeIdentifiers
import EasyPicCore

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
    let playback = ImagePlayback()
    private var original: CGImage?
    private var exportedOperations: [EditOperation] = []
    private var pendingAfterExport: (() -> Void)?
    var isReadOnly: Bool { mediaInfo?.isReadOnly == true }
    var dirty: Bool { !isReadOnly && image != nil && history.operations != exportedOperations }
    var dimensions: String { image.map { "\($0.width) × \($0.height)" } ?? "" }
    var canBrowse: Bool { !busy && !cropping && !exportSheet && !choosingExportLocation }
    var canEdit: Bool { image != nil && !isReadOnly && canBrowse }
    var currentIndex: Int? { fileURL.flatMap { browsingFiles.firstIndex(of: $0) } }

    func openPanel() {
        guard !busy, !exportSheet, !choosingExportLocation else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择图片，或选择文件夹连续浏览"
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
                let (loaded, target, siblings) = try await Task.detached(priority: .userInitiated) {
                    let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentTypeKey, .isRegularFileKey]
                    let directory = try input.resourceValues(forKeys: keys).isDirectory == true
                        ? input : input.deletingLastPathComponent()
                    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
                    let pictures = files.filter {
                        guard let values = try? $0.resourceValues(forKeys: keys), values.isRegularFile == true else { return false }
                        return values.contentType?.conforms(to: .image) == true
                    }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    let isFolder = (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    guard let target = isFolder ? pictures.first : input else { throw ImageFailure.unreadable }
                    return (try ImageEngine.load(target), target, pictures)
                }.value
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
                if loaded.mediaInfo.animation != nil { status = "动图 · 只读播放" }
                else if loaded.mediaInfo.isGIF { status = "GIF · 只读查看" }
                else { status = loaded.frameCount > 1 ? "多页图片 · 当前查看和编辑首页" : "本地编辑 · 保留原图" }
                playback.configure(url: target, poster: loaded.image, animation: loaded.mediaInfo.animation)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    func navigate(_ direction: Int) {
        guard canBrowse, let index = currentIndex else { return }
        let next = index + direction
        if browsingFiles.indices.contains(next) { open(browsingFiles[next]) }
    }

    func apply(_ operation: EditOperation) {
        guard canEdit else { return }
        var next = history
        next.apply(operation)
        render(next)
    }

    func undo() {
        guard canEdit, history.canUndo else { return }
        var next = history; next.undo(); render(next)
    }

    func redo() {
        guard canEdit, history.canRedo else { return }
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

    func beginCrop() { guard canEdit else { return }; cropping = true; cropRect = nil; zoom = 1; actualSize = false }
    func cancelCrop() { cropping = false; cropRect = nil }
    func commitCrop() {
        guard let cropRect, cropRect.width >= 1, cropRect.height >= 1 else { return }
        cropping = false
        apply(.crop(cropRect))
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
