import SwiftUI
import AppKit
import QuartzCore
import Combine

/// Camera state is independent of document state. Native viewing changes a retained layer
/// transform; only tools with SwiftUI handles request view updates.
@MainActor final class CanvasCamera: @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    var publishesChanges = true
    var changed: (() -> Void)?
    var zoom = 1.0
    var pan = CGSize.zero
    func update(zoom: Double? = nil, pan: CGSize? = nil) {
        let nextZoom = zoom ?? self.zoom, nextPan = pan ?? self.pan
        guard nextZoom != self.zoom || nextPan != self.pan else { return }
        if publishesChanges { objectWillChange.send() }
        self.zoom = nextZoom; self.pan = nextPan; changed?()
    }
}

struct NativeRasterViewport: NSViewRepresentable {
    let image: CGImage
    let camera: CanvasCamera
    let actualSize: Bool
    let active: Bool
    let clock: CanvasFrameClock
    func makeNSView(context: Context) -> RasterViewportView { RasterViewportView() }
    func updateNSView(_ view: RasterViewportView, context: Context) {
        view.configure(image: image, camera: camera, actualSize: actualSize, active: active, clock: clock)
    }
}

final class RasterViewportView: NSView, CALayerDelegate {
    let imageLayer = CALayer()
    private let checker = CALayer(), checkerClip = CAShapeLayer()
    private weak var camera: CanvasCamera?
    private weak var clock: CanvasFrameClock?
    private var imageID: ObjectIdentifier?
    private var pixelSize = CGSize.zero
    private var actualSize = false, active = true
    private(set) var textureAssignments = 0
    private(set) var transformUpdates = 0
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.masksToBounds = true
        checker.delegate = self; checker.needsDisplayOnBoundsChange = true; checker.mask = checkerClip
        imageLayer.minificationFilter = .trilinear; imageLayer.magnificationFilter = .linear
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(checker); layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(image: CGImage, camera: CanvasCamera, actualSize: Bool, active: Bool, clock: CanvasFrameClock) {
        self.camera = camera; self.clock = clock; self.actualSize = actualSize; self.active = active
        camera.changed = { [weak self] in self?.updateCamera() }
        if imageID != ObjectIdentifier(image) {
            imageID = ObjectIdentifier(image); pixelSize = CGSize(width: image.width, height: image.height)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            imageLayer.contents = image; imageLayer.bounds = CGRect(origin: .zero, size: pixelSize)
            CATransaction.commit(); textureAssignments += 1
        }
        updateCamera()
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        checker.frame = bounds; checker.contentsScale = window?.backingScaleFactor ?? 2
        checkerClip.frame = bounds
        CATransaction.commit(); updateCamera()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); checker.setNeedsDisplay(); needsLayout = true }
    func updateCamera() {
        guard active, let camera, pixelSize.width > 0, bounds.width > 0 else { return }
        let fit = min(max(1, bounds.width - 2 * CanvasLayout.imageInset) / pixelSize.width,
                      max(1, bounds.height - 2 * CanvasLayout.imageInset) / pixelSize.height)
        let scale = (actualSize ? 1 / (window?.backingScaleFactor ?? 2) : fit) * camera.zoom
        let center = CGPoint(x: bounds.midX + camera.pan.width, y: bounds.midY + camera.pan.height)
        let area = CGRect(x: center.x - pixelSize.width * scale / 2, y: center.y - pixelSize.height * scale / 2,
                          width: pixelSize.width * scale, height: pixelSize.height * scale).intersection(bounds)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.position = center; imageLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        checkerClip.path = area.isNull ? nil : CGPath(rect: area, transform: nil)
        CATransaction.commit(); transformUpdates += 1
        clock?.noteViewUpdate(clock?.currentTrace)
    }
    func draw(_ layer: CALayer, in context: CGContext) {
        context.draw(Self.checkerTile, in: CGRect(x: 0, y: 0, width: 24, height: 24), byTiling: true)
    }
    private static let checkerTile: CGImage = {
        let c = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray: 0.19, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        c.setFillColor(CGColor(gray: 0.25, alpha: 1)); c.fill([CGRect(x: 0, y: 0, width: 12, height: 12), CGRect(x: 12, y: 12, width: 12, height: 12)])
        return c.makeImage()!
    }()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Retained texture for tool/layer previews as well. Resizing never reassigns its image.
struct NativeRasterImage: NSViewRepresentable {
    let image: CGImage
    func makeNSView(context: Context) -> ImageView { ImageView() }
    func updateNSView(_ view: ImageView, context: Context) { view.setImage(image) }
    final class ImageView: NSView {
        private let picture = CALayer()
        private var identity: ObjectIdentifier?
        override init(frame: NSRect) {
            super.init(frame: frame); wantsLayer = true
            picture.contentsGravity = .resize; picture.minificationFilter = .trilinear; picture.magnificationFilter = .linear
            layer?.addSublayer(picture)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func setImage(_ image: CGImage) {
            guard identity != ObjectIdentifier(image) else { return }
            identity = ObjectIdentifier(image)
            CATransaction.begin(); CATransaction.setDisableActions(true); picture.contents = image; CATransaction.commit()
        }
        override func layout() {
            super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); picture.frame = bounds; CATransaction.commit()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
