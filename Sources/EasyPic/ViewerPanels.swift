import SwiftUI
import AppKit
import EasyPicCore

enum ViewerPanel { case thumbnails, text, edit }

extension EditorModel {
    var canSwitchPanel: Bool { canBrowse && !brushMode }
    var canNavigatePrevious: Bool { canBrowse && (currentIndex ?? 0) > 0 }
    var canNavigateNext: Bool {
        canBrowse && currentIndex.map { $0 + 1 < browsingFiles.count } == true
    }

    func togglePanel(_ panel: ViewerPanel) {
        guard canBrowse else { return }
        if brushMode { cancelBrush() }
        sidePanel = sidePanel == panel ? nil : panel
        if sidePanel == .text { recognizeText() }
        else { clearRecognition() }
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
                recognitionError = "无法识别文字：" + error.localizedDescription
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
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("预览").font(.headline); Spacer() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(model.browsingFiles, id: \.self) { url in
                            Button { model.open(url) } label: {
                                FolderThumbnail(url: url, selected: model.fileURL == url)
                            }
                            .buttonStyle(.plain).disabled(!model.canBrowse)
                            .help(url.lastPathComponent).accessibilityLabel("查看 " + url.lastPathComponent)
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct FolderThumbnail: View {
    let url: URL
    let selected: Bool
    @State private var image: CGImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.16))
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding(5)
            } else if failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
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
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("提取文本").font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.recognizedText, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .help("复制全部文本").accessibilityLabel("复制全部文本")
                .buttonStyle(.glass).disabled(model.recognizedText.isEmpty || model.recognizingText || model.busy)
            }
            if model.recognizingText || model.busy {
                HStack { ProgressView().controlSize(.small); Text("正在识别…").foregroundStyle(.secondary) }
            } else if let error = model.recognitionError {
                Text(error).font(.callout).foregroundStyle(.secondary)
                Button("重试") { model.clearRecognition(); model.recognizeText() }.buttonStyle(.glass)
            } else if model.recognizedText.isEmpty {
                Text("未识别到文字").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(model.recognizedText).font(.system(size: 14)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(18).frame(width: 300).frame(maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}
