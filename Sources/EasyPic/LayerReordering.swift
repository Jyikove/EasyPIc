import SwiftUI
import AppKit
import EasyPicCore
import UniformTypeIdentifiers

extension EditorModel {
    private func reorderedDocument(_ id: UUID, order: [UUID], filter: LayerInspectorFilter) -> EditorDocument? {
        guard sidePanel == .edit, var next = document else { return nil }
        guard (filter == .sticker && activeEditorTool == .sticker) ||
              (filter == .text && activeEditorTool == .text) ||
              (filter == .brush && activeEditorTool == .solid) else { return nil }
        let current = listedLayers(matching: filter, includingReorderPreview: false).map(\.id)
        guard order.count == current.count, Set(order).count == order.count, Set(order) == Set(current),
              let source = current.firstIndex(of: id), let destination = order.firstIndex(of: id), source != destination else { return nil }
        if let draft = draftLayer {
            if let index = next.layers.firstIndex(where: { $0.id == draft.id }) { next.layers[index] = draft }
            else if order.contains(draft.id), draft.text?.isValid == true { next.layers.append(draft) }
        }
        let movingUp = destination < source
        let target = order[destination + (movingUp ? 1 : -1)]
        guard next.moveLayer(id, relativeTo: target, above: movingUp) else { return nil }
        return next
    }
    func previewLayerReorder(_ id: UUID, order: [UUID], filter: LayerInspectorFilter) {
        layerReorderPreview = reorderedDocument(id, order: order, filter: filter)
    }
    func commitLayerReorder(_ id: UUID, order: [UUID], filter: LayerInspectorFilter) -> Bool {
        guard canPerformEditorActions, let next = reorderedDocument(id, order: order, filter: filter) else { return false }
        let textDraft = textEditing ? draftLayer : nil
        historyPresentation = EditorHistoryPresentation(textLayer: textDraft, cropRect: nil)
        layerReorderPreview = next
        pendingEditorAction = { [weak self] in
            guard let self else { return }
            if let textDraft {
                self.draftLayer = self.document?.layers.first(where: { $0.id == textDraft.id }) ?? textDraft
                self.selectedLayerID = textDraft.id; self.textEditing = true
            }
            self.layerReorderPreview = nil; self.historyPresentation = nil
        }
        commitDocument(next)
        return true
    }
}

/// Native drag images follow the pointer; only row crossings publish a new order.
/// Full-resolution composition runs once at drop, and cancellation restores the preview.
@MainActor final class LayerListDragState: ObservableObject {
    // SwiftUI resolves accepted identifiers to UTType when installing the drop
    // destination. An undeclared string leaves a visible drag with no valid target.
    static let contentType = UTType(exportedAs: "local.jyikove.easypic.layer-order", conformingTo: .data)
    static let typeIdentifier = contentType.identifier
    static func itemProvider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
    @Published private(set) var layerID: UUID?
    var visibleIDs = Set<UUID>()
    private var order: [UUID] = []
    private var filter: LayerInspectorFilter = .all
    private weak var model: EditorModel?
    private var timer: Timer?
    private var releasedAt: TimeInterval?
    private var edge: (id: UUID, direction: Int)?
    private var lastScroll: TimeInterval = 0
    private var scroll: ((UUID, UnitPoint) -> Void)?
    deinit { timer?.invalidate() }
    func begin(_ id: UUID, model: EditorModel, filter: LayerInspectorFilter, scroll: @escaping (UUID, UnitPoint) -> Void) {
        cancel()
        guard model.canPerformEditorActions else { return }
        self.model = model; self.filter = filter; self.scroll = scroll
        order = model.listedLayers(matching: filter, includingReorderPreview: false).map(\.id)
        guard order.contains(id) else { cancel(); return }
        layerID = id
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func entered(_ target: UUID) {
        guard let id = layerID, id != target, let source = order.firstIndex(of: id),
              let destination = order.firstIndex(of: target) else { return }
        order.remove(at: source); order.insert(id, at: destination)
        withAnimation(animation) { model?.previewLayerReorder(id, order: order, filter: filter) }
    }
    func updated(_ target: UUID, y: CGFloat) {
        edge = y < 6 ? (target, -1) : (y > 22 ? (target, 1) : nil)
    }
    func exited(_ target: UUID) { if edge?.id == target { edge = nil } }
    func drop() -> Bool {
        guard let id = layerID, let model else { cancel(); return false }
        let committed = model.commitLayerReorder(id, order: order, filter: filter)
        finish(keepingPreview: committed)
        return true
    }
    func cancel() { finish(keepingPreview: false) }
    private var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.88)
    }
    private func finish(keepingPreview: Bool) {
        timer?.invalidate(); timer = nil
        if !keepingPreview, layerID != nil { withAnimation(animation) { model?.layerReorderPreview = nil } }
        layerID = nil; order = []; releasedAt = nil; edge = nil; scroll = nil; model = nil
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        // AppKit's cached button flags can change during native drag tracking.
        let mouseDown = CGEventSource.buttonState(.combinedSessionState, button: .left) || NSEvent.pressedMouseButtons & 1 != 0
        if !mouseDown {
            // Native drag/drop completes asynchronously after mouse-up. Give the
            // destination time to accept it before treating it as an outside drop.
            if let releasedAt, now - releasedAt > 1 { cancel() }
            else if releasedAt == nil { releasedAt = now }
            return
        }
        releasedAt = nil
        guard let edge, now - lastScroll > 0.16, let index = order.firstIndex(of: edge.id) else { return }
        var candidate = index + edge.direction
        while order.indices.contains(candidate), order[candidate] == layerID { candidate += edge.direction }
        guard order.indices.contains(candidate), !visibleIDs.contains(order[candidate]) else { return }
        lastScroll = now
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.16)) {
            scroll?(order[candidate], edge.direction > 0 ? .bottom : .top)
        }
    }
}

struct LayerElementDropDelegate: DropDelegate {
    let id: UUID
    let state: LayerListDragState
    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { state.layerID != nil && info.hasItemsConforming(to: [LayerListDragState.contentType]) }
    }
    func dropEntered(info: DropInfo) { MainActor.assumeIsolated { state.entered(id) } }
    func dropExited(info: DropInfo) { MainActor.assumeIsolated { state.exited(id) } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated { state.updated(id, y: info.location.y) }
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool { MainActor.assumeIsolated { state.drop() } }
}
