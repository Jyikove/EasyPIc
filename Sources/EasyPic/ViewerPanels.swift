import SwiftUI
import AppKit
import EasyPicCore

enum ViewerPanel { case thumbnails, text, edit }

extension EditorModel {
    var viewerControlsEnabled: Bool { sidePanel != .edit && canBrowse }
    var canSwitchPanel: Bool { viewerControlsEnabled && !brushMode }
    var canNavigatePrevious: Bool { viewerControlsEnabled && (currentIndex ?? 0) > 0 }
    var canNavigateNext: Bool {
        viewerControlsEnabled && currentIndex.map { $0 + 1 < browsingFiles.count } == true
    }

    func togglePanel(_ panel: ViewerPanel) {
        if panel == .edit { toggleEditor(); return }
        guard canSwitchPanel else { return }
        finishInlineText { [weak self] in
            guard let self else { return }
            self.cancelBrush(); self.activeEditorTool = nil
            self.sidePanel = self.sidePanel == panel ? nil : panel
            if self.sidePanel == .text { self.recognizeText() }
            else { self.clearRecognition() }
        }
    }

    func clearRecognition() {
        recognitionTask?.cancel(); recognitionTask = nil; recognitionID = UUID()
        recognitionSource = nil; recognizedText = ""; recognizingText = false; recognitionError = nil
    }

    func recognizeText() {
        let displayed = livePhoto != nil || isReadOnly ? image : (documentPreview ?? image)
        guard sidePanel == .text, !busy, let source = displayed else { return }
        guard recognitionSource !== source else { return }
        clearRecognition()
        recognitionSource = source
        let id = recognitionID
        recognizingText = true
        let snapshot = livePhoto == nil && !isReadOnly ? document : nil
        let assets = resources
        recognitionTask = Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    let fullSize = try snapshot.map { try DocumentEngine.render($0, resources: assets) } ?? source
                    return try ViewerTools.recognizeText(in: fullSize)
                }.value
                guard !Task.isCancelled, recognitionID == id else { return }
                recognizedText = text; recognizingText = false
            } catch {
                guard !Task.isCancelled, recognitionID == id else { return }
                recognitionError = L10n.text("无法识别文字：") + error.localizedDescription
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
        let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(url.path):\(attributes?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(attributes?.fileSize ?? 0)" as NSString
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
                ScrollView {
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
    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("提取文本")).font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.recognizedText, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .quickHelp(L10n.text("复制全部文本")).accessibilityLabel(L10n.text("复制全部文本"))
                .buttonStyle(GlassButtonStyle()).disabled(model.recognizedText.isEmpty || model.recognizingText || model.busy)
            }
            if model.recognizingText || model.busy {
                HStack { ProgressView().controlSize(.small); Text(L10n.text("正在识别…")).foregroundStyle(.secondary) }
            } else if let error = model.recognitionError {
                Text(L10n.display(error)).font(.callout).foregroundStyle(.secondary)
                Button(L10n.text("重试")) { model.clearRecognition(); model.recognizeText() }.buttonStyle(GlassButtonStyle())
            } else if model.recognizedText.isEmpty {
                Text(L10n.text("未识别到文字")).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(model.recognizedText).font(.system(size: 14)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(18).frame(width: 300).frame(maxHeight: .infinity, alignment: .topLeading)
        .glassSurface(.panel, radius: 20)
    }
}
