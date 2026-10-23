import AppKit
import UniformTypeIdentifiers
import EasyPicCore

extension EditorModel {
    var canMergeAll: Bool {
        canPerformEditorActions && !cropping && !brushMode &&
            (!(document?.layers.isEmpty ?? true) || hasTextDraftChanges)
    }
    func mergeAllLayers() {
        guard canMergeAll else { return }
        finishInlineText { [weak self] in
            guard let self, self.canMergeAll, let doc = self.document else { return }
            let assets = self.resources, tool = self.activeEditorTool
            self.busy = true
            Task { [self] in
                do {
                    let merged = try await Task.detached(priority: .userInitiated) {
                        try DocumentEngine.merge(doc, resources: assets, mode: .all)
                    }.value
                    self.resources[merged.resourceID] = merged.image
                    self.selectedLayerID = nil
                    if tool == .text { self.pendingEditorAction = { [weak self] in self?.beginTextEditing() } }
                    self.commitDocument(merged.document)
                } catch { self.error = error.localizedDescription; self.busy = false }
            }
        }
    }
    var canMergeDown: Bool {
        guard canUseLayers, !brushMode, let doc = document,
              let i = doc.layers.firstIndex(where: { $0.id == selectedLayerID }), doc.layers[i].visible else { return false }
        return i == 0 || doc.layers[i - 1].visible
    }
    var mergeDownTitle: String {
        document?.layers.first?.id == selectedLayerID ? L10n.text("与原图合并") : L10n.text("向下合并")
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
        startEditorSessionIfNeeded()
        sidePanel = .edit; activeEditorTool = .sticker
        let panel = NSOpenPanel(); EasyPicGlass.prepareFilePanel(panel); panel.allowedContentTypes = [.image, .svg]
        choosingOpenLocation = true
        panel.begin { [weak self] response in
            guard let self else { return }; self.choosingOpenLocation = false
            if response == .OK, let url = panel.url { self.importSticker(from: url) }
        }
    }
    func importSticker(from url: URL) {
        importStickers(from: [url])
    }
    func importDroppedStickers(_ providers: [NSItemProvider]) -> Bool {
        guard canUseLayers, activeEditorTool == .sticker else { return false }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let expectedBase = document?.baseResourceID, expectedURL = fileURL
        Task {
            var urls: [URL] = []
            for provider in files {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            guard document?.baseResourceID == expectedBase, fileURL == expectedURL,
                  activeEditorTool == .sticker else { return }
            importStickers(from: urls)
        }
        return true
    }
    func importStickers(from urls: [URL]) {
        guard canUseLayers, !urls.isEmpty else { return }
        startEditorSessionIfNeeded()
        sidePanel = .edit; activeEditorTool = .sticker
        busy = true
        Task {
            do {
                let loaded = try await Task.detached {
                    try urls.map { url -> (URL, LoadedImage, Data?) in
                        let image = try ImageEngine.load(url)
                        guard !image.mediaInfo.isReadOnly || image.mediaInfo.isSVG else { throw ImageFailure.unreadable }
                        return (url, image, image.mediaInfo.isSVG ? try Data(contentsOf: url) : nil)
                    }
                }.value
                guard var doc = document else { busy = false; return }
                for (url, loaded, svg) in loaded {
                    let id = UUID(), size = doc.size
                    resources[id] = loaded.image
                    let ratio = min(1, min(size.width * 0.5 / CGFloat(loaded.image.width), size.height * 0.5 / CGFloat(loaded.image.height)))
                    var layer = StickerLayer(resourceID: id, name: url.lastPathComponent, center: CGPoint(x: size.width / 2, y: size.height / 2), size: CGSize(width: max(1, CGFloat(loaded.image.width) * ratio), height: max(1, CGFloat(loaded.image.height) * ratio)))
                    layer.svgData = svg
                    doc.layers.append(layer); selectedLayerID = layer.id
                }
                busy = false; commitDocument(doc)
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
    func commitDocument(_ doc: EditorDocument) {
        guard var next = documentHistory else { return }; next.apply(doc); renderDocument(next)
    }
    func renderDocument(_ next: DocumentHistory) {
        // Keep the visible draft until its committed composite is ready.
        previewTask?.cancel()
        renderRevision = UUID()
        let revision = renderRevision
        let trace = InteractionMetrics.shared.begin("DocumentCommit", parent: latestInteractionID)
        latestInteractionID = nil
        busy = true
        let assets = resources, doc = next.document
        let cachedBase = document?.operations == doc.operations && document?.baseResourceID == doc.baseResourceID && document?.baseStrokes == doc.baseStrokes && document?.adjustments == doc.adjustments ? baseImage : nil
        previewTask = Task {
            var succeeded = false
            do {
                let (base, preview) = try await renderService.render(doc, resources: assets, base: cachedBase, trace: trace)
                if let rotation = rotationTransition { await rotation.waitForCompletion() }
                guard renderRevision == revision else { return }
                rotationTransition = nil
                documentHistory = next; baseImage = base; image = base; documentPreview = preview
                clearAdjustmentDraft()
                draftLayer = nil; visualTraceID = trace
                InteractionMetrics.shared.mark(trace, "PreviewPublished")
                if !doc.layers.contains(where: { $0.id == selectedLayerID }) { selectedLayerID = nil }
                cropRect = nil; status = L10n.text("可编辑图层 · 原图保留")
                collectUnusedResources()
                succeeded = true
            } catch is CancellationError { }
            catch {
                guard renderRevision == revision else { return }
                self.error = error.localizedDescription
            }
            guard renderRevision == revision else { return }
            if !succeeded {
                clearAdjustmentDraft()
                draftLayer = layerReorderPreview != nil ? historyPresentation?.textLayer : nil
                rotationTransition = nil; layerReorderPreview = nil
            }
            previewTask = nil
            busy = false
            let continuation = pendingEditorAction; pendingEditorAction = nil
            if succeeded { continuation?() } else { historyPresentation = nil }
        }
    }
    func updateLayer(_ layer: StickerLayer, commit: Bool) {
        guard (canUseLayers || textEditing), let document else { return }
        let index = document.layers.firstIndex(where: { $0.id == layer.id })
        if index == nil {
            guard textEditing, activeEditorTool == .text, layer.text != nil, draftLayer?.id == layer.id else { return }
        }
        if commit {
            var next = document
            if let index { next.layers[index] = layer } else { next.layers.append(layer) }
            commitDocument(next)
        } else if draftLayer != layer {
            // A drag publishes only its layer, without copying or compositing the document.
            draftLayer = layer
        }
    }
    func collectUnusedResources() {
        var ids = documentHistory?.referencedResourceIDs ?? []
        if let savedDocument { ids.formUnion(savedDocument.referencedResourceIDs) }
        if let session = editorSession {
            ids.formUnion(session.history?.referencedResourceIDs ?? [])
            ids.formUnion(session.savedDocument?.referencedResourceIDs ?? [])
        }
        if let draftLayer, draftLayer.text == nil { ids.insert(draftLayer.resourceID) }
        resources = resources.filter { ids.contains($0.key) }
    }

    func deleteElement(_ id: UUID) {
        guard canPerformEditorActions, sidePanel == .edit,
              document?.layers.contains(where: { $0.id == id }) == true || draftLayer?.id == id else { return }
        let editing = textEditing && draftLayer?.id != id && draftLayer?.text?.isUnfinished == false ? draftLayer : nil
        if let editing { historyPresentation = EditorHistoryPresentation(textLayer: editing, cropRect: nil) }
        let resume: () -> Void = { [weak self] in
            guard let self else { return }
            if let editing, let saved = self.document?.layers.first(where: { $0.id == editing.id }),
               self.sidePanel == .edit, self.activeEditorTool == .text {
                self.selectedLayerID = saved.id; self.draftLayer = saved; self.textEditing = true
            }
            self.historyPresentation = nil
        }
        finishInlineText { [weak self] in
            guard let self, var next = self.document else { return }
            guard next.layers.contains(where: { $0.id == id }) else { resume(); return }
            next.layers.removeAll { $0.id == id }
            if self.selectedLayerID == id { self.selectedLayerID = nil }
            self.pendingEditorAction = resume
            self.commitDocument(next)
        }
        if error != nil { historyPresentation = nil }
    }
    func layerAction(_ action: String) {
        if action == "delete", let selectedLayerID { deleteElement(selectedLayerID); return }
        guard canUseLayers, var doc = document, let i = doc.layers.firstIndex(where: { $0.id == selectedLayerID }) else { return }
        switch action {
        case "delete": doc.layers.remove(at: i)
        case "duplicate":
            doc.numberBrushElements()
            var copy = doc.layers[i]; copy.id = UUID(); copy.center.x += 20; copy.center.y += 20
            if let shape = copy.brushElementShape {
                let number = doc.nextBrushElementNumber(for: shape)
                copy.brushElementNumber = number; copy.name = "\(shape.elementTitle) \(number)"
            }
            doc.layers.insert(copy, at: i + 1); selectedLayerID = copy.id
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
        let panel = NSSavePanel(); EasyPicGlass.prepareFilePanel(panel)
        panel.allowedContentTypes = [UTType(importedAs: "local.jyikove.easypic.project")]
        panel.nameFieldStringValue = projectURL?.lastPathComponent ?? (fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".easypic"
        panel.directoryURL = (projectURL ?? fileURL)?.deletingLastPathComponent()
        choosingExportLocation = true
        panel.begin { [weak self] response in
            guard let self else { return }; self.choosingExportLocation = false
            guard response == .OK, let url = panel.url else { self.pendingAfterExport = nil; return }
            guard url.pathExtension.lowercased() == "easypic",
                  url.resolvingSymlinksInPath().standardizedFileURL != self.fileURL?.resolvingSymlinksInPath().standardizedFileURL || url == self.projectURL else {
                self.error = L10n.text("请使用 .easypic 项目文件名，保留原始图片。"); self.pendingAfterExport = nil; return
            }
            let assets = self.resources
            self.busy = true
            Task {
                do {
                    try await Task.detached { try DocumentEngine.save(doc, resources: assets, to: url) }.value
                    // Selection is persisted without making selection alone an edit.
                    self.savedDocument = self.document; self.projectURL = url
                    self.checkpointEditorSession()
                    self.status = L10n.text("已保存项目 · ") + url.lastPathComponent; self.busy = false
                    let continuation = self.pendingAfterExport; self.pendingAfterExport = nil; continuation?()
                } catch { self.error = error.localizedDescription; self.busy = false; self.pendingAfterExport = nil }
            }
        }
    }
    func loadProject(_ url: URL) {
        clearAdjustmentDraft()
        busy = true
        Task {
            do {
                let (doc, assets, base, preview) = try await Task.detached {
                    let (doc, assets) = try DocumentEngine.load(url)
                    let base = try DocumentEngine.renderBase(doc, resources: assets)
                    return (doc, assets, base, try DocumentEngine.render(doc, resources: assets, base: base))
                }.value
                renderRevision = UUID(); contentID = UUID(); recognitionCache = [:]; recognitionCacheOrder = []
                cancelBrush(); previewTask?.cancel(); playback.clear(); livePlayback.clear()
                livePhoto = nil; missingLivePair = false; mediaInfo = nil; originalTypeIdentifier = nil; svgImage = nil
                resources = assets; original = assets[doc.baseResourceID]; baseImage = base; image = base; documentPreview = preview
                documentHistory = DocumentHistory(doc); savedDocument = doc; projectURL = url; fileURL = url
                selectedLayerID = doc.activeLayerID; draftLayer = nil
                browsingFiles = []; zoom = 1; actualSize = false; cropRect = nil
                status = L10n.text("项目已打开 · 可继续编辑")
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
