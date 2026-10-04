import AppKit
import UniformTypeIdentifiers
import EasyPicCore

extension EditorModel {
    var canMergeDown: Bool {
        guard canUseLayers, !brushMode, let doc = document,
              let i = doc.layers.firstIndex(where: { $0.id == selectedLayerID }), doc.layers[i].visible else { return false }
        return i == 0 || doc.layers[i - 1].visible
    }
    var mergeDownTitle: String {
        document?.layers.first?.id == selectedLayerID ? "与原图合并" : "向下合并"
    }
    var canMergeVisible: Bool {
        canUseLayers && !brushMode && (document?.layers.filter(\.visible).count ?? 0) >= 2
    }
    func mergeLayers(_ mode: LayerMergeMode) {
        guard canUseLayers, !brushMode, let doc = document else { return }
        let assets = resources
        busy = true
        Task {
            do {
                let merged = try await Task.detached(priority: .userInitiated) {
                    try DocumentEngine.merge(doc, resources: assets, mode: mode)
                }.value
                resources[merged.resourceID] = merged.image
                selectedLayerID = merged.document.activeLayerID
                commitDocument(merged.document)
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
    func importSticker() {
        guard canUseLayers else { return }
        sidePanel = .edit; activeEditorTool = .sticker
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        choosingOpenLocation = true
        panel.begin { [weak self] response in
            guard let self else { return }; self.choosingOpenLocation = false
            if response == .OK, let url = panel.url { self.importSticker(from: url) }
        }
    }
    func importSticker(from url: URL) {
        guard canUseLayers else { return }
        sidePanel = .edit; activeEditorTool = .sticker
        busy = true
        Task {
            do {
                let loaded = try await Task.detached { try ImageEngine.load(url) }.value
                guard !loaded.mediaInfo.isReadOnly else { throw ImageFailure.unreadable }
                guard var doc = document else { busy = false; return }
                let id = UUID(), size = doc.size
                resources[id] = loaded.image
                let ratio = min(1, min(size.width * 0.5 / CGFloat(loaded.image.width), size.height * 0.5 / CGFloat(loaded.image.height)))
                let layer = StickerLayer(resourceID: id, name: url.lastPathComponent, center: CGPoint(x: size.width / 2, y: size.height / 2), size: CGSize(width: max(1, CGFloat(loaded.image.width) * ratio), height: max(1, CGFloat(loaded.image.height) * ratio)))
                doc.layers.append(layer); selectedLayerID = layer.id
                busy = false; commitDocument(doc)
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
    func commitDocument(_ doc: EditorDocument) {
        guard var next = documentHistory else { return }; next.apply(doc); renderDocument(next)
    }
    func renderDocument(_ next: DocumentHistory) {
        previewTask?.cancel(); draftLayer = nil
        busy = true
        let assets = resources, doc = next.document
        let cachedBase = document?.operations == doc.operations && document?.baseResourceID == doc.baseResourceID && document?.baseStrokes == doc.baseStrokes ? baseImage : nil
        Task {
            var succeeded = false
            do {
                let (base, preview) = try await Task.detached(priority: .userInitiated) {
                    let base = try cachedBase ?? DocumentEngine.renderBase(doc, resources: assets)
                    return (base, try DocumentEngine.render(doc, resources: assets, base: base, maxDimension: 1600))
                }.value
                documentHistory = next; baseImage = base; image = base; documentPreview = preview
                if !doc.layers.contains(where: { $0.id == selectedLayerID }) { selectedLayerID = nil }
                cropRect = nil; status = "可编辑图层 · 原图保留"
                succeeded = true
            } catch { self.error = error.localizedDescription }
            busy = false
            let continuation = pendingEditorAction; pendingEditorAction = nil
            if succeeded { continuation?() }
        }
    }
    func updateLayer(_ layer: StickerLayer, commit: Bool) {
        guard (canUseLayers || textEditing), var doc = document, let i = doc.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        doc.layers[i] = layer
        if commit { commitDocument(doc); return }
        draftLayer = layer
        previewTask?.cancel()
        let assets = resources, base = baseImage
        previewTask = Task {
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try DocumentEngine.render(doc, resources: assets, base: base, maxDimension: 1600)
                }.value
                guard !Task.isCancelled else { return }; documentPreview = preview
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func layerAction(_ action: String) {
        guard canUseLayers, var doc = document, let i = doc.layers.firstIndex(where: { $0.id == selectedLayerID }) else { return }
        switch action {
        case "delete": doc.layers.remove(at: i)
        case "duplicate": var copy = doc.layers[i]; copy.id = UUID(); copy.center.x += 20; copy.center.y += 20; doc.layers.insert(copy, at: i + 1); selectedLayerID = copy.id
        case "top": let layer = doc.layers.remove(at: i); doc.layers.append(layer)
        case "bottom": let layer = doc.layers.remove(at: i); doc.layers.insert(layer, at: 0)
        case "visibility": doc.layers[i].visible.toggle()
        default: return
        }
        commitDocument(doc)
    }
    func saveProject() {
        guard canUseLayers, var doc = document else { return }
        doc.activeLayerID = selectedLayerID
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(importedAs: "local.jyikove.easypic.project")]
        panel.nameFieldStringValue = projectURL?.lastPathComponent ?? (fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".easypic"
        panel.directoryURL = (projectURL ?? fileURL)?.deletingLastPathComponent()
        choosingExportLocation = true
        panel.begin { [weak self] response in
            guard let self else { return }; self.choosingExportLocation = false
            guard response == .OK, let url = panel.url else { self.pendingAfterExport = nil; return }
            guard url.pathExtension.lowercased() == "easypic",
                  url.resolvingSymlinksInPath().standardizedFileURL != self.fileURL?.resolvingSymlinksInPath().standardizedFileURL || url == self.projectURL else {
                self.error = "请使用 .easypic 项目文件名，保留原始图片。"; self.pendingAfterExport = nil; return
            }
            let assets = self.resources
            self.busy = true
            Task {
                do {
                    try await Task.detached { try DocumentEngine.save(doc, resources: assets, to: url) }.value
                    // Selection is persisted without making selection alone an edit.
                    self.savedDocument = self.document; self.projectURL = url
                    self.status = "已保存项目 · " + url.lastPathComponent; self.busy = false
                    let continuation = self.pendingAfterExport; self.pendingAfterExport = nil; continuation?()
                } catch { self.error = error.localizedDescription; self.busy = false; self.pendingAfterExport = nil }
            }
        }
    }
    func loadProject(_ url: URL) {
        busy = true
        Task {
            do {
                let (doc, assets, base, preview) = try await Task.detached {
                    let (doc, assets) = try DocumentEngine.load(url)
                    let base = try DocumentEngine.renderBase(doc, resources: assets)
                    return (doc, assets, base, try DocumentEngine.render(doc, resources: assets, base: base, maxDimension: 1600))
                }.value
                cancelBrush(); previewTask?.cancel(); playback.clear(); livePlayback.clear()
                livePhoto = nil; missingLivePair = false; mediaInfo = nil; originalTypeIdentifier = nil
                resources = assets; original = assets[doc.baseResourceID]; baseImage = base; image = base; documentPreview = preview
                documentHistory = DocumentHistory(doc); savedDocument = doc; projectURL = url; fileURL = url
                selectedLayerID = doc.activeLayerID; draftLayer = nil
                browsingFiles = []; zoom = 1; actualSize = false; cropRect = nil
                status = "项目已打开 · 可继续编辑"
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
