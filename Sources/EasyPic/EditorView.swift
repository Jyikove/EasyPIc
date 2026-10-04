import SwiftUI
import AppKit
import EasyPicCore

private let accent = Color(red: 0.93, green: 0.73, blue: 0.43)

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let delegate: AppDelegate
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 16) {
            header
            HStack(spacing: 16) {
                canvas
                if model.image != nil {
                    if model.isReadOnly { ReadOnlyInspector(model: model, playback: model.playback) }
                    else { inspector }
                }
            }
            footer
        }
        .padding(20)
        .padding(.top, 8)
        .frame(minWidth: 850, minHeight: 600)
        .background {
            ZStack {
                WindowMaterial()
                LinearGradient(colors: [Color(red: 0.13, green: 0.16, blue: 0.2).opacity(0.86), Color(red: 0.07, green: 0.08, blue: 0.1).opacity(0.91)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [accent.opacity(0.09), .clear], center: .topLeading, startRadius: 10, endRadius: 650)
            }.ignoresSafeArea()
        }
        .background(WindowBridge(delegate: delegate))
        .preferredColorScheme(.dark)
        .tint(.clear)
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            guard let provider = providers.first, !model.busy else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url) } }
            }
            return true
        }
        .sheet(isPresented: $model.exportSheet, onDismiss: model.cancelExport) { ExportView(model: model) }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "viewfinder").font(.system(size: 22, weight: .light)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("EasyPic").font(.system(size: 15, weight: .semibold, design: .rounded)).tracking(4)
                Text("让图片编辑轻一点").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = model.fileURL {
                Text(url.lastPathComponent).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                if model.dirty { Circle().fill(accent).frame(width: 5, height: 5).help("有未导出的修改") }
            }
            Spacer()
            Button(action: model.openPanel) { Label("打开", systemImage: "folder") }.buttonStyle(.glass).disabled(model.busy || model.cropping)
            Button(action: model.showExport) { Label("导出", systemImage: "square.and.arrow.up") }.buttonStyle(.glassProminent).tint(accent).disabled(!model.canEdit)
        }
        .controlSize(.large)
    }

    private var canvas: some View {
        ZStack {
            Color.black.opacity(0.18)
            if let image = model.image {
                ImageCanvas(model: model, image: image)
            } else {
                VStack(spacing: 22) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 62, weight: .ultraLight)).foregroundStyle(accent.opacity(0.9))
                        .padding(26).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
                    VStack(spacing: 10) {
                        Text("每张图片，都值得好好看").font(.system(size: 24, weight: .medium))
                        Text("拖入图片开始，或打开整个文件夹浏览").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Button("打开图片", action: model.openPanel).buttonStyle(.glassProminent).tint(accent).controlSize(.large)
                    Text("JPG · PNG · HEIC · TIFF · WebP · GIF 动图").font(.system(size: 10)).tracking(1).foregroundStyle(.tertiary)
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

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text(model.cropping ? "裁剪图片" : "基础编辑").font(.system(size: 14, weight: .semibold)); Spacer(); Image(systemName: model.cropping ? "crop" : "slider.horizontal.3").foregroundStyle(accent) }
            if model.cropping {
                Text("在图片上拖出选区。再次拖动可以重新选择范围。").font(.system(size: 12)).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Button("居中 1 : 1") { model.setCenteredCrop(ratio: 1) }
                    Button("居中 4 : 3") { model.setCenteredCrop(ratio: 4.0 / 3) }
                    Button("居中 16 : 9") { model.setCenteredCrop(ratio: 16.0 / 9) }
                }.buttonStyle(.glass).frame(maxWidth: .infinity)
                if let rect = model.cropRect { Text("\(Int(rect.width)) × \(Int(rect.height)) px").font(.system(size: 12, design: .monospaced)).foregroundStyle(accent) }
                Button(action: model.commitCrop) { Label("应用裁剪", systemImage: "checkmark") }.buttonStyle(.glassProminent).tint(accent).disabled(model.cropRect == nil || model.busy)
                Button("取消", action: model.cancelCrop).buttonStyle(.glass).keyboardShortcut(.escape, modifiers: [])
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    caption("构图")
                    Button(action: model.beginCrop) { Label("裁剪图片", systemImage: "crop").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.glass)
                }
                VStack(alignment: .leading, spacing: 12) {
                    caption("旋转")
                    HStack {
                        editButton("左转", "rotate.left") { model.apply(.counterclockwise) }
                        editButton("右转", "rotate.right") { model.apply(.clockwise) }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    caption("镜像")
                    HStack {
                        editButton("水平", "arrow.left.and.right.righttriangle.left.righttriangle.right") { model.apply(.mirrorHorizontal) }
                        editButton("垂直", "arrow.up.and.down.righttriangle.up.righttriangle.down") { model.apply(.mirrorVertical) }
                    }
                }
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 12) {
                    caption("图片信息")
                    Text(model.dimensions + " px").font(.system(size: 13, design: .monospaced))
                    Text(model.fileURL?.pathExtension.uppercased() ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Label("原图始终保留", systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 200)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .disabled(model.busy)
    }

    private func caption(_ text: String) -> some View { Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
    private func editButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) { Image(systemName: symbol).font(.system(size: 18, weight: .light)); Text(title).font(.system(size: 11)) }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }.buttonStyle(.glass)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Button { model.navigate(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.busy || model.cropping || (model.currentIndex ?? 0) <= 0)
                Text(model.currentIndex.map { "\($0 + 1) / \(model.browsingFiles.count)" } ?? "0 / 0").font(.system(size: 11, design: .monospaced)).frame(minWidth: 46)
                Button { model.navigate(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.busy || model.cropping || (model.currentIndex ?? -1) >= model.browsingFiles.count - 1)
            }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 12).glassEffect()
            Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if model.image != nil {
                HStack(spacing: 18) {
                    Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canEdit || !model.history.canUndo).help("撤销 ⌘Z")
                    Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canEdit || !model.history.canRedo).help("重做 ⇧⌘Z")
                    Divider().frame(height: 16)
                    Button { model.zoom = max(0.1, model.zoom / 1.25) } label: { Image(systemName: "minus") }.disabled(model.cropping)
                    Button(action: model.resetZoom) { Text(model.actualSize ? "\(Int(model.zoom * 100))%" : "适应 \(Int(model.zoom * 100))%").font(.system(size: 11, design: .monospaced)) }.help("点击适应窗口 ⌘0")
                    Button { model.zoom = min(8, model.zoom * 1.25) } label: { Image(systemName: "plus") }.disabled(model.cropping)
                }.buttonStyle(.plain).padding(.horizontal, 18).padding(.vertical, 12).glassEffect()
            }
        }
    }
}

struct ImageCanvas: View {
    @ObservedObject var model: EditorModel
    let image: CGImage
    @State private var start: CGPoint?
    @State private var gestureZoom: Double?

    var body: some View {
        GeometryReader { geometry in
            let available = CGSize(width: max(1, geometry.size.width - 56), height: max(1, geometry.size.height - 56))
            let fit = min(available.width / Double(image.width), available.height / Double(image.height))
            let base = model.actualSize ? 1 / (NSScreen.main?.backingScaleFactor ?? 2) : fit
            let scale = base * model.zoom
            let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    checkerboard(size: size)
                    if model.mediaInfo?.animation != nil {
                        AnimatedFrameView(playback: model.playback, poster: image).frame(width: size.width, height: size.height)
                    } else {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                    }
                    if model.cropping { cropOverlay(size: size, scale: scale) }
                }
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.3), radius: 22, y: 10)
                .padding(28)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                guard !model.cropping else { return }
                if gestureZoom == nil { gestureZoom = model.zoom }
                model.zoom = min(8, max(0.1, (gestureZoom ?? 1) * value.magnification))
            }.onEnded { _ in gestureZoom = nil })
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

    private func cropOverlay(size: CGSize, scale: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, area in
                var mask = Path(CGRect(origin: .zero, size: area))
                if let rect = model.cropRect { mask.addRect(CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)) }
                context.fill(mask, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
            }
            if let rect = model.cropRect {
                let display = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                Rectangle().stroke(.white, lineWidth: 1.5).frame(width: display.width, height: display.height).offset(x: display.minX, y: display.minY)
                Path { path in
                    for fraction in [1.0 / 3, 2.0 / 3] {
                        path.move(to: CGPoint(x: display.minX + display.width * fraction, y: display.minY)); path.addLine(to: CGPoint(x: display.minX + display.width * fraction, y: display.maxY))
                        path.move(to: CGPoint(x: display.minX, y: display.minY + display.height * fraction)); path.addLine(to: CGPoint(x: display.maxX, y: display.minY + display.height * fraction))
                    }
                }.stroke(.white.opacity(0.35), lineWidth: 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let point = CGPoint(x: min(size.width, max(0, value.location.x)), y: min(size.height, max(0, value.location.y)))
            if start == nil { start = CGPoint(x: min(size.width, max(0, value.startLocation.x)), y: min(size.height, max(0, value.startLocation.y))) }
            if let start {
                let rect = CGRect(x: floor(min(start.x, point.x) / scale), y: floor(min(start.y, point.y) / scale), width: floor(abs(point.x - start.x) / scale), height: floor(abs(point.y - start.y) / scale))
                model.cropRect = rect.width >= 1 && rect.height >= 1 ? rect : nil
            }
        }.onEnded { _ in start = nil })
    }
}

struct AnimatedFrameView: View {
    @ObservedObject var playback: ImagePlayback
    let poster: CGImage
    var body: some View {
        Image(decorative: playback.frame ?? poster, scale: 1).resizable().interpolation(.high)
    }
}

struct ReadOnlyInspector: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var playback: ImagePlayback
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(model.mediaInfo?.animation == nil ? "只读图片" : "动图播放", systemImage: "play.rectangle")
                .font(.system(size: 14, weight: .semibold))
            Text("此图片仅供查看，编辑和导出已禁用。").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(model.dimensions + " px").font(.system(size: 13, design: .monospaced))
            if let animation = model.mediaInfo?.animation {
                Text("\(animation.format.rawValue) · \(animation.frameCount) 帧").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("按原始帧时长循环播放").font(.system(size: 11)).foregroundStyle(.secondary)
                Button(action: playback.toggle) {
                    Label(playback.isPlaying ? "暂停" : "播放", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                }.buttonStyle(.glass)
                Button("从头播放", action: playback.restart).buttonStyle(.glass)
                Text("第 \(playback.frameIndex + 1) / \(animation.frameCount) 帧")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                if let error = playback.error { Text(error).font(.caption).foregroundStyle(.red) }
            } else { Text("GIF · 静态单帧").font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Label("只读 · 原图保留", systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 200)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .disabled(model.busy)
    }
}

struct ExportView: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Image(systemName: "square.and.arrow.up").foregroundStyle(accent); Text("导出图片").font(.title2.weight(.medium)) }
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
