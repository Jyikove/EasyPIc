import SwiftUI
import AppKit
import EasyPicCore

/// Shared blue-tinted materials; the native compositor supplies refraction.
enum EasyPicGlass {
    static let accent = Color(red: 0.57, green: 0.77, blue: 1)
    static let blue = Color(red: 0.18, green: 0.43, blue: 0.73)
    static let panelBlue = Color(red: 0.48, green: 0.69, blue: 0.94)
    enum Surface { case canvas, panel, floating, input, control }
    static func edge(_ surface: Surface, highlighted: Bool = false) -> LinearGradient {
        let top: Double = highlighted ? 0.64 : (surface == .control ? 0.36 : 0.44)
        return LinearGradient(stops: [
            .init(color: .white.opacity(top), location: 0),
            .init(color: Color(red: 0.80, green: 0.91, blue: 1).opacity(0.24), location: 0.22),
            .init(color: .white.opacity(0.08), location: 0.60),
            .init(color: .white.opacity(0.16), location: 1)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    @MainActor static func prepareFilePanel(_ panel: NSSavePanel) {
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.titlebarAppearsTransparent = true
    }
}

extension View {
    func glassSurface(_ surface: EasyPicGlass.Surface = .panel, radius: CGFloat = 20,
                      selected: Bool = false, interactive: Bool = false) -> some View {
        modifier(GlassSurfaceModifier(surface: surface, radius: radius, selected: selected, interactive: interactive))
    }
    func glassWindowBackground() -> some View {
        background(GlassWindowAppearanceBridge())
            .preferredColorScheme(.dark).tint(EasyPicGlass.accent)
    }
    func glassPopover(radius: CGFloat = 18) -> some View {
        glassSurface(.floating, radius: radius)
            .presentationBackground(.clear)
            .preferredColorScheme(.dark).tint(EasyPicGlass.accent)
            .glassEntrance()
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let surface: EasyPicGlass.Surface
    let radius: CGFloat
    let selected: Bool
    let interactive: Bool
    private var material: Glass {
        let isPanel = surface == .canvas || surface == .panel
        let alpha = selected ? 0.22 : (surface == .floating ? 0.10 : (isPanel ? 0.08 : 0.055))
        let tint = isPanel ? EasyPicGlass.panelBlue : EasyPicGlass.blue
        let base = (surface == .canvas ? Glass.clear : Glass.regular).tint(tint.opacity(alpha))
        return interactive ? base.interactive() : base
    }
    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(surface == .canvas || surface == .panel ?
                              Color(red: 0.14, green: 0.21, blue: 0.30) : Color(red: 0.08, green: 0.10, blue: 0.14))
                }
            }
            .glassEffect(material, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(EasyPicGlass.edge(surface, highlighted: selected), lineWidth: 0.8)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .shadow(color: .black.opacity(surface == .floating ? 0.22 : 0.07),
                    radius: surface == .floating ? 16 : 5, y: surface == .floating ? 8 : 2)
    }
}

struct GlassButtonStyle: ButtonStyle {
    var selected = false
    var prominent = false
    var destructive = false
    var radius: CGFloat = 10
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 5
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, style: self, enabled: enabled, reduceMotion: reduceMotion)
    }
}
private struct GlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: GlassButtonStyle
    let enabled: Bool
    let reduceMotion: Bool
    @State private var hovered = false
    var body: some View {
        configuration.label
            .padding(.horizontal, style.horizontalPadding).padding(.vertical, style.verticalPadding)
            .foregroundStyle(style.destructive ? Color(red: 1, green: 0.56, blue: 0.58) :
                ((style.selected || style.prominent) ? EasyPicGlass.accent : Color.primary))
            .contentShape(RoundedRectangle(cornerRadius: style.radius))
            .glassSurface(.control, radius: style.radius,
                          selected: style.selected || style.prominent || (hovered && enabled), interactive: true)
            .opacity(enabled ? 1 : 0.36)
            .scaleEffect(configuration.isPressed && enabled ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovered = $0 }
    }
}

struct GlassToggleStyle: ToggleStyle {
    var isButton = false
    func makeBody(configuration: Configuration) -> some View {
        if isButton {
            Button { configuration.isOn.toggle() } label: { configuration.label }
                .buttonStyle(GlassButtonStyle(selected: configuration.isOn, horizontalPadding: 6, verticalPadding: 3))
                .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        } else {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 8) {
                    configuration.label
                    Spacer(minLength: 4)
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule().fill(.clear).frame(width: 36, height: 22)
                            .glassSurface(.input, radius: 11, selected: configuration.isOn)
                        Circle().fill(.clear).frame(width: 16, height: 16)
                            .glassSurface(.control, radius: 8, selected: configuration.isOn)
                            .padding(3)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
            .accessibilityValue(configuration.isOn ? L10n.text("已开启") : L10n.text("已关闭"))
        }
    }
}

struct GlassSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(String, Value)]
    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    Button { selection = option.1 } label: {
                        Text(option.0).frame(maxWidth: .infinity, minHeight: 26)
                    }
                    .buttonStyle(GlassButtonStyle(selected: selection == option.1, radius: 8,
                                                  horizontalPadding: 5, verticalPadding: 0))
                    .accessibilityAddTraits(selection == option.1 ? .isSelected : [])
                }
            }
        }
        .padding(3).glassSurface(.input, radius: 11)
    }
}

/// Continuous dragging, track clicks, keyboard arrows and VoiceOver adjustment share one value path.
struct GlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool
    @State private var dragging = false
    init(value: Binding<Double>, in range: ClosedRange<Double>) { _value = value; self.range = range }
    private var fraction: Double {
        guard value.isFinite, range.upperBound > range.lowerBound else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
    private func setValue(_ next: Double) {
        guard enabled, next.isFinite else { return }
        value = min(range.upperBound, max(range.lowerBound, next))
    }
    private func adjust(_ direction: Double) { setValue(value + direction * (range.upperBound - range.lowerBound) / 100) }
    var body: some View {
        GeometryReader { geometry in
            let diameter: CGFloat = 18
            let travel = max(1, geometry.size.width - diameter)
            let progress = travel * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(.clear).frame(height: 6)
                    .glassSurface(.input, radius: 3)
                Capsule().fill(EasyPicGlass.accent.opacity(0.28))
                    .frame(width: progress + diameter / 2, height: 6)
                    .glassSurface(.control, radius: 3, selected: true)
                Circle().fill(.clear).frame(width: diameter, height: diameter)
                    .glassSurface(.control, radius: diameter / 2, selected: focused || dragging, interactive: true)
                    .scaleEffect(dragging ? 1.1 : 1).offset(x: progress)
            }
            .frame(height: 24).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                guard enabled else { return }; focused = true; dragging = true
                let ratio = min(1, max(0, (event.location.x - diameter / 2) / travel))
                setValue(range.lowerBound + ratio * (range.upperBound - range.lowerBound))
            }.onEnded { _ in dragging = false })
        }
        .frame(minWidth: 48, maxWidth: .infinity).frame(height: 24)
        .opacity(enabled ? 1 : 0.36)
        .focusable(enabled).focused($focused).focusEffectDisabled()
        .onKeyPress { event in
            switch event.key {
            case .leftArrow, .downArrow: adjust(event.modifiers.contains(.shift) ? -10 : -1); return .handled
            case .rightArrow, .upArrow: adjust(event.modifiers.contains(.shift) ? 10 : 1); return .handled
            default: return .ignored
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(value.formatted(.number.precision(.fractionLength(0...2))))
        .accessibilityAdjustableAction { direction in
            if direction == .increment { adjust(1) } else if direction == .decrement { adjust(-1) }
        }
    }
}

struct GlassDialog<Actions: View>: View {
    @FocusState private var focused: Bool
    let title: String
    let message: String
    var icon = "questionmark.circle"
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(EasyPicGlass.accent)
            Text(title).font(.system(size: 18, weight: .semibold)).multilineTextAlignment(.center)
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            actions()
        }
        .padding(24).frame(width: 330)
        .glassSurface(.floating, radius: 24)
        .preferredColorScheme(.dark).tint(EasyPicGlass.accent)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
    }
}

/// Transparent utility windows use the same native backdrop as the document window.
struct GlassWindowAppearanceBridge: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func makeNSView(context: Context) -> NSView {
        let view = GlassAppearanceView()
        view.reduceTransparency = reduceTransparency
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? GlassAppearanceView else { return }
        view.reduceTransparency = reduceTransparency
        view.scheduleAppearance()
    }
}
private final class GlassAppearanceView: NSView {
    var reduceTransparency = false
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleAppearance() }
    func scheduleAppearance() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            GlassBackdropView.install(in: window, reducedTransparency: self.reduceTransparency)
        }
    }
}
