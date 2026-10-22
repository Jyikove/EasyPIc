import SwiftUI
import AppKit
import EasyPicCore

enum ViewerPanel { case thumbnails, text, qr, edit }
enum RecognitionPresentation { case all, separate }

extension EditorModel {
    var viewerControlsEnabled: Bool { sidePanel != .edit && canBrowse }
    var canSwitchPanel: Bool { viewerControlsEnabled && !brushMode }
    var canNavigatePrevious: Bool { viewerControlsEnabled && (currentIndex ?? 0) > 0 }
    var canNavigateNext: Bool {
        viewerControlsEnabled && currentIndex.map { $0 + 1 < browsingFiles.count } == true
    }

    var isRecognitionPanel: Bool { sidePanel == .text || sidePanel == .qr }
    var hasRecognitionSelection: Bool { sidePanel == .text }

    func togglePanel(_ panel: ViewerPanel) {
        if panel == .edit { toggleEditor(); return }
        guard canSwitchPanel else { return }
        finishInlineText { [weak self] in
            guard let self else { return }
            self.cancelBrush(); self.activeEditorTool = nil
            self.clearRecognition()
            self.sidePanel = self.sidePanel == panel ? nil : panel
            self.recognitionRegion = self.sidePanel == .text ? CGRect(x: 0, y: 0, width: 1, height: 1) : nil
            if self.sidePanel == .text {
                self.recognitionPresentation = .all
                self.resetZoom()
            }
            self.recognizeText()
        }
    }

    func clearRecognition() {
        recognitionTask?.cancel(); recognitionTask = nil; recognitionID = UUID()
        recognitionSource = nil; recognizedText = ""; recognizingText = false; recognitionError = nil
        recognitionResult = ImageRecognitionResult(); recognitionScrollTarget = nil; highlightedRecognitionID = nil
    }

    func recognizeRegion(_ region: CGRect?) {
        clearRecognition()
        recognitionRegion = sidePanel == .text ? (region ?? CGRect(x: 0, y: 0, width: 1, height: 1)) : nil
        recognizeText()
    }

    func recognizeText() {
        let displayed = livePhoto != nil || isReadOnly ? image : (documentPreview ?? image)
        guard isRecognitionPanel, !busy, let source = displayed else { return }
        guard recognitionSource !== source else { return }
        clearRecognition()
        let textMode = sidePanel == .text
        if textMode && recognitionRegion == nil { recognitionRegion = CGRect(x: 0, y: 0, width: 1, height: 1) }
        recognitionSource = source
        let id = recognitionID
        recognizingText = true
        let edits = liveHistory.edits
        let liveKey = livePhoto == nil ? "" : "\(edits.crop):\(String(describing: edits.coverTime))"
        let region = textMode ? recognitionRegion : nil
        let key = contentID.uuidString + ":" + (document?.contentKey ?? "poster") + liveKey + String(describing: region) + (textMode ? ":text" : ":qr")
        if let cached = recognitionCache[key] {
            recognitionResult = cached; recognizedText = cached.text; recognizingText = false; return
        }
        let cancellation = RecognitionCancellation()
        let trace = InteractionMetrics.shared.begin(textMode ? "TextRecognition" : "QRRecognition")
        recognitionTask = Task {
            do {
                let work = Task.detached(priority: .userInitiated) {
                    InteractionMetrics.shared.mark(trace, "VisionBegin")
                    let result = try ViewerTools.recognize(in: source, region: region, detectText: textMode,
                                                           detectQRCodes: !textMode, cancellation: cancellation.install)
                    InteractionMetrics.shared.mark(trace, "VisionReady")
                    return result
                }
                let result = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel(); cancellation.cancel()
                }
                guard !Task.isCancelled, recognitionID == id else { return }
                recognitionCache[key] = result
                recognitionCacheOrder.removeAll { $0 == key }; recognitionCacheOrder.append(key)
                while recognitionCacheOrder.count > 8 { recognitionCache.removeValue(forKey: recognitionCacheOrder.removeFirst()) }
                recognitionResult = result; recognizedText = result.text; recognizingText = false
                visualTraceID = trace; InteractionMetrics.shared.mark(trace, "RecognitionPublished")
            } catch {
                guard !Task.isCancelled, recognitionID == id else { return }
                recognitionError = L10n.text(textMode ? "无法识别文字：" : "无法识别二维码：") + error.localizedDescription
                recognizingText = false
            }
        }
    }
}

private actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, ThumbnailBox>()
    init() { cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 256 }
    func image(for url: URL) throws -> CGImage {
        try Task.checkCancellation()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.path):\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attributes?[.size] ?? 0):\(attributes?[.systemFileNumber] ?? 0)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        let image = try ViewerTools.thumbnail(url)
        try Task.checkCancellation()
        cache.setObject(ThumbnailBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
private final class ThumbnailBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

struct FolderPreviewPanel: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    var body: some View {
        let _ = languageSettings.language
        VStack(spacing: 12) {
            HStack { Text(L10n.text("预览")).font(.headline); Spacer() }
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(model.browsingFiles, id: \.self) { url in
                            Button { model.open(url) } label: {
                                FolderThumbnail(url: url, selected: model.fileURL == url)
                            }
                            .buttonStyle(GlassButtonStyle(selected: model.fileURL == url, radius: 10,
                                                        horizontalPadding: 0, verticalPadding: 0))
                            .accessibilityAddTraits(model.fileURL == url ? .isSelected : []).disabled(!model.canBrowse)
                            .quickHelp(url.lastPathComponent).accessibilityLabel(L10n.text("查看 ") + url.lastPathComponent)
                            .id(url)
                        }
                    }
                }
                .onAppear { if let url = model.fileURL { proxy.scrollTo(url, anchor: .center) } }
                .onChange(of: model.fileURL) { _, url in
                    if let url { withAnimation { proxy.scrollTo(url, anchor: .center) } }
                }
                .onChange(of: model.browsingFiles) { _, _ in
                    if let url = model.fileURL { proxy.scrollTo(url, anchor: .center) }
                }
            }
        }
        .padding(16).frame(width: 264)
        .glassSurface(.panel, radius: 20)
    }
}

private struct FolderThumbnail: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    let url: URL
    let selected: Bool
    @State private var image: CGImage?
    @State private var failed = false
    var body: some View {
        let _ = languageSettings.language
        ZStack {
            Color.clear
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding(5)
            } else if failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            do {
                let thumbnail = try await ThumbnailCache.shared.image(for: url)
                guard !Task.isCancelled else { return }; image = thumbnail
            } catch is CancellationError { }
            catch { guard !Task.isCancelled else { return }; failed = true }
        }
    }
}

struct TextRecognitionPanel: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    private var textMode: Bool { model.sidePanel == .text }
    private var copyText: String {
        if !textMode { return model.recognitionResult.codes.map(\.payload).joined(separator: "\n") }
        return model.recognitionPresentation == .all ? model.recognitionResult.flowingText : model.recognizedText
    }
    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .leading, spacing: 12) {
            if textMode {
                GlassSlidingPicker(selection: $model.recognitionPresentation,
                                   options: [(L10n.text("全部"), .all), (L10n.text("分条"), .separate)])
                    .accessibilityLabel(L10n.text("文字显示方式"))
            }
            HStack {
                if !textMode { Text(L10n.text("二维码")).font(.headline) }
                Spacer()
                ClipboardCopyButton(text: copyText, title: L10n.text("复制全部文本"))
                    .disabled(model.recognizingText || copyText.isEmpty)
            }
            if model.recognizingText || model.busy {
                HStack { ProgressView().controlSize(.small); Text(L10n.text("正在识别…")).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            } else if let error = model.recognitionError {
                Text(L10n.display(error)).font(.callout).foregroundStyle(.secondary)
                Button(L10n.text("重试")) { model.clearRecognition(); model.recognizeText() }
                Spacer(minLength: 0)
            } else if textMode && model.recognitionResult.lines.isEmpty {
                Text(L10n.text("未识别到文字")).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if textMode && model.recognitionPresentation == .all {
                RecognizedTextView(text: model.recognitionResult.flowingText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            if textMode {
                                if model.recognitionResult.lines.isEmpty { Text(L10n.text("未识别到文字")).foregroundStyle(.secondary) }
                                ForEach(model.recognitionResult.lines) { line in resultRow(line.text, id: line.id) }
                            } else {
                                if model.recognitionResult.codes.isEmpty { Text(L10n.text("未识别到二维码")).foregroundStyle(.secondary) }
                                ForEach(model.recognitionResult.codes) { code in
                                    VStack(alignment: .leading, spacing: 6) {
                                        resultRow(code.payload, id: code.id)
                                        if let url = URL(string: code.payload), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                            Button(L10n.text("打开链接")) { NSWorkspace.shared.open(url) }
                                        }
                                    }.id(code.id)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.recognitionScrollTarget) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .buttonStyle(GlassButtonStyle()).font(.system(size: 12))
        .padding(16).frame(width: 300).frame(maxHeight: .infinity, alignment: .topLeading)
        .glassSurface(.panel, radius: 20)
    }
    private func resultRow(_ text: String, id: UUID) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            ClipboardCopyButton(text: text, title: L10n.text("复制")) { model.highlightedRecognitionID = id }
        }
        .padding(8).glassSurface(.input, radius: 8, selected: model.highlightedRecognitionID == id)
        .contentShape(Rectangle()).onTapGesture { model.highlightedRecognitionID = id }
        .onHover { if $0 { model.highlightedRecognitionID = id } }
        .id(id)
    }
}

private struct RecognizedTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let view = NSTextView(frame: scroll.contentView.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 4)
        view.font = .systemFont(ofSize: 14)
        view.textColor = .labelColor
        view.allowsUndo = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineBreakMode = .byWordWrapping
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        view.defaultParagraphStyle = paragraph
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            view.string = text
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        view.setAccessibilityLabel(L10n.text("提取文本"))
    }
}

/// Covers cancellation both before and after Vision creates its request.
private final class RecognitionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var cancelled = false
    func install(_ action: @escaping () -> Void) {
        lock.lock(); self.action = action; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { action() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let action = action; lock.unlock()
        action?()
    }
}
