import SwiftUI
import EasyPicCore

enum EditorTool: String, CaseIterable, Identifiable {
    case undo, redo, crop, horizontal, vertical, rotate, sticker, text, solid, mosaic, repair, ai
    case replaceOriginal, saveAs
    var id: Self { self }
    var showsDetails: Bool {
        switch self {
        case .undo, .redo, .horizontal, .vertical, .rotate, .replaceOriginal, .saveAs: return false
        default: return true
        }
    }
    var title: String {
        switch self {
        case .undo: return "撤销"
        case .redo: return "重做（取消撤销）"
        case .crop: return "裁剪"
        case .horizontal: return "水平镜像"
        case .vertical: return "垂直镜像"
        case .rotate: return "逆时针旋转"
        case .sticker: return "添加贴纸"
        case .text: return "添加文本"
        case .solid: return "纯色画笔"
        case .mosaic: return "马赛克画笔"
        case .repair: return "消除画笔"
        case .ai: return "AI 编辑"
        case .replaceOriginal: return "保存并替换原图"
        case .saveAs: return "另存为"
        }
    }
    var icon: String {
        switch self {
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .crop: return "crop"
        case .horizontal: return "arrow.left.and.right"
        case .vertical: return "arrow.up.and.down"
        case .rotate: return "arrow.counterclockwise"
        case .sticker: return "photo.badge.plus"
        case .text: return "textformat"
        case .solid: return "paintbrush.pointed.fill"
        case .mosaic: return "square.grid.3x3.fill"
        case .repair: return "eraser.fill"
        case .ai: return "sparkles"
        case .replaceOriginal: return "square.and.arrow.down"
        case .saveAs: return "square.and.arrow.down.on.square"
        }
    }
}

extension EditorModel {
    /// The rail can finish an inline text draft or cancel a crop before switching tools.
    var canPerformEditorActions: Bool {
        image != nil && !isReadOnly && !busy && !exportSheet && !choosingExportLocation &&
        !choosingOpenLocation && !aiRunning && !aiSelecting
    }
    var hasTextDraftChanges: Bool {
        guard textEditing, let draftLayer else { return false }
        return document?.layers.first(where: { $0.id == draftLayer.id }) != draftLayer
    }
    func toolEnabled(_ tool: EditorTool) -> Bool {
        guard canPerformEditorActions else { return false }
        if livePhoto != nil && tool != .undo && tool != .redo && tool != .crop && tool != .saveAs { return false }
        if tool == .replaceOriginal { return canReplaceOriginal }
        if tool == .saveAs { return !cropping }
        if tool == .undo { return canUndo || hasTextDraftChanges }
        if tool == .redo { return canRedo && !hasTextDraftChanges }
        return true
    }
    func finishInlineText(then action: @escaping () -> Void) {
        guard textEditing else { action(); return }
        guard var draft = draftLayer, draft.text?.isValid == true else {
            error = "请先输入有效的文字设置。"; return
        }
        let changed = hasTextDraftChanges
        textEditing = false; previewTask?.cancel(); draftLayer = nil
        guard changed else { action(); return }
        draft.name = String(draft.text?.content.prefix(24) ?? "").replacingOccurrences(of: "\n", with: " ")
        if draft.name.isEmpty { draft.name = "文字" }
        pendingEditorAction = action
        updateLayer(draft, commit: true)
    }
    func chooseEditorTool(_ tool: EditorTool) {
        guard toolEnabled(tool) else { return }
        finishInlineText { [weak self] in self?.activateEditorTool(tool) }
    }
    private func activateEditorTool(_ tool: EditorTool) {
        let collapse = activeEditorTool == tool && tool.showsDetails
        cancelCrop(); cancelBrush()
        sidePanel = .edit; activeEditorTool = collapse || !tool.showsDetails ? nil : tool
        guard !collapse else { return }
        switch tool {
        case .undo: undo()
        case .redo: redo()
        case .horizontal: apply(.mirrorHorizontal)
        case .vertical: apply(.mirrorVertical)
        case .rotate: apply(.counterclockwise)
        case .replaceOriginal: saveReplacingOriginal()
        case .saveAs: showExport()
        case .crop: beginCrop()
        case .solid: brushTool = .solid; beginBrush()
        case .mosaic:
            if brushTool != .blur && brushTool != .pixelate { brushTool = .pixelate }
            beginBrush()
        case .repair: brushTool = .repair; brushRectangle = false; beginBrush()
        case .text: if selectedLayer?.text != nil { editText() }
        case .sticker, .ai: break
        }
    }
    func closeToolDetails() {
        guard canPerformEditorActions else { return }
        finishInlineText { [weak self] in
            self?.cancelCrop(); self?.cancelBrush(); self?.activeEditorTool = nil
        }
    }
    func toggleEditor() {
        guard canPerformEditorActions else { return }
        finishInlineText { [weak self] in
            guard let self else { return }
            self.cancelCrop(); self.cancelBrush(); self.activeEditorTool = nil
            self.sidePanel = self.sidePanel == .edit ? nil : .edit
            self.clearRecognition()
        }
    }
    func saveFromEditor() { finishInlineText { [weak self] in self?.saveProject() } }
    func exportFromEditor() { finishInlineText { [weak self] in self?.showExport() } }
}

struct EditingSidebar: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        HStack(spacing: 10) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(EditorTool.allCases) { tool in
                        Button { model.chooseEditorTool(tool) } label: {
                            Image(systemName: tool.icon).font(.system(size: 17, weight: .medium))
                                .frame(width: 32, height: 32)
                                .foregroundStyle(model.activeEditorTool == tool ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.glass).controlSize(.small)
                        .help(tool.title).accessibilityLabel(tool.title)
                        .disabled(!model.toolEnabled(tool))
                    }
                }.padding(8)
            }
            .frame(width: 56)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityLabel("编辑工具栏")
            if let tool = model.activeEditorTool, tool.showsDetails {
                EditorToolDetails(model: model, tool: tool)
            }
        }
    }
}

private struct EditorToolDetails: View {
    @ObservedObject var model: EditorModel
    let tool: EditorTool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                Button(action: model.closeToolDetails) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("收起工具详情").accessibilityLabel("收起工具详情")
                    .disabled(!model.canPerformEditorActions)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tool {
                    case .crop: CropToolControls(model: model)
                    case .sticker:
                        Button("导入图片贴纸…", action: model.importSticker).buttonStyle(.glass).disabled(!model.canUseLayers)
                        LayerInspector(model: model, showsInsertionButtons: false)
                    case .text: TextToolControls(model: model)
                    case .solid, .mosaic, .repair: BrushToolControls(model: model)
                    case .ai: AIEditorControls(model: model)
                    case .undo, .redo, .horizontal, .vertical, .rotate, .replaceOriginal, .saveAs: EmptyView()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            EditFileControls(model: model)
        }
        .font(.system(size: 13)).padding(tool == .crop ? 12 : 18).frame(width: tool == .crop ? 210 : 340)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        .disabled(model.busy)
    }
}

private struct CropToolControls: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.cropping {
                Picker("比例", selection: Binding(get: { model.cropRatio }, set: { model.selectCropRatio($0) })) {
                    ForEach(CropRatio.allCases) { ratio in Text(ratio.title).tag(ratio) }
                }
                .labelsHidden().accessibilityLabel("裁剪比例")
                if let rect = model.cropPixelRect {
                    Text("\(Int(rect.width)) × \(Int(rect.height)) px").font(.system(.caption, design: .monospaced))
                }
                Button("应用裁剪", action: model.commitCrop).buttonStyle(.glassProminent).disabled(!model.canApplyCrop)
                Button("取消裁剪", action: model.cancelCrop).buttonStyle(.glass).keyboardShortcut(.escape, modifiers: [])
            } else {
                Button("开始裁剪", action: model.beginCrop).buttonStyle(.glass)
                if model.livePhoto != nil { LivePhotoCoverControls(model: model, playback: model.livePlayback) }
            }
        }
    }
}

private struct TextToolControls: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button("添加文本") {
                model.finishInlineText { model.addText() }
            }.buttonStyle(.glass).disabled(!model.canPerformEditorActions)
            if model.textEditing, let layer = model.selectedLayer, layer.text != nil {
                InlineTextEditor(model: model, layer: layer).id(layer.id)
            } else if model.selectedLayer?.text != nil {
                Button("编辑当前文字", action: model.editText).buttonStyle(.glass).disabled(!model.canUseLayers)
            }
            Divider()
            LayerInspector(model: model, showsInsertionButtons: false)
        }
    }
}
