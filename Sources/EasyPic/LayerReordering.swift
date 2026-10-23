import SwiftUI
import AppKit
import EasyPicCore

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

/// Local mouse tracking keeps one gesture alive while SwiftUI rearranges the rows.
/// No pasteboard, drop destination, or mouse-up timeout participates in committing.
@MainActor final class LayerListDragState: ObservableObject {
    static let rowPitch: CGFloat = 34
    @Published private(set) var layerID: UUID?
    @Published private(set) var translation: CGFloat = 0
    var visibleIDs = Set<UUID>()
    var viewport: CGRect = .zero
    private let clock = CanvasFrameClock()
    private var order: [UUID] = []
    private var sourceID: UUID?
    private var originalIndex = 0
    private var initialPoint = CGPoint.zero
    private var pointer = CGPoint.zero
    private var scrollOffset: CGFloat = 0
    private var initialScrollOffset: CGFloat = 0
    private var filter: LayerInspectorFilter = .all
    private weak var model: EditorModel?
    private weak var window: NSWindow?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var timer: Timer?
    private var select: (() -> Void)?
    private var scroll: ((UUID, UnitPoint) -> Void)?

    deinit {
        timer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
    func track(_ id: UUID, event: NSEvent, model: EditorModel, filter: LayerInspectorFilter,
               select: @escaping () -> Void, scroll: @escaping (UUID, UnitPoint) -> Void) {
        cancel()
        guard model.canPerformEditorActions, let window = event.window else { return }
        order = model.listedLayers(matching: filter, includingReorderPreview: false).map(\.id)
        guard let index = order.firstIndex(of: id) else { return }
        self.model = model; self.filter = filter; self.window = window
        self.select = select; self.scroll = scroll; sourceID = id; originalIndex = index
        initialPoint = event.locationInWindow; pointer = initialPoint
        initialScrollOffset = scrollOffset
        clock.attach(window)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, sourceID != nil else { return event }
        if event.type == .keyDown {
            if event.keyCode == 53 { cancel(); return nil }
            return event
        }
        let point = event.locationInWindow
        if event.type == .leftMouseDragged {
            pointer = point
            if layerID == nil, hypot(point.x - initialPoint.x, point.y - initialPoint.y) >= 4 {
                layerID = sourceID
                let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.autoscroll() }
                }
                self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            }
            if layerID != nil {
                clock.submit("LayerListDrag", at: event.timestamp) { [weak self] in self?.update(at: point) }
            }
            return nil
        }
        if event.type == .leftMouseUp {
            if layerID != nil {
                clock.flush("LayerListDrag"); update(at: point)
                if viewport.insetBy(dx: -12, dy: -8).contains(point) { commit() }
                else { cancel() }
            } else {
                let action = select
                finish(keepingPreview: false)
                action?()
            }
            return nil
        }
        return event
    }
    private func update(at point: CGPoint) {
        guard let id = layerID, let source = order.firstIndex(of: id), !order.isEmpty else { return }
        pointer = point
        translation = initialPoint.y - point.y + scrollOffset - initialScrollOffset
        let destination = min(order.count - 1, max(0, Int((CGFloat(originalIndex) + translation / Self.rowPitch).rounded())))
        guard destination != source else { return }
        order.remove(at: source); order.insert(id, at: destination)
        withAnimation(animation) { model?.previewLayerReorder(id, order: order, filter: filter) }
    }
    func rowOffset(_ id: UUID) -> CGFloat {
        guard layerID == id, let index = order.firstIndex(of: id) else { return 0 }
        return CGFloat(originalIndex - index) * Self.rowPitch + translation
    }
    func scrolled(to offset: CGFloat) {
        scrollOffset = offset
        guard layerID != nil else { return }
        let point = pointer
        clock.submit("LayerListDrag") { [weak self] in self?.update(at: point) }
    }
    private func autoscroll() {
        guard layerID != nil, !viewport.isEmpty else { return }
        let visible = order.indices.filter { visibleIDs.contains(order[$0]) }
        let target: Int
        let anchor: UnitPoint
        if pointer.y >= viewport.maxY - 12, let first = visible.first, first > 0 {
            target = first - 1; anchor = .top
        } else if pointer.y <= viewport.minY + 12, let last = visible.last, last < order.count - 1 {
            target = last + 1; anchor = .bottom
        } else { return }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.12)) {
            scroll?(order[target], anchor)
        }
    }
    private func commit() {
        guard let id = layerID, let model else { cancel(); return }
        let finalOrder = order
        finish(keepingPreview: true)
        if !model.commitLayerReorder(id, order: finalOrder, filter: filter) { model.layerReorderPreview = nil }
    }
    func cancel() { finish(keepingPreview: false) }
    private var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.88)
    }
    private func finish(keepingPreview: Bool) {
        clock.cancel("LayerListDrag"); clock.attach(nil)
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        if !keepingPreview, layerID != nil { withAnimation(animation) { model?.layerReorderPreview = nil } }
        layerID = nil; translation = 0; sourceID = nil; order = []
        select = nil; scroll = nil; model = nil; window = nil
    }
}

/// The native overlay receives the row's mouse-down; its trailing delete button
/// is excluded by the caller. A simple click still invokes the original action.
struct LayerRowInputBridge: NSViewRepresentable {
    let mouseDown: (NSEvent) -> Void
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) { view.down = mouseDown }
    final class InputView: NSView {
        var down: ((NSEvent) -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { down?(event) }
        override func accessibilityIsIgnored() -> Bool { true }
    }
}

struct LayerListViewportBridge: NSViewRepresentable {
    let measured: (CGRect) -> Void
    func makeNSView(context: Context) -> ViewportView { ViewportView() }
    func updateNSView(_ view: ViewportView, context: Context) {
        view.measured = measured; view.needsLayout = true
    }
    final class ViewportView: NSView {
        var measured: ((CGRect) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
        override func layout() {
            super.layout()
            if window != nil { measured?(convert(bounds, to: nil)) }
        }
    }
}
