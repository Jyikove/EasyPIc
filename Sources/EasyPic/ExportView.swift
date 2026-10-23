import SwiftUI
import AppKit
import EasyPicCore

/// Keeps a stable sheet size when switching format; the quality row remains reserved.
struct ExportView: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    @State private var filename = ""
    @State private var directory: URL?
    @State private var pendingReplacement: URL?
    @State private var encodedBytes: Int?
    @State private var measuredSettings: MeasurementSettings?
    @State private var measurementError: String?
    private var blocked: Bool { model.busy || model.choosingExportLocation }
    private struct MeasurementSettings: Hashable {
        let format: String
        let quality: Double
        let scale: Double
    }
    private var measurementSettings: MeasurementSettings {
        MeasurementSettings(format: model.exportFormat.rawValue, quality: model.jpegQuality, scale: model.exportScale)
    }
    private var outputDimensions: String {
        guard let source = model.documentPreview ?? model.image else { return "—" }
        let size = ImageCompression.dimensions(source, scale: model.exportScale)
        return "\(Int(size.width)) × \(Int(size.height)) px"
    }

    var body: some View {
        let _ = languageSettings.language
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.text("另存为"), functionIcon: "square.and.arrow.down.on.square")
                .font(.title2.weight(.medium))
            HStack {
                Text(L10n.text("格式"))
                Spacer()
                GlassSlidingPicker(selection: $model.exportFormat, options: [("PNG", .png), ("JPG", .jpg)])
                    .frame(width: 200).accessibilityLabel(L10n.text("格式"))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("文件名"))
                HStack(spacing: 6) {
                    TextField(L10n.text("文件名"), text: $filename).textFieldStyle(.plain)
                    Text("." + model.exportFormat.rawValue).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).frame(height: 34).glassSurface(.input, radius: 10)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("位置"))
                HStack(spacing: 6) {
                    ExportPathBar(url: directory).frame(maxWidth: .infinity).frame(height: 30)
                        .padding(.leading, 6).glassSurface(.input, radius: 10)
                    Button(action: chooseDirectory) {
                        FunctionIcon(systemName: "folder.badge.gearshape").frame(width: 30, height: 30)
                    }
                    .buttonStyle(GlassButtonStyle(radius: 10, horizontalPadding: 0, verticalPadding: 0))
                    .quickHelp(L10n.text("选择文件夹…")).accessibilityLabel(L10n.text("选择文件夹…"))
                }
            }
            VStack(spacing: 6) {
                HStack { Text(L10n.text("分辨率")); Spacer(); Text("\(Int((model.exportScale * 100).rounded()))%").monospacedDigit() }
                GlassSlider(value: Binding(get: { model.exportScale }, set: { model.exportScale = ($0 * 100).rounded() / 100 }), in: 0.01...1)
            }
            HStack { Text(L10n.text("尺寸")); Spacer(); Text(outputDimensions).monospaced() }
            VStack(spacing: 6) {
                HStack { Text(L10n.text("质量")); Spacer(); Text("\(Int(model.jpegQuality * 100))%").monospaced() }
                GlassSlider(value: $model.jpegQuality, in: 0.1...1)
            }
            .frame(height: 48).opacity(model.exportFormat == .jpg ? 1 : 0)
            .allowsHitTesting(model.exportFormat == .jpg).accessibilityHidden(model.exportFormat != .jpg)
            HStack {
                Text(L10n.text("预计大小")); Spacer()
                if measuredSettings == measurementSettings, let bytes = encodedBytes {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                        .monospacedDigit().help("\(bytes) bytes")
                } else if let measurementError {
                    Text("—").help(measurementError)
                } else { ProgressView().controlSize(.small) }
            }.frame(height: 20)
            Text(model.error.map(L10n.display) ?? " ")
                .font(.caption).foregroundStyle(.red).lineLimit(2).frame(height: 30, alignment: .topLeading)
            HStack {
                Button(L10n.text("取消")) { model.error = nil; model.cancelExport() }
                    .keyboardShortcut(.cancelAction).buttonStyle(GlassButtonStyle())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(L10n.text("保存"), action: save)
                    .keyboardShortcut(.defaultAction).buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || directory == nil)
            }
        }
        .font(.system(size: 13)).padding(24).frame(width: 424)
        .disabled(blocked || pendingReplacement != nil)
        .glassSurface(.floating, radius: 24, backgroundOpacity: 0.88).glassWindowBackground().presentationBackground(.clear)
        .overlay {
            if let url = pendingReplacement {
                ZStack {
                    Color.black.opacity(0.25).clipShape(RoundedRectangle(cornerRadius: 24))
                    GlassDialog(title: L10n.text("替换文件？"), message: L10n.text("“{0}”已存在，是否替换？", url.lastPathComponent)) {
                        HStack {
                            Button(L10n.text("取消")) { pendingReplacement = nil }.keyboardShortcut(.cancelAction)
                            Button(L10n.text("替换")) { pendingReplacement = nil; write(to: url) }.keyboardShortcut(.defaultAction)
                        }.buttonStyle(GlassButtonStyle())
                    }
                }
            }
        }
        .glassEntrance().preferredColorScheme(.dark).tint(EasyPicGlass.accent)
        .interactiveDismissDisabled()
        .onAppear {
            directory = model.fileURL?.deletingLastPathComponent()
            filename = (model.fileURL?.deletingPathExtension().lastPathComponent ?? "Image") + "-edited"
        }
        .task(id: measurementSettings) { await measureOutput() }
    }

    private func measureOutput() async {
        let settings = measurementSettings, format = model.exportFormat
        measurementError = nil
        guard let source = model.documentPreview ?? model.image else { return }
        do {
            // Avoid repeatedly encoding full images while the user drags a slider.
            try await Task.sleep(for: .milliseconds(180))
            let worker = Task.detached(priority: .utility) {
                try ImageCompression.encode(source, format: format, quality: settings.quality, scale: settings.scale).count
            }
            let bytes = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            encodedBytes = bytes; measuredSettings = settings
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            encodedBytes = nil; measuredSettings = settings; measurementError = error.localizedDescription
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel(); EasyPicGlass.prepareFilePanel(panel)
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = directory
        panel.prompt = L10n.text("选择")
        model.choosingExportLocation = true
        panel.begin { response in
            model.choosingExportLocation = false
            if response == .OK { directory = panel.url }
        }
    }
    private func save() {
        guard let source = model.fileURL, let directory else { return }
        model.error = nil
        do {
            let url = try ExportDestination.make(filename: filename, format: model.exportFormat, directory: directory, source: source)
            if FileManager.default.fileExists(atPath: url.path) { pendingReplacement = url }
            else { write(to: url) }
        } catch { model.error = error.localizedDescription }
    }
    private func write(to url: URL) {
        guard let image = model.image, let source = model.fileURL else { return }
        model.writeExport(image, source: source, destination: url)
    }
}

enum ExportDestination {
    static func make(filename: String, format: ExportFormat, directory: URL, source: URL) throws -> URL {
        var name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw ExportNameError.invalid
        }
        // Accept a pasted filename with an image extension without producing doubled suffixes.
        if ["png", "jpg", "jpeg"].contains((name as NSString).pathExtension.lowercased()) {
            name = (name as NSString).deletingPathExtension
        }
        guard !name.isEmpty, name != ".", name != ".." else { throw ExportNameError.invalid }
        let url = directory.appendingPathComponent(name).appendingPathExtension(format.rawValue)
        guard url.resolvingSymlinksInPath().standardizedFileURL != source.resolvingSymlinksInPath().standardizedFileURL else {
            throw ExportNameError.original
        }
        return url
    }
    private enum ExportNameError: LocalizedError {
        case invalid, original
        var errorDescription: String? {
            switch self {
            case .invalid: L10n.text("请输入有效的文件名，不能包含斜线。")
            case .original: L10n.text("请使用新的文件名导出，以保留原图。")
            }
        }
    }
}

private struct ExportPathBar: NSViewRepresentable {
    let url: URL?
    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard; control.isEditable = false; control.backgroundColor = .clear
        control.controlSize = .small
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }
    func updateNSView(_ control: NSPathControl, context: Context) {
        control.url = url; control.toolTip = url?.path
    }
}
