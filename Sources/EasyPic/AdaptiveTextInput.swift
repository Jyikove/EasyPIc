import SwiftUI
import AppKit

/// A plain text editor which grows with its wrapped lines, then scrolls at the cap.
struct AdaptiveTextInput: View {
    @Binding var text: String
    @Binding var focused: Bool
    @State private var height = GrowingTextScrollView.minimumHeight
    var body: some View {
        NativeInput(text: $text, focused: $focused, height: $height)
            .frame(maxWidth: .infinity).frame(height: height)
    }

    private struct NativeInput: NSViewRepresentable {
        @Binding var text: String
        @Binding var focused: Bool
        @Binding var height: CGFloat
        func makeCoordinator() -> Coordinator { Coordinator(self) }
        func makeNSView(context: Context) -> GrowingTextScrollView {
            let view = GrowingTextScrollView()
            view.editor.delegate = context.coordinator
            view.heightChanged = { [weak coordinator = context.coordinator] height in coordinator?.parent.height = height }
            view.editor.focusChanged = { [weak coordinator = context.coordinator] focused in coordinator?.parent.focused = focused }
            return view
        }
        func updateNSView(_ view: GrowingTextScrollView, context: Context) {
            context.coordinator.parent = self
            if view.editor.string != text && !view.editor.hasMarkedText() {
                let selection = view.editor.selectedRange()
                view.editor.string = text
                let location = min(selection.location, (text as NSString).length)
                view.editor.setSelectedRange(NSRange(location: location, length: min(selection.length, (text as NSString).length - location)))
                view.measureContent()
            }
        }
        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: NativeInput
            init(_ parent: NativeInput) { self.parent = parent }
            func textDidChange(_ notification: Notification) {
                guard let editor = notification.object as? NSTextView else { return }
                if parent.text != editor.string { parent.text = editor.string }
                (editor.enclosingScrollView as? GrowingTextScrollView)?.measureContent()
            }
        }
    }
}

final class GrowingTextScrollView: NSScrollView {
    static let minimumHeight: CGFloat = 40
    static let maximumHeight: CGFloat = 160
    let editor = FocusReportingTextView(frame: .zero)
    var heightChanged: ((CGFloat) -> Void)?
    private(set) var measuredHeight = minimumHeight
    private var measuring = false
    private var requestedInitialFocus = false
    private var reportedHeight: CGFloat?
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false; backgroundColor = .clear; borderType = .noBorder
        contentView.drawsBackground = false
        hasVerticalScroller = false; hasHorizontalScroller = false
        automaticallyAdjustsContentInsets = false; contentInsets = NSEdgeInsetsZero
        scrollerStyle = .overlay; scrollerKnobStyle = .light; autohidesScrollers = true
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        wantsLayer = true; layer?.masksToBounds = true
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.drawsBackground = false; editor.backgroundColor = .clear
        editor.font = .systemFont(ofSize: 13); editor.textColor = .labelColor
        editor.insertionPointColor = .white
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        documentView = editor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !requestedInitialFocus else { return }
        requestedInitialFocus = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.window === window else { return }
            window?.makeFirstResponder(self.editor)
        }
    }
    override func layout() { super.layout(); measureContent() }
    func measureContent() {
        guard !measuring, contentSize.width > 0,
              let layout = editor.layoutManager, let container = editor.textContainer else { return }
        measuring = true; defer { measuring = false }
        let width = contentSize.width
        if abs(editor.frame.width - width) > 0.5 { editor.setFrameSize(NSSize(width: width, height: max(1, editor.frame.height))) }
        container.containerSize = NSSize(width: max(1, width - 2 * editor.textContainerInset.width), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: editor.font ?? .systemFont(ofSize: 13))
        let textHeight = max(lineHeight, layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let natural = ceil(textHeight + 2 * editor.textContainerInset.height)
        let height = min(Self.maximumHeight, max(Self.minimumHeight, natural))
        let overflowing = natural > Self.maximumHeight
        if hasVerticalScroller != overflowing { hasVerticalScroller = overflowing }
        let documentHeight = max(height, natural)
        if abs(editor.frame.height - documentHeight) > 0.5 { editor.setFrameSize(NSSize(width: width, height: documentHeight)) }
        if !overflowing { contentView.scroll(to: .zero); reflectScrolledClipView(contentView) }
        measuredHeight = height
        guard reportedHeight != height else { return }
        reportedHeight = height
        DispatchQueue.main.async { [weak self] in
            guard let self, self.measuredHeight == height else { return }
            self.heightChanged?(height)
        }
    }
}

final class FocusReportingTextView: NSTextView {
    var focusChanged: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.focusChanged?(true) } }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.focusChanged?(false) } }
        return result
    }
}
