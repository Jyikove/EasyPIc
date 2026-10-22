import AppKit
import SwiftUI
import EasyPicCore

private actor SVGRenderWorker {
    func render(_ url: URL?, data: Data?, region: CGRect, pixels: CGSize, quarterTurns: Int) throws -> CGImage {
        try Task.checkCancellation()
        let source = try data ?? url.map { try Data(contentsOf: $0) }
        guard let source else { throw ImageFailure.unreadable }
        return try SVGImageRenderer.renderRegion(data: source, region: region, pixelSize: pixels, quarterTurns: quarterTurns)
    }
}

/// Continuous zoom and pan use existing GPU textures. After input settles, one worker
/// refreshes just the visible vector region at display density, never the huge zoomed canvas.
struct SVGImageView: NSViewRepresentable {
    @Environment(\.canvasRenderingActive) private var renderingActive
    let image: NSImage
    let poster: CGImage
    let sourceURL: URL?
    let viewport: CGRect
    var sourceData: Data? = nil
    var quarterTurns = 0
    func makeNSView(context: Context) -> VectorImageView { VectorImageView() }
    func updateNSView(_ view: VectorImageView, context: Context) {
        view.setRenderingActive(renderingActive)
        view.configure(image: image, poster: poster, url: sourceURL, viewport: viewport, data: sourceData, quarterTurns: quarterTurns)
    }
    static func dismantleNSView(_ view: VectorImageView, coordinator: ()) { view.cancel() }

    final class VectorImageView: NSView {
        private struct Detail: Equatable { let region: CGRect; let pixels: CGSize }
        private let worker = SVGRenderWorker()
        private let posterLayer = CALayer()
        private let detailLayer = CALayer()
        private var task: Task<Void, Never>?
        private var identity: ObjectIdentifier?
        private var sourceURL: URL?
        private var sourceData: Data?
        private var quarterTurns = 0
        private var posterIdentity: ObjectIdentifier?
        private var viewport = CGRect.zero
        private var requested: Detail?
        private var displayedRegion: CGRect?
        private var displayedDetail: Detail?
        private var renderingActive = true
        func setRenderingActive(_ active: Bool) {
            guard renderingActive != active else { return }
            renderingActive = active
            if active { scheduleDetail() } else { cancel(); requested = nil }
        }
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            posterLayer.contentsGravity = .resize
            posterLayer.minificationFilter = .trilinear
            posterLayer.magnificationFilter = .linear
            detailLayer.contentsGravity = .resize
            detailLayer.isHidden = true
            layer?.addSublayer(posterLayer); layer?.addSublayer(detailLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(image: NSImage, poster: CGImage, url: URL?, viewport: CGRect, data: Data? = nil, quarterTurns: Int = 0) {
            if identity != ObjectIdentifier(image) || sourceURL != url || self.quarterTurns != quarterTurns || posterIdentity != ObjectIdentifier(poster) {
                self.sourceData = data; self.quarterTurns = quarterTurns; posterIdentity = ObjectIdentifier(poster)
                cancel()
                identity = ObjectIdentifier(image); sourceURL = url; requested = nil; displayedRegion = nil; displayedDetail = nil
                CATransaction.begin(); CATransaction.setDisableActions(true)
                posterLayer.contents = poster; posterLayer.isHidden = false
                detailLayer.contents = nil; detailLayer.isHidden = true
                CATransaction.commit()
            }
            self.viewport = viewport
            scheduleDetail()
        }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); positionDetail(); scheduleDetail() }
        override func layout() { super.layout(); positionDetail(); scheduleDetail() }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); scheduleDetail() }
        private func positionDetail() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            posterLayer.frame = bounds
            if let region = displayedRegion {
                detailLayer.frame = CGRect(x: region.minX * bounds.width, y: region.minY * bounds.height,
                                           width: region.width * bounds.width, height: region.height * bounds.height)
            }
            CATransaction.commit()
        }
        private func scheduleDetail() {
            guard renderingActive, sourceURL != nil || sourceData != nil, bounds.width > 0, bounds.height > 0 else { return }
            let url = sourceURL, data = sourceData, turns = quarterTurns
            let visible = viewport.insetBy(dx: -128, dy: -128).intersection(bounds)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { cancel(); requested = nil; return }
            let region = CGRect(x: visible.minX / bounds.width, y: visible.minY / bounds.height,
                                width: visible.width / bounds.width, height: visible.height / bounds.height)
            let density = window?.backingScaleFactor ?? 2
            let factor = min(1, 4096 / max(visible.width * density, visible.height * density))
            let detail = Detail(region: region, pixels: CGSize(width: visible.width * density * factor, height: visible.height * density * factor))
            if let shown = displayedDetail {
                let coverage = CGRect(x: shown.region.minX * bounds.width, y: shown.region.minY * bounds.height,
                                      width: shown.region.width * bounds.width, height: shown.region.height * bounds.height)
                let required = viewport.intersection(bounds)
                let densityX = shown.pixels.width / max(1, coverage.width)
                if coverage.contains(required), densityX >= density * 0.9 { return }
            }
            guard detail != requested else { return }
            task?.cancel(); requested = detail
            // Never blend the same semi-transparent artwork twice. During input use
            // only the poster; once settled the detail covers the entire visible viewport.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            posterLayer.isHidden = false; detailLayer.isHidden = true
            CATransaction.commit()
            let expected = identity
            task = Task { [weak self, worker] in
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    let bitmap = try await worker.render(url, data: data, region: detail.region, pixels: detail.pixels, quarterTurns: turns)
                    guard !Task.isCancelled, let self, self.identity == expected, self.requested == detail else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.detailLayer.contents = bitmap; self.displayedRegion = detail.region; self.displayedDetail = detail
                    self.positionDetail()
                    self.posterLayer.isHidden = true; self.detailLayer.isHidden = false
                    CATransaction.commit()
                } catch { /* Keep the last valid texture when cancelled or unreadable. */ }
            }
        }
        func cancel() { task?.cancel(); task = nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
