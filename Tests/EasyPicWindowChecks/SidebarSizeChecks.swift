import AppKit

@main @MainActor struct SidebarSizeChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "SidebarSizeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func flush() async { try? await Task.sleep(for: .milliseconds(40)) }
    static func main() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 30, y: 80, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let sizer = SidebarWindowSizer(minimumWidth: 850)
        sizer.attach(to: window); await flush()
        let baseline = window.frame
        let viewport = sizer.viewportWidth
        for width: CGFloat in [64, 220, 310, 64, 0, 0] {
            sizer.update(sidebarWidth: width); await flush()
            try expect(abs(window.frame.width - width - baseline.width) < 0.5, "Sidebar changed viewport width")
            try expect(window.frame.height == baseline.height, "Sidebar changed viewport height")
            try expect(sizer.viewportWidth == viewport, "Panel layout changed the fixed image viewport")
        }
        print("PASS: opening, switching and closing panels preserve viewport dimensions")

        var resized = window.frame; resized.size.width = 1120
        window.setFrame(resized, display: false)
        sizer.update(sidebarWidth: 64); await flush()
        try expect(abs(window.frame.width - 1184) < 0.5, "Manual window resize was lost")
        try expect(sizer.viewportWidth == 1096, "Manual window resize did not update the image viewport")
        print("PASS: panel expansion uses the user's current window size")

        let saved = window.frame
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        sizer.update(sidebarWidth: 310); await flush()
        try expect(window.frame == saved, "Window resized during fullscreen transition")
        sizer.update(sidebarWidth: 0); await flush()
        try expect(window.frame == saved, "Pending fullscreen transition resized window")
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        window.setFrame(saved, display: false)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        await flush()
        try expect(abs(window.frame.width - 1120) < 0.5, "Exiting fullscreen failed to reconcile closed panels")
        print("PASS: fullscreen transition notifications defer resizing and reconcile closed panels")

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        sizer.update(sidebarWidth: 220); await flush()
        NotificationCenter.default.post(name: .easyPicFullScreenTransitionFailed, object: window)
        await flush()
        try expect(abs(window.frame.width - 1340) < 0.5, "Failed fullscreen transition blocked further resizing")
        print("PASS: failed fullscreen transition resumes window sizing")
    }
}
