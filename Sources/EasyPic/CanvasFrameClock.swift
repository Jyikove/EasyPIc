import AppKit
import SwiftUI
import QuartzCore
import EasyPicCore

/// One input batch per native display refresh. Last-value updates are coalesced;
/// callers keep stroke samples in a separate buffer and flush before mouse-up commits.
@MainActor final class CanvasFrameClock: NSObject, ObservableObject {
    private struct Pending { var action: () -> Void; let trace: UUID? }
    private var pending: [String: Pending] = [:]
    private var link: CADisplayLink?
    private var target: Target?
    private weak var window: NSWindow?
    private var fallbackScheduled = false
    private var suspended = false
    func setRenderingActive(_ active: Bool) {
        guard suspended == active else { return }
        suspended = !active
        if suspended {
            for key in pending.keys.sorted() { flush(key) }
            awaitingDisplay.removeAll(); link?.isPaused = true
        } else { wake() }
    }
    private var awaitingView: Set<UUID> = []
    private var awaitingDisplay: Set<UUID> = []
    private var seen: Set<UUID> = []
    private var seenOrder: [UUID] = []
    private(set) var currentTrace: UUID?
    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        link?.invalidate(); link = nil; self.window = window
        if let window {
            let target = Target(); target.owner = self; self.target = target
            let link = window.displayLink(target: target, selector: #selector(Target.tick(_:)))
            let rate = Float(window.screen?.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, rate), maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common); link.isPaused = true; self.link = link
            wake()
        }
    }
    func submit(_ key: String, at timestamp: Double? = nil, _ action: @escaping () -> Void) {
        if var job = pending[key] {
            job.action = action; pending[key] = job
            InteractionMetrics.shared.count(job.trace, "coalescedInputs")
        } else {
            let trace = InteractionMetrics.shared.begin(key, at: timestamp)
            pending[key] = Pending(action: action, trace: trace)
        }
        wake()
    }
    func flush(_ key: String) {
        guard let job = pending.removeValue(forKey: key) else { return }
        currentTrace = job.trace
        InteractionMetrics.shared.mark(job.trace, "FrameApply")
        job.action()
        if let trace = job.trace { awaitingView.insert(trace) }
        currentTrace = nil
    }
    func noteViewUpdate(_ explicit: UUID? = nil) {
        if let explicit, !seen.contains(explicit) { awaitingView.insert(explicit) }
        for trace in awaitingView where !seen.contains(trace) {
            InteractionMetrics.shared.mark(trace, "ViewUpdate")
            if link != nil { awaitingDisplay.insert(trace) }
            seen.insert(trace); seenOrder.append(trace)
        }
        awaitingView.removeAll()
        while seenOrder.count > 2048 { seen.remove(seenOrder.removeFirst()) }
        wake()
    }
    func cancel(_ key: String) { pending.removeValue(forKey: key) }
    private func wake() {
        guard !suspended else { link?.isPaused = true; return }
        if let link { link.isPaused = pending.isEmpty && awaitingDisplay.isEmpty; return }
        guard !fallbackScheduled, !pending.isEmpty else { return }
        fallbackScheduled = true
        DispatchQueue.main.async { [weak self] in self?.fallbackScheduled = false; self?.advance() }
    }
    private func advance() {
        guard !suspended else { link?.isPaused = true; return }
        // A display opportunity is explicitly an estimate, not physical presentation.
        if link != nil {
            for trace in awaitingDisplay { InteractionMetrics.shared.mark(trace, "NextDisplayOpportunityEstimate") }
        }
        awaitingDisplay.removeAll()
        for key in pending.keys.sorted() { flush(key) }
        if pending.isEmpty && awaitingDisplay.isEmpty { link?.isPaused = true }
    }
    @MainActor private final class Target: NSObject {
        weak var owner: CanvasFrameClock?
        @objc func tick(_ link: CADisplayLink) { owner?.advance() }
    }
    deinit { link?.invalidate() }
}

struct FramePresentationProbe: NSViewRepresentable {
    let clock: CanvasFrameClock
    var trace: UUID? = nil
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { clock.noteViewUpdate(trace) }
}
