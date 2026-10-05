import SwiftUI
import EasyPicCore

enum EditorTool: String, CaseIterable, Identifiable {
    case undo, redo, crop, horizontal, vertical, rotate, sticker, text, solid, mosaic, repair
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
        case .undo: return L10n.text("撤销")
        case .redo: return L10n.text("重做（取消撤销）")
        case .crop: return L10n.text("裁剪")
        case .horizontal: return L10n.text("水平镜像")
        case .vertical: return L10n.text("垂直镜像")
        case .rotate: return L10n.text("逆时针旋转")
        case .sticker: return L10n.text("添加贴纸")
        case .text: return L10n.text("添加文本")
        case .solid: return L10n.text("纯色画笔")
        case .mosaic: return L10n.text("马赛克画笔")
        case .repair: return L10n.text("消除画笔")
        case .replaceOriginal: return L10n.text("保存并替换原图")
        case .saveAs: return L10n.text("另存为")
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
        case .replaceOriginal: return "square.and.arrow.down"
        case .saveAs: return "square.and.arrow.down.on.square"
        }
    }
}

extension EditorModel {
    /// Finish pending edits before switching tools.
    var canPerformEditorActions: Bool {
        image != nil && !isReadOnly && canRequestApplicationExit
    }
    var canRequestApplicationExit: Bool {
        !busy && !exportSheet && !choosingExportLocation &&
        !choosingOpenLocation && pendingOriginalReplacement == nil && !confirmingEditorExit && error == nil
    }
    var hasTextDraftChanges: Bool {
        guard textEditing, let draftLayer else { return false }
        if document?.layers.contains(where: { $0.id == draftLayer.id }) == false {
            return !(draftLayer.text?.content.isEmpty ?? true) || (draftLayer.text?.backgroundColor.alpha ?? 0) > 0
        }
        return document?.layers.first(where: { $0.id == draftLayer.id }) != draftLayer
    }
    func toolEnabled(_ tool: EditorTool) -> Bool {
        guard canPerformEditorActions else { return false }
        if livePhoto != nil && tool != .undo && tool != .redo && tool != .crop && tool != .saveAs { return false }
        if tool == .replaceOriginal { return canReplaceOriginal }
        if tool == .saveAs { return true }
        if tool == .undo { return canUndo || hasTextDraftChanges }
        if tool == .redo { return canRedo && !hasTextDraftChanges }
        return true
    }
    func finishInlineText(then action: @escaping () -> Void) {
        if cropping {
            finishCrop { [weak self] in self?.finishInlineText(then: action) }
            return
        }
        guard textEditing else { action(); return }
        guard var draft = draftLayer, draft.text?.isValid == true else {
            error = L10n.text("请先输入有效的文字设置。"); return
        }
        let changed = hasTextDraftChanges
        textEditing = false; previewTask?.cancel(); draftLayer = nil
        guard changed else {
            if document?.layers.contains(where: { $0.id == draft.id }) == false { selectedLayerID = nil }
            action(); return
        }
        draft.name = String(draft.text?.content.prefix(24) ?? "").replacingOccurrences(of: "\n", with: " ")
        if draft.name.isEmpty { draft.name = L10n.text("文字") }
        pendingEditorAction = action
        if var doc = document, !doc.layers.contains(where: { $0.id == draft.id }) {
            doc.layers.append(draft); commitDocument(doc)
        } else { updateLayer(draft, commit: true) }
    }
    func finishCrop(then action: @escaping () -> Void) {
        guard cropping else { action(); return }
        guard canApplyCrop, let rect = cropPixelRect else { return }
        // Leaving an unchanged full-image selection should not create history.
        if rect == CGRect(origin: .zero, size: cropImageSize) {
            cancelCrop(); action(); return
        }
        pendingEditorAction = action
        commitCrop()
        // Synchronous validation failures must not leave a stale continuation.
        if !busy { pendingEditorAction = nil }
    }
    func chooseEditorTool(_ tool: EditorTool) {
        guard toolEnabled(tool) else { return }
        startEditorSessionIfNeeded()
        if tool == .undo || tool == .redo {
            let current = activeEditorTool
            let ratio = cropRatio
            finishInlineText { [weak self] in
                guard let self else { return }
                self.cancelCrop(); self.cancelBrush()
                self.sidePanel = .edit; self.activeEditorTool = current
                self.pendingEditorAction = { [weak self] in self?.resumeEditorTool(current, cropRatio: ratio) }
                if tool == .undo { self.undo() } else { self.redo() }
            }
            return
        }
        finishInlineText { [weak self] in self?.activateEditorTool(tool) }
    }
    func resumeEditorTool(_ tool: EditorTool?, cropRatio ratio: CropRatio = .free) {
        activeEditorTool = tool
        switch tool {
        case .crop: beginCrop(); if ratio != .free { selectCropRatio(ratio) }
        case .solid, .mosaic, .repair: beginBrush()
        case .text: beginTextEditing()
        default: break
        }
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
        case .replaceOriginal: requestOriginalReplacement()
        case .saveAs: showExport()
        case .crop: beginCrop()
        case .solid: brushTool = .solid; beginBrush()
        case .mosaic:
            if brushTool != .blur && brushTool != .pixelate { brushTool = .pixelate }
            beginBrush()
        case .repair: brushTool = .repair; brushRectangle = false; beginBrush()
        case .text: beginTextEditing()
        case .sticker: break
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
        if sidePanel == .edit { requestEditorExit(); return }
        startEditorSessionIfNeeded()
        finishInlineText { [weak self] in
            guard let self else { return }
            self.cancelCrop(); self.cancelBrush(); self.activeEditorTool = nil
            self.sidePanel = .edit
            self.clearRecognition()
        }
    }
    func saveFromEditor() { finishInlineText { [weak self] in self?.saveProject() } }
    func exportFromEditor() { finishInlineText { [weak self] in self?.showExport() } }
}

struct EditingSidebar: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: EditorModel
    private let buttonHeight: CGFloat = 40
    private let buttonSpacing: CGFloat = 4
    private let railPadding: CGFloat = 6
    private var railHeight: CGFloat {
        let count = CGFloat(EditorTool.allCases.count)
        return count * buttonHeight + max(0, count - 1) * buttonSpacing + railPadding * 2
    }
    var body: some View {
        let _ = languageSettings.language
        HStack(spacing: 10) {
            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    GlassEffectContainer(spacing: 0) {
                    VStack(spacing: buttonSpacing) {
                        ForEach(EditorTool.allCases) { tool in
                            Button { model.chooseEditorTool(tool) } label: {
                                EditorToolIcon(tool: tool, selected: model.activeEditorTool == tool)
                                    .frame(width: buttonHeight, height: buttonHeight)
                            }
                            .buttonStyle(GlassButtonStyle(selected: model.activeEditorTool == tool, radius: 12, horizontalPadding: 0, verticalPadding: 0))
                            .contentShape(Rectangle())
                            .quickHelp(tool.title).accessibilityLabel(tool.title)
                            .disabled(!model.toolEnabled(tool))
                        }
                    }
                    .padding(railPadding)
                    }
                }
                .frame(height: min(geometry.size.height, railHeight))
                .glassSurface(.panel, radius: 18)
                .accessibilityLabel(L10n.text("编辑工具栏"))
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: buttonHeight + railPadding * 2)
            if let tool = model.activeEditorTool, tool.showsDetails {
                ZStack {
                    EditorToolDetails(model: model, tool: tool).id(tool)
                        .transition(.opacity)
                }
                .transition(EasyPicMotion.sidebarTransition(reduced: reduceMotion))
            }
        }
        .animation(EasyPicMotion.panelAnimation(reduced: reduceMotion), value: model.activeEditorTool)
    }
}

private struct EditorToolIcon: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    let tool: EditorTool
    let selected: Bool
    private var tint: Color { selected ? EasyPicGlass.accent : .primary }

    var body: some View {
        let _ = languageSettings.language
        Group {
            if tool == .mosaic {
                Canvas { context, size in
                    let cell = size.width / 4
                    for row in 0..<4 {
                        for column in 0..<4 {
                            let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                                              width: cell, height: cell)
                            context.fill(Path(rect), with: .color(tint.opacity((row + column).isMultiple(of: 2) ? 1 : 0.22)))
                        }
                    }
                }
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
            } else {
                Image(systemName: tool.icon).font(.system(size: 17, weight: .medium))
            }
        }
        .frame(width: 32, height: 32).foregroundStyle(tint)
        .accessibilityHidden(true)
    }
}

private struct EditorToolDetails: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    let tool: EditorTool
    @State private var panelSize = CGSize(width: 110, height: 540)
    var body: some View {
        let _ = languageSettings.language
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                panel.fixedSize(horizontal: true, vertical: true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
            }
            .frame(height: min(geometry.size.height, panelSize.height))
            .glassSurface(.panel, radius: 20)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard tool == .sticker else { return false }
                return model.importDroppedStickers(providers)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: panelSize.width)
        .disabled(model.busy)
    }
    private var closeButton: some View {
        Button(action: model.closeToolDetails) { Image(systemName: "xmark").frame(width: 22, height: 22) }
            .buttonStyle(GlassButtonStyle(radius: 7, horizontalPadding: 0, verticalPadding: 0)).quickHelp(L10n.text("收起工具详情")).accessibilityLabel(L10n.text("收起工具详情"))
            .disabled(!model.canPerformEditorActions)
    }
    // Flexible inputs need a usable width; ordinary controls keep their intrinsic size.
    private var minimumContentWidth: CGFloat? {
        switch tool {
        case .text: return model.textEditing ? 220 : nil
        case .solid, .mosaic, .repair: return 160
        default: return nil
        }
    }
    private var maximumContentWidth: CGFloat? {
        switch tool {
        case .crop: return nil
        case .text: return 260
        default: return 240
        }
    }
    private var panel: some View {
        VStack(alignment: tool == .crop ? .center : .leading, spacing: tool == .crop ? 10 : 16) {
            if tool == .crop {
                HStack(spacing: 10) {
                    closeButton
                    Button(action: model.closeToolDetails) {
                        Image(systemName: "checkmark").frame(width: 22, height: 22)
                    }
                    .buttonStyle(GlassButtonStyle(radius: 7, horizontalPadding: 0, verticalPadding: 0))
                    .accessibilityLabel(L10n.text("完成裁剪"))
                    .disabled(!model.canPerformEditorActions || !model.canApplyCrop)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack {
                    Spacer()
                    closeButton
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                    switch tool {
                    case .crop: CropToolControls(model: model)
                    case .sticker:
                        Button(action: model.importSticker) {
                            Text(L10n.text("导入贴纸…")).frame(maxWidth: .infinity, alignment: .center)
                        }.buttonStyle(GlassButtonStyle()).disabled(!model.canUseLayers)
                        LayerInspector(model: model, showsInsertionButtons: false, filter: .sticker)
                    case .text: TextToolControls(model: model)
                    case .solid, .mosaic, .repair: BrushToolControls(model: model)
                    case .undo, .redo, .horizontal, .vertical, .rotate, .replaceOriginal, .saveAs: EmptyView()
                    }
            }
            .frame(minWidth: minimumContentWidth, maxWidth: maximumContentWidth, alignment: .leading)
        }
        .font(.system(size: 13)).padding(tool == .crop ? 8 : 12)
    }
}

private struct CropToolControls: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .center, spacing: 10) {
            if model.cropping {
                VStack(spacing: 6) {
                    ForEach(CropRatio.allCases) { ratio in
                        Button { model.selectCropRatio(ratio) } label: {
                            Text(ratio.title)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .foregroundStyle(model.cropRatio == ratio ? EasyPicGlass.accent : .primary)
                        }
                        .buttonStyle(GlassButtonStyle(selected: model.cropRatio == ratio, radius: 8))
                        .accessibilityLabel(ratio.title)
                        .accessibilityAddTraits(model.cropRatio == ratio ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("裁剪比例"))
                if let rect = model.cropPixelRect {
                    Text("\(Int(rect.width)) × \(Int(rect.height)) px")
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 6)
                }
            } else {
                Button(L10n.text("开始裁剪"), action: model.beginCrop).buttonStyle(GlassButtonStyle())
                if model.livePhoto != nil { LivePhotoCoverControls(model: model, playback: model.livePlayback) }
            }
        }
    }
}

private struct TextToolControls: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .leading, spacing: 16) {
            Button {
                model.finishInlineText { model.addText() }
            } label: {
                Text(L10n.text("新增文字")).frame(maxWidth: .infinity, alignment: .center)
            }.buttonStyle(GlassButtonStyle()).disabled(!model.canPerformEditorActions)
            LayerInspector(model: model, showsInsertionButtons: false, fullWidthActions: true,
                           filter: .text, showsLayerProperties: !model.textEditing)
            if model.textEditing, let layer = model.selectedLayer, layer.text != nil {
                InlineTextEditor(model: model, layer: model.draftLayer ?? layer).id(layer.id)
            }
        }
    }
}
