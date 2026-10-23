import SwiftUI
import EasyPicCore

enum EditorTool: String, CaseIterable, Identifiable {
    case undo, redo, crop, horizontal, vertical, rotate, adjust, sticker, text, solid, mosaic, repair
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
        case .adjust: return L10n.text("调整")
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
        case .adjust: return "slider.horizontal.3"
        case .sticker: return "photo.badge.plus"
        case .text: return "textformat"
        case .solid: return "paintbrush.pointed.fill"
        case .mosaic: return "square.grid.3x3.fill"
        case .repair: return "eraser.fill"
        case .replaceOriginal: return "square.and.arrow.down"
        case .saveAs: return "arrow.down.to.line"
        }
    }
}

/// Keep the current controls mounted while history commits and restores their tool.
struct EditorHistoryPresentation {
    let textLayer: StickerLayer?
    let cropRect: CGRect?
}

extension EditorModel {
    /// Finish pending edits before switching tools.
    var canPerformEditorActions: Bool {
        image != nil && !isReadOnly && canRequestApplicationExit && historyPresentation == nil
    }
    var canRequestApplicationExit: Bool {
        !busy && !exportSheet && !choosingExportLocation &&
        !choosingOpenLocation && pendingOriginalReplacement == nil && !confirmingEditorExit && error == nil
    }
    var hasTextDraftChanges: Bool {
        guard textEditing, let draftLayer else { return false }
        if document?.layers.contains(where: { $0.id == draftLayer.id }) == false {
            return draftLayer.text?.isUnfinished == false
        }
        return document?.layers.first(where: { $0.id == draftLayer.id }) != draftLayer
    }
    func toolEnabled(_ tool: EditorTool) -> Bool {
        guard canPerformEditorActions else { return false }
        if livePhoto != nil && tool != .undo && tool != .redo && tool != .crop && tool != .saveAs { return false }
        if tool == .replaceOriginal { return canReplaceOriginal }
        if tool == .saveAs { return true }
        if tool == .undo { return canUndo || hasTextDraftChanges || hasAdjustmentDraftChanges }
        if tool == .redo { return canRedo && !hasTextDraftChanges && !hasAdjustmentDraftChanges }
        return true
    }
    func finishInlineText(then action: @escaping () -> Void) {
        if hasAdjustmentDraftChanges {
            finishAdjustments { [weak self] in self?.finishInlineText(then: action) }
            return
        }
        if cropping {
            finishCrop { [weak self] in self?.finishInlineText(then: action) }
            return
        }
        guard var next = document else { action(); return }
        if textEditing {
            guard var draft = draftLayer, let text = draft.text else { return }
            if !text.isUnfinished {
                guard text.isValid else { error = L10n.text("请先输入有效的文字设置。"); return }
                draft.name = text.content
                if let index = next.layers.firstIndex(where: { $0.id == draft.id }) { next.layers[index] = draft }
                else { next.layers.append(draft) }
            } else { next.layers.removeAll { $0.id == draft.id } }
            textEditing = false; previewTask?.cancel()
        }
        next.layers.removeAll { $0.text?.isUnfinished == true }
        if !next.layers.contains(where: { $0.id == selectedLayerID }) { selectedLayerID = nil }
        guard next != document else { draftLayer = nil; action(); return }
        pendingEditorAction = action
        commitDocument(next)
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
            historyPresentation = EditorHistoryPresentation(textLayer: textEditing ? selectedLayer : nil,
                                                            cropRect: cropPixelRect)
            finishInlineText { [weak self] in
                guard let self else { return }
                self.cancelCrop()
                self.sidePanel = .edit; self.activeEditorTool = current
                self.pendingEditorAction = { [weak self] in
                    guard let self else { return }
                    self.resumeEditorTool(current, cropRatio: ratio)
                    self.historyPresentation = nil
                }
                if tool == .undo { self.undo() } else { self.redo() }
                // A crop commit may have consumed the available redo entry.
                if !self.busy {
                    let continuation = self.pendingEditorAction; self.pendingEditorAction = nil
                    continuation?()
                }
            }
            if error != nil || (!busy && pendingEditorAction == nil) { historyPresentation = nil }
            return
        }
        finishInlineText { [weak self] in self?.activateEditorTool(tool) }
    }
    func resumeEditorTool(_ tool: EditorTool?, cropRatio ratio: CropRatio = .free) {
        activeEditorTool = tool
        switch tool {
        case .crop: beginCrop(); if ratio != .free { selectCropRatio(ratio) }
        case .solid, .mosaic, .repair: if !brushMode { beginBrush() }
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
            brushTool = lastMosaicTool
            beginBrush()
        case .repair: brushTool = .repair; brushRectangle = false; beginBrush()
        case .text: beginTextEditing()
        case .sticker, .adjust: break
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
    func saveUsingShortcut() {
        guard canPerformEditorActions else { return }
        finishInlineText { [weak self] in
            guard let self else { return }
            if self.projectURL != nil { self.saveProject() }
            else if self.canReplaceOriginal { self.requestOriginalReplacement() }
            else { self.showExport() }
        }
    }
    func exportFromEditor() { finishInlineText { [weak self] in self?.showExport() } }
}

private struct EditorDetailsWidthPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct EditingSidebar: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: EditorModel
    @State private var detailsWidth: CGFloat = 264
    private let railTools = EditorTool.allCases.filter { ![.undo, .redo, .replaceOriginal, .saveAs].contains($0) }
    private let buttonHeight: CGFloat = 40
    private let buttonSpacing: CGFloat = 4
    private let railPadding: CGFloat = 6
    private var railHeight: CGFloat {
        let count = CGFloat(railTools.count)
        return count * buttonHeight + max(0, count - 1) * buttonSpacing + railPadding * 2
    }
    var body: some View {
        let _ = languageSettings.language
        HStack(spacing: 10) {
            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    GlassEffectContainer(spacing: 0) {
                    VStack(spacing: buttonSpacing) {
                        ForEach(railTools) { tool in
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
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .glassSurface(.panel, radius: 18)
                .accessibilityLabel(L10n.text("编辑工具栏"))
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: buttonHeight + railPadding * 2)
            if let tool = model.activeEditorTool, tool.showsDetails {
                ZStack {
                    // Preserve the panel's measured size while its tool changes.
                    EditorToolDetails(model: model, tool: tool)
                }
                .transition(EasyPicMotion.sidebarTransition(reduced: reduceMotion))
            }
        }
        .onPreferenceChange(EditorDetailsWidthPreference.self) { if $0 > 0 { detailsWidth = $0 } }
        .preference(key: SidebarWidthPreference.self,
                    value: model.sidePanel == .edit ? buttonHeight + railPadding * 2 + (model.activeEditorTool?.showsDetails == true ? 10 + detailsWidth : 0) : 0)
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
                FunctionIcon(systemName: tool.icon).font(.system(size: 17, weight: .medium))
            }
        }
        .frame(width: 32, height: 32).foregroundStyle(tint)
        .accessibilityHidden(true)
    }
}

private struct EditorToolDetails: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: EditorModel
    let tool: EditorTool
    @State private var panelSize = CGSize(width: 110, height: 540)
    @State private var measuredPanelSize = CGSize(width: 110, height: 540)
    @State private var historyLayoutLocked = false
    private var panelWidth: CGFloat { [.solid, .adjust].contains(tool) ? 264 : panelSize.width }
    private var layerFilter: LayerInspectorFilter? {
        switch tool {
        case .sticker: return .sticker
        case .text: return .text
        case .solid: return .brush
        default: return nil
        }
    }
    private var layerListHeight: CGFloat {
        layerFilter.map { LayerElementList.height(for: model.listedLayers(matching: $0).count) } ?? 0
    }
    var body: some View {
        let _ = languageSettings.language
        GeometryReader { geometry in
            VStack(spacing: layerListHeight > 0 ? 10 : 0) {
                if let filter = layerFilter, layerListHeight > 0 {
                    LayerElementList(model: model, filter: filter)
                        .frame(height: layerListHeight)
                        .transition(.opacity)
                }
                ScrollView(showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        panel.fixedSize(horizontal: true, vertical: true)
                            .id(tool)
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                                measuredPanelSize = size
                                guard model.historyPresentation == nil, !historyLayoutLocked else { return }
                                // Measure the natural content, not the animated outer frame.
                                guard abs(size.width - panelSize.width) > 0.5 || abs(size.height - panelSize.height) > 0.5 else { return }
                                panelSize = size
                            }
                            .transition(.opacity)
                    }
                    .animation(EasyPicMotion.panelAnimation(reduced: reduceMotion), value: tool)
                }
                .frame(height: min(max(0, geometry.size.height - layerListHeight - (layerListHeight > 0 ? 10 : 0)), panelSize.height))
                .animation(EasyPicMotion.panelAnimation(reduced: reduceMotion), value: panelSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .glassSurface(.panel, radius: 20)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard tool == .sticker else { return false }
                    return model.importDroppedStickers(providers)
                }
            }
            .animation(EasyPicMotion.panelAnimation(reduced: reduceMotion), value: layerListHeight)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: panelWidth)
        .animation(EasyPicMotion.panelAnimation(reduced: reduceMotion), value: panelWidth)
        // The native window receives the target once, instead of being retargeted
        // for every intermediate frame of the SwiftUI width animation.
        .preference(key: EditorDetailsWidthPreference.self, value: panelWidth)
        .onChange(of: model.historyPresentation != nil) { _, restoring in
            if restoring { historyLayoutLocked = true }
        }
        .task(id: model.historyPresentation != nil) {
            guard model.historyPresentation == nil, historyLayoutLocked else { return }
            // Native text/list measurements settle on the following layout pass.
            // Publish only the final size, never the temporary collapsed controls.
            do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
            guard model.historyPresentation == nil else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                panelSize = measuredPanelSize
                historyLayoutLocked = false
            }
        }
        .transaction {
            if model.historyPresentation != nil || historyLayoutLocked {
                $0.animation = nil; $0.disablesAnimations = true
            }
        }
        .disabled(model.busy || model.historyPresentation != nil)
    }
    private var closeButton: some View {
        Button(action: model.closeToolDetails) { FunctionIcon(systemName: "xmark").frame(width: 22, height: 22) }
            .buttonStyle(GlassButtonStyle(radius: 7, horizontalPadding: 0, verticalPadding: 0)).quickHelp(L10n.text("收起工具详情")).accessibilityLabel(L10n.text("收起工具详情"))
            .disabled(!model.canPerformEditorActions)
    }
    // Flexible inputs need a usable width; ordinary controls keep their intrinsic size.
    private var minimumContentWidth: CGFloat? {
        switch tool {
        case .text: return 220
        case .solid, .adjust: return 240
        case .mosaic, .repair: return 160
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
                        FunctionIcon(systemName: "checkmark").frame(width: 22, height: 22)
                    }
                    .buttonStyle(GlassButtonStyle(radius: 7, horizontalPadding: 0, verticalPadding: 0))
                    .accessibilityLabel(L10n.text("完成裁剪"))
                    .disabled(!model.canPerformEditorActions || !model.canApplyCrop)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 16) {
                    switch tool {
                    case .crop: CropToolControls(model: model)
                    case .sticker:
                        Button(action: model.importSticker) {
                            Text(L10n.text("导入贴纸…")).frame(maxWidth: .infinity, alignment: .center)
                        }.buttonStyle(GlassButtonStyle()).disabled(!model.canUseLayers)
                        if let selected = model.selectedLayer, selected.text == nil, selected.brushElementShape == nil {
                            LayerInspector(model: model, showsInsertionButtons: false, fullWidthActions: true, filter: .sticker)
                        }
                    case .adjust: AdjustmentToolControls(model: model)
                    case .text: TextToolControls(model: model)
                    case .solid, .mosaic, .repair: BrushToolControls(model: model)
                    case .undo, .redo, .horizontal, .vertical, .rotate, .replaceOriginal, .saveAs: EmptyView()
                    }
            }
            .frame(minWidth: minimumContentWidth, maxWidth: maximumContentWidth, alignment: .leading)
            .animation(EasyPicMotion.panelAnimation(reduced: reduceMotion), value: model.brushShape)
            .animation(EasyPicMotion.panelAnimation(reduced: reduceMotion), value: model.textEditing)
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
            if model.cropping || model.historyPresentation?.cropRect != nil {
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
                if let rect = model.historyPresentation?.cropRect ?? model.cropPixelRect {
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
    private var editingLayer: StickerLayer? {
        model.historyPresentation?.textLayer ?? (model.textEditing ? model.selectedLayer : nil)
    }
    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .leading, spacing: 16) {
            Button {
                model.finishInlineText { model.addText() }
            } label: {
                Text(L10n.text("新增文字")).frame(maxWidth: .infinity, alignment: .center)
            }.buttonStyle(GlassButtonStyle()).disabled(!model.canPerformEditorActions)
            if editingLayer == nil, model.selectedLayer?.text != nil {
                LayerInspector(model: model, showsInsertionButtons: false, fullWidthActions: true, filter: .text)
            }
            if let layer = editingLayer, layer.text != nil {
                InlineTextEditor(model: model, layer: layer).id(layer.id)
            }
        }
    }
}
