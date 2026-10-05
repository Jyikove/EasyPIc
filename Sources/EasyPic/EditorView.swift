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
    @StateObject private var sidebarLayout = SidebarWindowSizer(minimumWidth: SidebarWindowSizer.minimumViewerWidth)
    private let windowInset: CGFloat = 12
    private let minimumWindowWidth = SidebarWindowSizer.minimumViewerWidth

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
                    } else if model.sidePanel == .text {
                        TextRecognitionPanel(model: model)
                            .transition(.opacity)
                    } else if model.sidePanel == .edit {
                        EditingSidebar(model: model)
                            .transition(.opacity)
                    }
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: SidebarWidthPreference.self, value: geometry.size.width)
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
        .disabled(showingDialog).allowsHitTesting(!showingDialog)
        .padding(.horizontal, windowInset)
        .padding(.bottom, windowInset)
        .padding(.top, windowInset - toolbarBottomSpacing)
        .frame(minWidth: minimumWindowWidth, minHeight: minimumWindowWidth, alignment: .topLeading)
        .onPreferenceChange(SidebarWidthPreference.self) { width in
            sidebarWidth = width > 0 ? width + 12 : 0
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 12) {
                toolbarButton(L10n.text("上一张"), "chevron.left", disabled: !model.canNavigatePrevious) { model.navigate(-1) }
                toolbarButton(L10n.text("下一张"), "chevron.right", disabled: !model.canNavigateNext) { model.navigate(1) }
                toolbarButton(L10n.text("预览"), "square.grid.2x2", disabled: model.image == nil || !model.canSwitchPanel, selected: model.sidePanel == .thumbnails) { model.togglePanel(.thumbnails) }
                toolbarButton(L10n.text("提取文本"), "text.viewfinder", disabled: model.image == nil || !model.canSwitchPanel, selected: model.sidePanel == .text) { model.togglePanel(.text) }
                toolbarButton(L10n.text("逆时针旋转 90°"), "arrow.counterclockwise", disabled: !model.viewerControlsEnabled || !model.canTransform || model.brushMode) { model.apply(.counterclockwise) }
                toolbarButton(L10n.text("编辑"), "pencil.tip", disabled: !model.canPerformEditorActions, selected: model.sidePanel == .edit) { model.toggleEditor() }
                }
                .background(ToolbarSpacingReader { toolbarBottomSpacing = $0 })
            }
        }
        .toolbar(removing: .title)
        .onAppear {
            let action = openWindow
            delegate.showEditor = { action(id: "editor") }
        }
        .onChange(of: model.document) { _, _ in model.recognizeText() }
        .onChange(of: model.liveHistory.edits) { _, _ in model.recognizeText() }
        .onChange(of: model.fileURL) { _, _ in model.recognizeText() }
        .onChange(of: model.cropping) { _, cropping in if cropping { model.sidePanel = .edit } }
        .onChange(of: model.brushMode) { _, painting in if painting { model.sidePanel = .edit } }
        .glassWindowBackground()
        .background(WindowBridge(delegate: delegate, model: model))
        .background(SidebarWindowBridge(sizer: sidebarLayout, sidebarWidth: sidebarWidth))
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
        model.error != nil || model.pendingOriginalReplacement != nil || model.confirmingEditorExit
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

    private func toolbarButton(_ title: String, _ icon: String, disabled: Bool, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).frame(width: 32, height: 28).contentShape(Rectangle()) }
            .buttonStyle(GlassButtonStyle(selected: selected, radius: 9, horizontalPadding: 0, verticalPadding: 0))
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

struct ImageCanvas: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    let image: CGImage
    @State private var panOffset: CGSize = .zero

    var body: some View {
        let _ = languageSettings.language
        GeometryReader { geometry in
            let available = CGSize(width: max(1, geometry.size.width - 56), height: max(1, geometry.size.height - 56))
            let fit = min(available.width / Double(image.width), available.height / Double(image.height))
            let base = model.actualSize ? 1 / (NSScreen.main?.backingScaleFactor ?? 2) : fit
            let scale = base * model.zoom
            let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
            ZStack {
                ZStack(alignment: .topLeading) {
                    checkerboard(size: size)
                    if model.livePhoto != nil {
                        LivePhotoFrameView(playback: model.livePlayback, poster: image).frame(width: size.width, height: size.height)
                    } else if model.mediaInfo?.animation != nil {
                        AnimatedFrameView(playback: model.playback, poster: image).frame(width: size.width, height: size.height)
                    } else {
                        Image(decorative: model.documentPreview ?? image, scale: 1).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                    }
                    if model.cropping { CropOverlay(model: model, size: size, scale: scale) }
                    else if model.brushMode { BrushOverlay(model:model,scale:scale,size:size) }
                    else if model.sidePanel == .edit && (model.activeEditorTool == .sticker || model.activeEditorTool == .text) && model.livePhoto == nil && !model.isReadOnly { LayerCanvasOverlay(model: model, scale: scale, size: size) }
                }
                .frame(width: size.width, height: size.height)
                .offset(panOffset)
                .shadow(color: .black.opacity(0.3), radius: 22, y: 10)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(CanvasInputBridge { event, point in
                guard !model.cropping else { return }
                if event.type == .scrollWheel {
                    panOffset.width += event.scrollingDeltaX
                    panOffset.height += event.scrollingDeltaY
                } else {
                    let next = min(8, max(0.1, model.zoom * (1 + event.magnification)))
                    let ratio = next / model.zoom
                    panOffset = CGSize(width: (panOffset.width + geometry.size.width / 2 - point.x) * ratio + point.x - geometry.size.width / 2,
                                       height: (panOffset.height + geometry.size.height / 2 - point.y) * ratio + point.y - geometry.size.height / 2)
                    model.zoom = next
                }
            })
            .clipped()
            .onAppear { model.brushCanvasScale = scale }
            .onChange(of: scale) { _, scale in model.brushCanvasScale = scale }
            .onChange(of: model.fileURL) { _, _ in panOffset = .zero }
            .onChange(of: model.viewportReset) { _, _ in panOffset = .zero }
        }
    }

    private func checkerboard(size: CGSize) -> some View {
        Canvas { context, area in
            context.fill(Path(CGRect(origin: .zero, size: area)), with: .color(Color(white: 0.20)))
            let tile = 12.0
            for y in stride(from: 0.0, to: area.height, by: tile) {
                for x in stride(from: 0.0, to: area.width, by: tile) where (Int(x / tile) + Int(y / tile)) % 2 == 0 {
                    context.fill(Path(CGRect(x: x, y: y, width: tile, height: tile)), with: .color(Color(white: 0.25)))
                }
            }
        }.frame(width: size.width, height: size.height)
    }

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

struct ExportView: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .leading, spacing: 24) {
            HStack { Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(accent); Text(L10n.text("另存为")).font(.title2.weight(.medium)) }
            Text(L10n.text("按当前图片的完整像素尺寸导出。缩放比例不影响导出质量。")).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Text(L10n.text("格式")); Spacer(); GlassSegmentedPicker(selection: $model.exportFormat, options: [("PNG", .png), ("JPG", .jpg)]).frame(width: 190).accessibilityLabel(L10n.text("格式")) }
            HStack { Text(L10n.text("尺寸")); Spacer(); Text(model.dimensions + " px").monospaced() }
            if model.exportFormat == .jpg {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(L10n.text("质量")); Spacer(); Text("\(Int(model.jpegQuality * 100))%").monospaced() }
                    GlassSlider(value: $model.jpegQuality, in: 0.1...1)
                    Text(L10n.text("透明区域会填充白色背景。")).font(.caption).foregroundStyle(.secondary)
                }
            } else { Text(L10n.text("无损导出，保留透明区域。")).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(L10n.text("取消"), action: model.cancelExport).keyboardShortcut(.cancelAction).buttonStyle(GlassButtonStyle())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(L10n.text("选择保存位置…"), action: model.export).keyboardShortcut(.defaultAction).buttonStyle(GlassButtonStyle(prominent: true))
            }
        }
        .font(.system(size: 13))
        .padding(30).frame(width: 400)
        .glassSurface(.floating, radius: 24).glassWindowBackground().presentationBackground(.clear)
        .glassEntrance()
        .preferredColorScheme(.dark).tint(accent)
        .disabled(model.busy || model.choosingExportLocation)
        .interactiveDismissDisabled()
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
        Image(decorative: playback.showingMotion ? (playback.frame ?? poster) : poster, scale: 1)
            .resizable().interpolation(.high)
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
