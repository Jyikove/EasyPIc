import SwiftUI
import AppKit
import QuartzCore

@MainActor final class RotationTransition: Identifiable {
    let id = UUID()
    let image: CGImage
    let angle: Double
    let duration = 0.28
    private(set) var hasStarted = false
    private(set) var hasCompleted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(image: CGImage, angle: Double) { self.image = image; self.angle = angle }
    func started() { hasStarted = true }
    func finish() {
        guard !hasCompleted else { return }
        hasCompleted = true
        let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() }
    }
    func waitForCompletion() async {
        guard !hasCompleted else { return }
        // Background/headless windows must not leave an edit permanently busy.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.finish()
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Native layer animation is independent of the canvas transaction that disables layout animations.
struct RotatingImageView: NSViewRepresentable {
    let transition: RotationTransition
    let size: CGSize
    let finalScale: Double
    func makeNSView(context: Context) -> NativeRotationView { NativeRotationView() }
    func updateNSView(_ view: NativeRotationView, context: Context) {
        view.configure(transition, finalScale: finalScale)
    }
}

final class NativeRotationView: NSView {
    let imageLayer = CALayer()
    private var transition: RotationTransition?
    private var finalScale = 1.0
    private var completion: RotationAnimationCompletion?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; clipsToBounds = false
        layer?.masksToBounds = false
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear; imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ transition: RotationTransition, finalScale: Double) {
        guard self.transition?.id != transition.id else { return }
        self.transition = transition; self.finalScale = finalScale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = transition.image
        imageLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        startIfReady()
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit(); startIfReady()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); startIfReady() }
    private func startIfReady() {
        guard let transition, !transition.hasStarted, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        transition.started()
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0; rotation.toValue = transition.angle * .pi / 180
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1; scale.toValue = finalScale
        let group = CAAnimationGroup(); group.animations = [rotation, scale]
        group.duration = transition.duration; group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let completion = RotationAnimationCompletion(transition); self.completion = completion; group.delegate = completion
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.transform = CATransform3DScale(CATransform3DMakeRotation(transition.angle * .pi / 180, 0, 0, 1), finalScale, finalScale, 1)
        imageLayer.add(group, forKey: "EasyPicRotation")
        CATransaction.commit()
    }
}
private final class RotationAnimationCompletion: NSObject, CAAnimationDelegate {
    private weak var transition: RotationTransition?
    @MainActor init(_ transition: RotationTransition) { self.transition = transition }
    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        Task { @MainActor [weak self] in self?.transition?.finish() }
    }
}
