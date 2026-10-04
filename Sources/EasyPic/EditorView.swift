import SwiftUI
import AppKit
import EasyPicCore
import AVFoundation

private let accent = Color(red: 0.93, green: 0.73, blue: 0.43)

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var dropTarget = false

    var body: some View {
        HStack(spacing: 12) {
            canvas
            if model.image != nil {
                if model.sidePanel == .thumbnails {
                    FolderPreviewPanel(model: model)
                } else if model.sidePanel == .text {
                    TextRecognitionPanel(model: model)
                } else if model.sidePanel == .edit {
                    EditingSidebar(model: model)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 850, minHeight: 600)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                toolbarButton("上一张", "chevron.left", disabled: !model.canNavigatePrevious) { model.navigate(-1) }
                toolbarButton("下一张", "chevron.right", disabled: !model.canNavigateNext) { model.navigate(1) }
                toolbarButton("预览", "square.grid.2x2", disabled: model.image == nil || !model.canSwitchPanel, selected: model.sidePanel == .thumbnails) { model.togglePanel(.thumbnails) }
                toolbarButton("提取文本", "text.viewfinder", disabled: model.image == nil || !model.canSwitchPanel, selected: model.sidePanel == .text) { model.togglePanel(.text) }
                toolbarButton("逆时针旋转 90°", "arrow.counterclockwise", disabled: !model.canTransform || model.brushMode) { model.apply(.counterclockwise) }
                toolbarButton("编辑", "pencil.tip", disabled: !model.canPerformEditorActions, selected: model.sidePanel == .edit) { model.toggleEditor() }
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
        .background {
            ZStack {
                WindowMaterial()
                LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.2).opacity(0.86), Color(red: 0.07, green: 0.08, blue: 0.1).opacity(0.91)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [accent.opacity(0.09), .clear], center: .topLeading, startRadius: 10, endRadius: 650)
            }.ignoresSafeArea()
        }
        .background(WindowBridge(delegate: delegate))
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
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func toolbarButton(_ title: String, _ icon: String, disabled: Bool, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon) }
            .labelStyle(.iconOnly).help(title).accessibilityLabel(title)
            .foregroundStyle(selected ? accent : .primary)
            .disabled(disabled)
    }

    private var canvas: some View {
        ZStack {
            Color.black.opacity(0.18)
            if let image = model.image {
                ImageCanvas(model: model, image: image)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Button("打开图片", action: model.openPanel).buttonStyle(.glassProminent).tint(accent).controlSize(.large)
                }
            }
            if model.busy {
                VStack(spacing: 10) { ProgressView(); Text("处理中…").font(.caption) }
                    .padding(24).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(dropTarget ? accent : Color.white.opacity(0.1), lineWidth: dropTarget ? 2 : 1))
    }

}

struct EditFileControls: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        HStack {
            if model.livePhoto == nil {
                Button("保存项目", action: model.saveFromEditor).disabled(!model.canPerformEditorActions || model.cropping)
            }
            Spacer(minLength: 0)
            Button("导出", action: model.exportFromEditor).disabled(!model.canPerformEditorActions || model.cropping)
        }
        .buttonStyle(.glass).controlSize(.small)
    }
}

struct ImageCanvas: View {
    @ObservedObject var model: EditorModel
    let image: CGImage
    @State private var panOffset: CGSize = .zero

    var body: some View {
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
                    if model.aiSelecting { AISelectionOverlay(model:model,scale:scale,size:size) }
                    else if model.cropping { CropOverlay(model: model, size: size, scale: scale) }
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
    @ObservedObject var playback: ImagePlayback
    let poster: CGImage
    var body: some View {
        Image(decorative: playback.frame ?? poster, scale: 1).resizable().interpolation(.high)
    }
}

struct ExportView: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(accent); Text("另存为").font(.title2.weight(.medium)) }
            Text("按当前图片的完整像素尺寸导出。缩放比例不影响导出质量。").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Text("格式"); Spacer(); Picker("格式", selection: $model.exportFormat) { Text("PNG").tag(ExportFormat.png); Text("JPG").tag(ExportFormat.jpg) }.labelsHidden().pickerStyle(.segmented).frame(width: 190) }
            HStack { Text("尺寸"); Spacer(); Text(model.dimensions + " px").monospaced() }
            if model.exportFormat == .jpg {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("质量"); Spacer(); Text("\(Int(model.jpegQuality * 100))%").monospaced() }
                    Slider(value: $model.jpegQuality, in: 0.1...1)
                    Text("透明区域会填充白色背景。").font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("无损导出，保留透明区域。").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("取消", action: model.cancelExport).keyboardShortcut(.cancelAction).buttonStyle(.glass).tint(.clear)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("选择保存位置…", action: model.export).keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
        }
        .font(.system(size: 13))
        .padding(30).frame(width: 400)
        .preferredColorScheme(.dark).tint(accent)
        .disabled(model.busy || model.choosingExportLocation)
        .interactiveDismissDisabled()
    }
}

struct LivePhotoCoverControls: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var playback: LivePhotoPlayback
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: playback.toggle) { Label(playback.isPlaying ? "暂停" : "播放", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") }
                Button(action: playback.restart) { Image(systemName: "backward.end.fill") }.help("从头播放")
            }.buttonStyle(.glass)
            Toggle("静音", isOn: $playback.muted).font(.system(size: 12))
            if let live = model.livePhoto {
                Slider(value: Binding(get: { playback.position }, set: { playback.seek($0) }), in: 0...max(0.001, live.lastFrameTime))
                    .accessibilityLabel("Live Photo 封面时间")
                Text(String(format: "%.2f / %.2f 秒", playback.position, live.duration)).font(.system(size: 11, design: .monospaced))
            }
            Button("将当前帧设为封面", action: model.setLiveCover).buttonStyle(.glassProminent).tint(accent)
            Button("查看封面", action: playback.showCover).buttonStyle(.glass)
            Button("恢复原始封面", action: model.restoreLiveCover).buttonStyle(.glass).disabled(model.liveHistory.edits.coverTime == nil)
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .disabled(!model.canEdit)
    }
}

struct LivePhotoFrameView: View {
    @ObservedObject var playback: LivePhotoPlayback
    let poster: CGImage
    var body: some View {
        Image(decorative: playback.showingMotion ? (playback.frame ?? poster) : poster, scale: 1)
            .resizable().interpolation(.high)
    }
}

struct LivePhotoExportView: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("导出 Live Photo", systemImage: "livephoto").font(.title2.weight(.medium))
            Text("创建新的配对文件夹，包含 LivePhoto.JPG 和 LivePhoto.MOV。照片与视频同步裁剪，保留声音，并记录所选封面的时间。")
            Text("可直接在 EasyPic 中重新打开导出的 JPG 或 MOV。向 Apple“照片”导入时，请同时选择这两个文件。")
                .foregroundStyle(.secondary)
            Text("MOV 使用 H.264 编码；照片为 JPG。当前输出为 SDR，不保留原始 HEVC/HDR 编码。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消", action: model.cancelExport).keyboardShortcut(.cancelAction).buttonStyle(.glass)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("选择保存位置…", action: model.export).keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
        }
        .font(.system(size: 13)).padding(30).frame(width: 440)
        .preferredColorScheme(.dark).tint(accent)
        .disabled(model.busy || model.choosingExportLocation).interactiveDismissDisabled()
    }
}
