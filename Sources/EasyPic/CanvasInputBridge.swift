import EasyPicCore
import AppKit
import SwiftUI

struct CanvasInputBridge: NSViewRepresentable {
    var frameClock: CanvasFrameClock? = nil
    var spacePanEnabled = false
    var shouldBeginPan: (CGPoint) -> Bool = { _ in false }
    var pan: (CGSize) -> Void = { _ in }
    var backgroundTap: (CGPoint) -> Void = { _ in }
    var input: (NSEvent, CGPoint) -> Void
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.frameClock = frameClock; frameClock?.attach(view.window)
        view.input = input
        view.spacePanEnabled = spacePanEnabled
        view.shouldBeginPan = shouldBeginPan
        view.pan = pan
        view.backgroundTap = backgroundTap
    }
    final class InputView: NSView {
        var frameClock: CanvasFrameClock?
        private var zoomEvents: [(NSEvent, CGPoint)] = []
        private var accumulatedPan: CGSize = .zero
        var spacePanEnabled = false {
            didSet { if !spacePanEnabled { lastPanPoint = nil } }
        }
        var shouldBeginPan: ((CGPoint) -> Bool)?
        var pan: ((CGSize) -> Void)?
        var backgroundTap: ((CGPoint) -> Void)?
        var input: ((NSEvent, CGPoint) -> Void)?
        private var monitor: Any?
        private var lastPanPoint: CGPoint?
        private var panStartPoint: CGPoint?
        private var panMoved = false
        private var panAllowsTap = false
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            frameClock?.attach(window)
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            lastPanPoint = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if event.type == .leftMouseDown { self.lastPanPoint = nil; self.panStartPoint = nil }
                // Keep a canvas pan captured until release, including outside the canvas.
                if let previous = self.lastPanPoint {
                    if event.type == .leftMouseDragged {
                        if let start = self.panStartPoint, hypot(point.x - start.x, point.y - start.y) > 3 {
                            self.panMoved = true
                        }
                        self.lastPanPoint = point
                        self.accumulatedPan.width += point.x - previous.x
                        self.accumulatedPan.height += point.y - previous.y
                        if let clock = self.frameClock {
                            clock.submit("CanvasPan", at: event.timestamp) { [weak self] in self?.flushPan() }
                        } else { self.flushPan() }
                        return nil
                    }
                    if event.type == .leftMouseUp {
                        self.frameClock?.flush("CanvasPan"); self.flushPan()
                        let isTap = self.panAllowsTap && !self.panMoved && self.bounds.contains(point)
                        self.lastPanPoint = nil
                        self.panStartPoint = nil
                        if isTap { self.backgroundTap?(point) }
                        return nil
                    }
                }
                guard self.bounds.contains(point) else { return event }
                if event.type == .leftMouseDown {
                    let spaceDrag = self.spacePanEnabled && CGEventSource.keyState(.combinedSessionState, key: 49)
                    guard spaceDrag || self.shouldBeginPan?(point) == true else { return event }
                    self.lastPanPoint = point
                    self.panStartPoint = point
                    self.panMoved = false
                    self.panAllowsTap = !spaceDrag
                    return nil
                }
                guard event.type == .scrollWheel || event.type == .magnify else { return event }
                self.zoomEvents.append((event, point))
                if let clock = self.frameClock {
                    clock.submit("CanvasZoom", at: event.timestamp) { [weak self] in
                        guard let self else { return }
                        let events = self.zoomEvents; self.zoomEvents.removeAll(keepingCapacity: true)
                        for (event, point) in events { self.input?(event, point) }
                    }
                } else { self.input?(event, point); self.zoomEvents.removeAll() }
                return nil
            }
        }
        private func flushPan() {
            let delta = accumulatedPan; accumulatedPan = .zero
            if delta != .zero { pan?(delta) }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
