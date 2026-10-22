import SwiftUI
import AVFoundation
import AppKit

struct NativeLivePhotoView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> VideoView {
        let view = VideoView()
        view.video.player = player
        return view
    }
    func updateNSView(_ view: VideoView, context: Context) {
        if view.video.player !== player { view.video.player = player }
    }
    static func dismantleNSView(_ view: VideoView, coordinator: ()) { view.video.player = nil }
    final class VideoView: NSView {
        let video = AVPlayerLayer()
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            video.videoGravity = .resize
            layer?.addSublayer(video)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); layoutVideo() }
        override func layout() { super.layout(); layoutVideo() }
        private func layoutVideo() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            video.frame = bounds
            CATransaction.commit()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
