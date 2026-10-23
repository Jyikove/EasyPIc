import SwiftUI
import EasyPicCore

extension EditorModel {
    var currentAdjustments: PhotoAdjustments { adjustmentDraft ?? document?.adjustments ?? PhotoAdjustments() }
    var hasAdjustmentDraftChanges: Bool {
        guard let adjustmentDraft else { return false }
        return adjustmentDraft != (document?.adjustments ?? PhotoAdjustments())
    }
    func setAdjustment(_ key: WritableKeyPath<PhotoAdjustments, Double>, value: Double) {
        guard canPerformEditorActions, activeEditorTool == .adjust, value.isFinite, let document else { return }
        var next = currentAdjustments
        next[keyPath: key] = value
        guard next.isValid, next != currentAdjustments else { return }
        adjustmentDraft = next
        adjustmentCommitTask?.cancel()
        if !adjustmentDragging { scheduleAdjustmentCommit() }
        guard adjustmentPreviewTask == nil else { return }
        let revision = adjustmentRevision, assets = resources
        adjustmentPreviewTask = Task { [weak self] in
            guard let self else { return }
            var rendered: PhotoAdjustments?
            do {
                // Consume the latest state at display cadence, with only one GPU job in flight.
                while !Task.isCancelled, self.adjustmentRevision == revision,
                      let settings = self.adjustmentDraft, rendered != settings {
                    try await Task.sleep(for: .milliseconds(16))
                    let latest = self.currentAdjustments
                    let image = try await self.adjustmentPreviewService.render(document, resources: assets, settings: latest)
                    try Task.checkCancellation()
                    guard self.adjustmentRevision == revision else { return }
                    self.adjustmentPreviewBase = image
                    rendered = latest
                }
            } catch is CancellationError { }
            catch {
                guard self.adjustmentRevision == revision else { return }
                self.error = error.localizedDescription
            }
            if self.adjustmentRevision == revision { self.adjustmentPreviewTask = nil }
        }
    }
    func adjustmentEditingChanged(_ editing: Bool) {
        adjustmentDragging = editing
        adjustmentCommitTask?.cancel()
        if !editing { finishAdjustments() }
    }
    private func scheduleAdjustmentCommit() {
        adjustmentCommitTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !self.adjustmentDragging, self.canPerformEditorActions else { return }
            self.finishAdjustments()
        }
    }
    func finishAdjustments(then action: (() -> Void)? = nil) {
        adjustmentCommitTask?.cancel(); adjustmentCommitTask = nil
        guard hasAdjustmentDraftChanges, let settings = adjustmentDraft, var doc = document else {
            clearAdjustmentDraft(); action?(); return
        }
        adjustmentPreviewTask?.cancel(); adjustmentPreviewTask = nil
        adjustmentRevision = UUID(); adjustmentDragging = false
        doc.adjustments = settings.isNeutral ? nil : settings
        pendingEditorAction = action
        commitDocument(doc)
    }
    func clearAdjustmentDraft() {
        adjustmentPreviewTask?.cancel(); adjustmentPreviewTask = nil
        adjustmentCommitTask?.cancel(); adjustmentCommitTask = nil
        adjustmentRevision = UUID(); adjustmentDragging = false
        adjustmentDraft = nil; adjustmentPreviewBase = nil
    }
    func resetAdjustments() {
        guard canPerformEditorActions, var doc = document else { return }
        clearAdjustmentDraft()
        guard doc.adjustments != nil else { return }
        doc.adjustments = nil
        commitDocument(doc)
    }
}

struct AdjustmentToolControls: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    private struct Control: Identifiable {
        let title: String
        let key: WritableKeyPath<PhotoAdjustments, Double>
        var range: ClosedRange<Double> = -100...100
        var step: Double = 1
        var trackColors: [Color] = []
        var id: String { title }
    }
    private let controls = [
        Control(title: "曝光", key: \.exposure, range: -3...3, step: 0.1),
        Control(title: "亮度", key: \.brightness),
        Control(title: "对比度", key: \.contrast),
        Control(title: "饱和度", key: \.saturation),
        Control(title: "高光", key: \.highlights),
        Control(title: "阴影", key: \.shadows),
        Control(title: "色温", key: \.temperature, trackColors: [
            Color(red: 0.39, green: 0.66, blue: 0.94),
            Color(red: 0.78, green: 0.79, blue: 0.79),
            Color(red: 0.97, green: 0.75, blue: 0.36)
        ]),
        Control(title: "色调", key: \.tint, trackColors: [
            Color(red: 0.50, green: 0.78, blue: 0.56),
            Color(red: 0.71, green: 0.70, blue: 0.63),
            Color(red: 0.81, green: 0.44, blue: 0.59)
        ]),
        Control(title: "锐化", key: \.sharpen, range: 0...100)
    ]
    var body: some View {
        let _ = languageSettings.language
        VStack(spacing: 12) {
            ForEach(controls) { control in
                let value = Binding<Double>(get: { model.currentAdjustments[keyPath: control.key] }, set: {
                    let rounded = ($0 / control.step).rounded() * control.step
                    model.setAdjustment(control.key, value: min(control.range.upperBound, max(control.range.lowerBound, rounded)))
                })
                VStack(spacing: 2) {
                    NumericValueControl(title: L10n.text(control.title), value: value, range: control.range, step: control.step)
                    GlassSlider(value: value, in: control.range, trackColors: control.trackColors, thumbStyle: .whiteBar,
                                onEditingChanged: model.adjustmentEditingChanged)
                        .accessibilityLabel(L10n.text(control.title))
                }
            }
            Button(action: model.resetAdjustments) {
                Text(L10n.text("重置调整")).frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(model.currentAdjustments.isNeutral)
        }
        .frame(width: 240)
    }
}
