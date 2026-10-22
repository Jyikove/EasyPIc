import SwiftUI
import AppKit
import EasyPicCore
import AVFoundation

private let accent = EasyPicGlass.accent

struct EditorView: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTarget = false
    @State private var toolbarBottomSpacing: CGFloat = 0
    @State private var sidebarWidth: CGFloat = 0
    @State private var titleWidth: CGFloat = 1180
    @State private var navigationExpanded = false
    @StateObject private var sidebarLayout = SidebarWindowSizer(minimumWidth: SidebarWindowSizer.minimumViewerWidth)
    private let windowInset = CanvasLayout.windowInset
    private let minimumWindowWidth = SidebarWindowSizer.minimumViewerWidth
    private let toolbarButtonHeight: CGFloat = 22
    private let toolbarControlInset: CGFloat = 3
    // The actual capsule is hosted in the titlebar at the whole-window midpoint.
    private let expandedToolbarWidth: CGFloat = 314
    private var filenameWidth: CGFloat {
        let stableWidth = sidebarLayout.viewportWidth ?? titleWidth
        // Navigation now retracts in editing mode, so the filename only needs
        // one normal button gap beside the collapsed, four-button center capsule.
        return max(0, min(180, (stableWidth - 154) / 2 - 238))
    }
    private var navigationContentWidth: CGFloat {
        108 + (model.fileURL != nil && filenameWidth > 0 ? filenameWidth + 28 : 0)
    }


    var body: some View {
        let _ = languageSettings.language
        GeometryReader { geometry in
            let panelWidth = model.image != nil && model.sidePanel != nil ? sidebarWidth : 0
            let canvasWidth = sidebarLayout.viewportWidth ?? max(1, geometry.size.width - panelWidth)
            ZStack(alignment: .topLeading) {
            canvas.frame(width: canvasWidth, height: geometry.size.height)
                .transaction { $0.animation = nil }
            if model.image != nil, model.sidePanel != nil {
                ZStack {
                    if model.sidePanel == .thumbnails {
                        FolderPreviewPanel(model: model)
                            .transition(.opacity)
                    } else if model.isRecognitionPanel {
                        TextRecognitionPanel(model: model)
                            .transition(.opacity)
                    } else if model.sidePanel == .edit {
                        EditingSidebar(model: model)
                            .transition(.opacity)
                    }
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: SidebarWidthPreference.self, value: model.sidePanel == .edit ? 0 : geometry.size.width)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: geometry.size.height)
                .offset(x: canvasWidth + 12)
                .transition(EasyPicMotion.sidebarTransition(reduced: reduceMotion))
            }
            }
            .animation(EasyPicMotion.panelAnimation(reduced: reduceMotion), value: model.sidePanel)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            if sidebarLayout.viewportWidth == nil { titleWidth = $0 }
        }
        .disabled(showingDialog).allowsHitTesting(!showingDialog)
        .padding(.horizontal, windowInset)
        .padding(.bottom, windowInset)
        .padding(.top, windowInset - toolbarBottomSpacing)
        .frame(minWidth: minimumWindowWidth, minHeight: minimumWindowWidth, alignment: .topLeading)
        .onPreferenceChange(SidebarWidthPreference.self) { width in
            sidebarWidth = width > 0 ? width + 12 : 0
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                navigationToolbar
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .principal) {
                // Keep the native titlebar height without allowing NSToolbar to
                // choose the horizontal center of the visible controls.
                Color.clear.frame(width: 1, height: toolbarButtonHeight + 2 * toolbarControlInset)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbar(removing: .title)
        .onAppear {
            let action = openWindow
            delegate.showEditor = { action(id: "editor") }
        }
        .onChange(of: model.document) { _, _ in model.recognizeText() }
        .onChange(of: model.liveHistory.edits) { _, _ in model.recognizeText() }
        .onChange(of: model.fileURL) { _, _ in model.recognizeText() }
        .onChange(of: model.sidePanel) { _, _ in navigationExpanded = false }
        .onChange(of: model.cropping) { _, cropping in if cropping { model.sidePanel = .edit } }
        .onChange(of: model.brushMode) { _, painting in if painting { model.sidePanel = .edit } }
        .glassWindowBackground()
        .background(WindowBridge(delegate: delegate, model: model))
        .background(SidebarWindowBridge(sizer: sidebarLayout, sidebarWidth: sidebarWidth))
        .background(WindowCenteredToolbar(width: expandedToolbarWidth, height: toolbarButtonHeight + 2 * toolbarControlInset,
                                          hitWidth: model.sidePanel == .edit ? expandedToolbarWidth : 154) {
            centeredToolbar.environmentObject(languageSettings)
                .disabled(showingDialog || model.exportSheet)
                .preferredColorScheme(.dark).tint(accent)
        })
        .preferredColorScheme(.dark)
        .tint(accent)
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            guard let provider = providers.first, !model.busy else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url, viewingOnly: true) } }
            }
            return true
        }
        .sheet(isPresented: $model.exportSheet, onDismiss: model.cancelExport) {
            if model.livePhoto != nil { LivePhotoExportView(model: model) }
            else { ExportView(model: model) }
        }
        .overlay {
            ZStack { dialogOverlay }
                .allowsHitTesting(showingDialog)
                .animation(EasyPicMotion.popupAnimation(reduced: reduceMotion), value: dialogKind)
        }
    }
    private var showingDialog: Bool {
        (model.error != nil && !model.exportSheet) || model.pendingOriginalReplacement != nil || model.confirmingEditorExit
    }
    private var dialogKind: String? {
        if model.error != nil { return "error" }
        if model.pendingOriginalReplacement != nil { return "replace" }
        return model.confirmingEditorExit ? "exit" : nil
    }
    @ViewBuilder private var dialogOverlay: some View {
        if showingDialog {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { }
                if let error = model.error {
                    GlassDialog(title: L10n.text("操作未完成"), message: L10n.display(error), icon: "exclamationmark.triangle") {
                        Button(L10n.text("好")) { model.error = nil }
                            .buttonStyle(GlassButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    }
                    .glassPopupTransition()
                } else if let target = model.pendingOriginalReplacement {
                    GlassDialog(title: L10n.text("替换原图？"),
                                message: L10n.text("将用当前编辑结果替换“{0}”。是否继续？", target.lastPathComponent)) {
                        VStack(spacing: 8) {
                            Button(L10n.text("保存并替换原图"), action: model.confirmOriginalReplacement)
                                .buttonStyle(GlassButtonStyle(destructive: true)).keyboardShortcut(.defaultAction)
                            Button(L10n.text("取消"), action: model.cancelOriginalReplacement)
                                .buttonStyle(GlassButtonStyle()).keyboardShortcut(.cancelAction)
                        }
                    }
                    .glassPopupTransition()
                } else {
                    GlassDialog(title: L10n.text("退出编辑？"), message: L10n.text("保存更改后退出？")) {
                        VStack(spacing: 8) {
                            Button(L10n.text(model.editorExitUsesReplacement ? "保存并替换原图" : "另存为"), action: model.saveAndExitEditor)
                                .buttonStyle(GlassButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                            Button(L10n.text("不保存"), action: model.discardEditorSession)
                                .buttonStyle(GlassButtonStyle(destructive: true))
                            Button(L10n.text("取消"), action: model.cancelEditorExit)
                                .buttonStyle(GlassButtonStyle()).keyboardShortcut(.cancelAction)
                        }
                    }
                    .glassPopupTransition()
                }
            }
            .transition(.opacity)
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 12) {
            toolbarButton(L10n.text("上一张"), "chevron.left", disabled: !model.canNavigatePrevious) { model.navigate(-1) }
            toolbarButton(L10n.text("下一张"), "chevron.right", disabled: !model.canNavigateNext) { model.navigate(1) }
            toolbarButton(L10n.text("预览"), "square.grid.2x2", disabled: model.image == nil || !model.canSwitchPanel, selected: model.sidePanel == .thumbnails) { model.togglePanel(.thumbnails) }
        }
    }
    private var navigationToolbar: some View {
        let editing = model.sidePanel == .edit
        return ZStack(alignment: .leading) {
            if editing {
                Button { navigationExpanded.toggle() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary).frame(width: 22, height: 22).contentShape(Circle())
                }
                .buttonStyle(.plain).quickHelp(L10n.text("图片导航"))
                .accessibilityLabel(L10n.text("图片导航"))
                .disabled(showingDialog || model.exportSheet)
                .popover(isPresented: $navigationExpanded, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    navigationButtons.padding(8)
                        .background(Capsule().fill(Color(red: 0.08, green: 0.20, blue: 0.34).opacity(0.8)))
                        .glassPopover(radius: 20)
                        .environmentObject(languageSettings)
                }
                .transition(.opacity)
            } else {
                HStack(spacing: 12) {
                    navigationButtons
                    if let name = model.fileURL?.lastPathComponent, filenameWidth > 0 {
                        Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                            .lineLimit(1).truncationMode(.middle).frame(width: filenameWidth)
                            .padding(.horizontal, 8).frame(height: toolbarButtonHeight)
                            .background(Capsule().fill(EasyPicGlass.blue.opacity(0.8)))
                            .quickHelp(name).accessibilityLabel(name)
                    }
                }.transition(.opacity)
            }
        }
        .frame(width: editing ? 22 : navigationContentWidth, height: toolbarButtonHeight, alignment: .leading)
        .clipped().padding(toolbarControlInset)
        .glassSurface(.panel, radius: 14)
        .animation(EasyPicMotion.panelAnimation(reduced: reduceMotion), value: editing)
        // Keep AppKit's leading origin steady while the visible capsule retracts left.
        .frame(width: navigationContentWidth + 6, alignment: .leading).fixedSize()
    }

    private var centeredToolbar: some View {
        HStack(spacing: 12) {
            toolbarButton(L10n.text("提取文本"), "text.viewfinder", disabled: model.image == nil || !model.canSwitchPanel, selected: model.sidePanel == .text) { model.togglePanel(.text) }
            toolbarButton(L10n.text("二维码"), "qrcode.viewfinder", disabled: model.image == nil || !model.canSwitchPanel, selected: model.sidePanel == .qr) { model.togglePanel(.qr) }
            toolbarButton(L10n.text("逆时针旋转 90°"), "arrow.counterclockwise", disabled: !model.viewerControlsEnabled || !model.canRotate || model.brushMode) { model.apply(.counterclockwise) }
            editorToolbarGroup
        }
        .padding(toolbarControlInset).fixedSize()
        .glassSurface(.panel, radius: toolbarButtonHeight / 2 + toolbarControlInset)
        .background(ToolbarSpacingReader { toolbarBottomSpacing = $0 })
        .animation(EasyPicMotion.panelAnimation(reduced: reduceMotion), value: model.sidePanel == .edit)
        .frame(width: expandedToolbarWidth, height: toolbarButtonHeight + 2 * toolbarControlInset)
    }

    private var editorToolbarGroup: some View {
        let editing = model.sidePanel == .edit
        return HStack(spacing: 12) {
            toolbarButton(L10n.text(editing ? "取消编辑" : "编辑"), editing ? "xmark" : "pencil.tip",
                          disabled: !model.canPerformEditorActions, selected: editing, grouped: editing) { model.toggleEditor() }
            if editing {
                toolbarButton(L10n.text("撤销"), "arrow.uturn.backward", disabled: !model.toolEnabled(.undo), grouped: true) { model.chooseEditorTool(.undo) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                toolbarButton(L10n.text("重做（取消撤销）"), "arrow.uturn.forward", disabled: !model.toolEnabled(.redo), grouped: true) { model.chooseEditorTool(.redo) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                toolbarButton(L10n.text("保存并替换原图"), "square.and.arrow.down", disabled: !model.toolEnabled(.replaceOriginal), grouped: true) { model.chooseEditorTool(.replaceOriginal) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                toolbarButton(L10n.text("另存为"), "arrow.down.to.line", disabled: !model.toolEnabled(.saveAs), grouped: true) { model.chooseEditorTool(.saveAs) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .background {
            if editing {
                Capsule().fill(Color(red: 0.08, green: 0.20, blue: 0.34).opacity(0.84))
                    .overlay(Capsule().strokeBorder(EasyPicGlass.edge(.control, highlighted: true), lineWidth: 0.8))
            }
        }
    }

    private func toolbarButton(_ title: String, _ icon: String, disabled: Bool, selected: Bool = false, grouped: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(width: 28, height: toolbarButtonHeight).contentShape(Rectangle()) }
            .buttonStyle(ToolbarIconStyle(selected: selected, grouped: grouped, radius: toolbarButtonHeight / 2))
            .labelStyle(.iconOnly).quickHelp(title).accessibilityLabel(title)
            .foregroundStyle(selected ? accent : .primary)
            .disabled(disabled)
    }

    private var canvas: some View {
        ZStack {
            Color.clear
            if let image = model.image {
                ImageCanvas(model: model, image: image)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Button(L10n.text("打开图片"), action: model.openPanel).buttonStyle(GlassButtonStyle(prominent: true)).tint(accent).controlSize(.large)
                }
            }
        }
        .glassSurface(.canvas, radius: 22)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(dropTarget ? accent : .clear, lineWidth: dropTarget ? 2 : 1))
    }

}

private struct ToolbarIconStyle: ButtonStyle {
    let selected: Bool
    let grouped: Bool
    let radius: CGFloat
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if grouped {
            configuration.label
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.5))
                .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.18 : (hovered ? 0.10 : 0))))
                .contentShape(Capsule())
                .onHover { hovered = $0 }
        } else {
            GlassButtonStyle(selected: selected, radius: radius, horizontalPadding: 0, verticalPadding: 0)
                .makeBody(configuration: configuration)
        }
    }
}

struct ImageCanvas: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    let image: CGImage
    @StateObject private var frameClock = CanvasFrameClock()
    @StateObject private var camera = CanvasCamera()
    private var canvasZoom: Double {
        get { camera.zoom }
        nonmutating set { camera.update(zoom: newValue) }
    }
    private var panOffset: CGSize {
        get { camera.pan }
        nonmutating set { camera.update(pan: newValue) }
    }
    private var usesNativeViewport: Bool {
        model.rotationTransition == nil && model.svgImage == nil && model.livePhoto == nil &&
        model.mediaInfo?.animation == nil && model.sidePanel != .edit && !model.isRecognitionPanel
    }
    @State private var panDragOrigin: CGSize?
    private var allowsPanGesture: Bool {
        !model.hasRecognitionSelection && (model.viewerControlsEnabled ||
            (model.sidePanel == .edit && model.canPerformEditorActions &&
             model.activeEditorTool == nil && !model.cropping && !model.brushMode && !model.textEditing))
    }

    var body: some View {
        let _ = languageSettings.language
        let _ = { camera.publishesChanges = !usesNativeViewport }()
        GeometryReader { geometry in
            let available = CGSize(width: max(1, geometry.size.width - 2 * CanvasLayout.imageInset),
                                   height: max(1, geometry.size.height - 2 * CanvasLayout.imageInset))
            let fit = min(available.width / Double(image.width), available.height / Double(image.height))
            let base = model.actualSize ? 1 / (NSScreen.main?.backingScaleFactor ?? 2) : fit
            let scale = base * canvasZoom
            let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
            ZStack {
                if usesNativeViewport {
                    NativeRasterViewport(image: model.documentPreview ?? image, camera: camera, actualSize: model.actualSize,
                                         active: model.windowIsRendering, clock: frameClock)
                } else {
                ZStack(alignment: .topLeading) {
                    if model.rotationTransition == nil { checkerboard(size: size) }
                    if let rotation = model.rotationTransition {
                        let rotatedFit = min(available.width / Double(image.height), available.height / Double(image.width))
                        RotatingImageView(transition: rotation, size: size, finalScale: model.actualSize ? 1 : rotatedFit / fit)
                            .frame(width: size.width, height: size.height).id(rotation.id)
                    } else if let svgImage = model.svgImage {
                        SVGImageView(image: svgImage, poster: image, sourceURL: model.fileURL,
                                     viewport: CGRect(x: (size.width - geometry.size.width) / 2 - panOffset.width,
                                                      y: (size.height - geometry.size.height) / 2 - panOffset.height,
                                                      width: geometry.size.width, height: geometry.size.height), quarterTurns: model.svgQuarterTurns).frame(width: size.width, height: size.height)
                    } else if model.livePhoto != nil {
                        LivePhotoFrameView(playback: model.livePlayback, poster: image).frame(width: size.width, height: size.height)
                    } else if model.mediaInfo?.animation != nil {
                        AnimatedFrameView(playback: model.playback, poster: image).frame(width: size.width, height: size.height)
                    } else if model.sidePanel == .edit, let document = model.document, let background = model.baseImage {
                        InteractiveDocumentView(document: document, draft: model.draftLayer, resources: model.resources,
                                                base: background, service: model.renderService, scale: scale, size: size,
                                                viewport: CGRect(x: (size.width - geometry.size.width) / 2 - panOffset.width,
                                                                 y: (size.height - geometry.size.height) / 2 - panOffset.height,
                                                                 width: geometry.size.width, height: geometry.size.height), spatialIndex: model.sceneIndex)
                    } else {
                        NativeRasterImage(image: model.documentPreview ?? image).frame(width: size.width, height: size.height)
                    }
                    if model.rotationTransition != nil { Color.clear.allowsHitTesting(false) }
                    else if model.cropping { CropOverlay(model: model, size: size, scale: scale) }
                    else if model.brushMode { BrushOverlay(model:model,scale:scale,size:size) }
                    else if model.sidePanel == .edit && (model.activeEditorTool == .sticker || model.activeEditorTool == .text) && model.livePhoto == nil && !model.isReadOnly { LayerCanvasOverlay(model: model, scale: scale, size: size) }
                    if model.isRecognitionPanel { RecognitionOverlay(model: model, size: size) }
                }
                .frame(width: size.width, height: size.height)
                .offset(panOffset)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard allowsPanGesture else { return }
                        let origin = panDragOrigin ?? panOffset
                        panDragOrigin = origin
                        frameClock.submit("CanvasDrag", at: ProcessInfo.processInfo.systemUptime - max(0, Date().timeIntervalSince(value.time))) {
                            panOffset = CGSize(width: origin.width + value.translation.width,
                                               height: origin.height + value.translation.height)
                        }
                    }
                    .onEnded { _ in frameClock.flush("CanvasDrag"); panDragOrigin = nil },
                including: allowsPanGesture ? .all : .subviews
            )
            .environmentObject(frameClock)
            .background(FramePresentationProbe(clock: frameClock, trace: model.visualTraceID))
            .background(CanvasInputBridge(
                frameClock: frameClock,
                spacePanEnabled: model.sidePanel == .edit && model.canPerformEditorActions,
                shouldBeginPan: { point in
                    let origin = CGPoint(x: (geometry.size.width - size.width) / 2 + panOffset.width,
                                         y: (geometry.size.height - size.height) / 2 + panOffset.height)
                    let imagePoint = CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
                    return model.canPanBehindLayers(at: imagePoint, scale: scale)
                },
                pan: { delta in
                    guard model.canPerformEditorActions else { return }
                    panOffset.width += delta.width
                    panOffset.height += delta.height
                }
            ) { event, point in
                guard !model.cropping, !model.hasRecognitionSelection else { return }
                let zoomFactor: Double
                if event.type == .scrollWheel {
                    // Keep wheel-down zooming in, regardless of Natural Scrolling.
                    let delta = Double(event.scrollingDeltaY) * (event.isDirectionInvertedFromDevice ? -1 : 1)
                    guard delta != 0 else { return }
                    zoomFactor = exp(-delta * (event.hasPreciseScrollingDeltas ? 0.005 : 0.05))
                } else {
                    zoomFactor = 1 + Double(event.magnification)
                }
                let next = min(8, max(0.1, canvasZoom * zoomFactor))
                let ratio = next / canvasZoom
                camera.update(zoom: next, pan: CGSize(width: (panOffset.width + geometry.size.width / 2 - point.x) * ratio + point.x - geometry.size.width / 2,
                                   height: (panOffset.height + geometry.size.height / 2 - point.y) * ratio + point.y - geometry.size.height / 2))
            })
            .clipped()
            .onAppear { frameClock.setRenderingActive(model.windowIsRendering); canvasZoom = model.zoom; if model.brushMode { model.brushCanvasScale = scale } }
            .onChange(of: model.windowIsRendering) { _, active in frameClock.setRenderingActive(active) }
            .environment(\.canvasRenderingActive, model.windowIsRendering)
            .onChange(of: model.zoom) { _, zoom in canvasZoom = zoom }
            .onChange(of: model.actualSize) { _, _ in canvasZoom = model.zoom }
            .onChange(of: scale) { _, scale in if model.brushMode { model.brushCanvasScale = scale } }
            .onChange(of: model.brushMode) { _, enabled in if enabled { model.brushCanvasScale = scale } }
            .onChange(of: model.fileURL) { _, _ in canvasZoom = model.zoom; panOffset = .zero; panDragOrigin = nil }
            .onChange(of: model.viewportReset) { _, _ in canvasZoom = model.zoom; panOffset = .zero; panDragOrigin = nil }
            .onChange(of: allowsPanGesture) { _, enabled in if !enabled { panDragOrigin = nil } }
        }
    }

    private func checkerboard(size: CGSize) -> some View {
        Rectangle().fill(ImagePaint(image: Self.checkerTile, scale: 1))
            .frame(width: size.width, height: size.height)
    }
    private static let checkerTile: Image = {
        let context = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.20, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        context.setFillColor(CGColor(gray: 0.25, alpha: 1))
        context.fill([CGRect(x: 0, y: 0, width: 12, height: 12), CGRect(x: 12, y: 12, width: 12, height: 12)])
        return Image(decorative: context.makeImage()!, scale: 1)
    }()


}

struct AnimatedFrameView: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var playback: ImagePlayback
    let poster: CGImage
    var body: some View {
        let _ = languageSettings.language
        Image(decorative: playback.frame ?? poster, scale: 1).resizable().interpolation(.high)
    }
}

struct LivePhotoCoverControls: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    @ObservedObject var playback: LivePhotoPlayback
    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: playback.toggle) { Label(playback.isPlaying ? L10n.text("暂停") : L10n.text("播放"), systemImage: playback.isPlaying ? "pause.fill" : "play.fill") }
                Button(action: playback.restart) { Image(systemName: "backward.end.fill") }.quickHelp(L10n.text("从头播放"))
            }.buttonStyle(GlassButtonStyle())
            Toggle(L10n.text("静音"), isOn: $playback.muted).toggleStyle(GlassToggleStyle()).font(.system(size: 12))
            if let live = model.livePhoto {
                GlassSlider(value: Binding(get: { playback.position }, set: { playback.seek($0) }), in: 0...max(0.001, live.lastFrameTime))
                    .accessibilityLabel(L10n.text("Live Photo 封面时间"))
                Text(String(format: L10n.text("%.2f / %.2f 秒"), playback.position, live.duration)).font(.system(size: 11, design: .monospaced))
            }
            Button(L10n.text("将当前帧设为封面"), action: model.setLiveCover).buttonStyle(GlassButtonStyle(prominent: true)).tint(accent)
            Button(L10n.text("查看封面"), action: playback.showCover).buttonStyle(GlassButtonStyle())
            Button(L10n.text("恢复原始封面"), action: model.restoreLiveCover).buttonStyle(GlassButtonStyle()).disabled(model.liveHistory.edits.coverTime == nil)
            if let error = playback.error { Text(L10n.display(error)).font(.caption).foregroundStyle(.red) }
        }
        .disabled(!model.canEdit)
    }
}

struct LivePhotoFrameView: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var playback: LivePhotoPlayback
    let poster: CGImage
    var body: some View {
        let _ = languageSettings.language
        Group {
            if playback.showingMotion { NativeLivePhotoView(player: playback.player) }
            else { Image(decorative: poster, scale: 1).resizable().interpolation(.high) }
        }
    }
}

struct LivePhotoExportView: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .leading, spacing: 20) {
            Label(L10n.text("导出 Live Photo"), systemImage: "livephoto").font(.title2.weight(.medium))
            Text(L10n.text("创建新的配对文件夹，包含 LivePhoto.JPG 和 LivePhoto.MOV。照片与视频同步裁剪，保留声音，并记录所选封面的时间。"))
            Text(L10n.text("可直接在 EasyPic 中重新打开导出的 JPG 或 MOV。向 Apple“照片”导入时，请同时选择这两个文件。"))
                .foregroundStyle(.secondary)
            Text(L10n.text("MOV 使用 H.264 编码；照片为 JPG。当前输出为 SDR，不保留原始 HEVC/HDR 编码。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("取消"), action: model.cancelExport).keyboardShortcut(.cancelAction).buttonStyle(GlassButtonStyle())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(L10n.text("选择保存位置…"), action: model.export).keyboardShortcut(.defaultAction).buttonStyle(GlassButtonStyle(prominent: true))
            }
        }
        .font(.system(size: 13)).padding(30).frame(width: 440)
        .glassSurface(.floating, radius: 24).glassWindowBackground().presentationBackground(.clear)
        .glassEntrance()
        .preferredColorScheme(.dark).tint(accent)
        .disabled(model.busy || model.choosingExportLocation).interactiveDismissDisabled()
    }
}
