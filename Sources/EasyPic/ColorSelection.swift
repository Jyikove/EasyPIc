import SwiftUI
import EasyPicCore

struct EasyPicColorButton: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    let title: String
    @Binding var selection: TextColor
    var alignWithNumericInput = false
    @State private var presented = false

    var body: some View {
        let _ = languageSettings.language
        HStack {
            Text(title)
            Spacer()
            Button { presented.toggle() } label: {
                ColorSwatch(color: selection)
                    .frame(width: alignWithNumericInput ? EditorValueLayout.fieldWidth : 30, height: 22)
            }
            .buttonStyle(GlassButtonStyle(radius: 6, horizontalPadding: 0, verticalPadding: 0))
            .quickHelp(L10n.text("选择") + title).accessibilityLabel(L10n.text("选择") + title)
            .popover(isPresented: $presented, arrowEdge: .leading) {
                EasyPicColorPopover(selection: $selection)
            }
            .padding(.trailing, alignWithNumericInput ? EditorValueLayout.fieldTrailingInset : 0)
        }
    }
}

private struct ColorSwatch: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    let color: TextColor
    var body: some View {
        let _ = languageSettings.language
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0...Int(size.height / 5) {
                for column in 0...Int(size.width / 5) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: column * 5, y: row * 5, width: 5, height: 5)), with: .color(.gray.opacity(0.35)))
                }
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(cgColor: color.cgColor)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.2), lineWidth: 1))
    }
}

private struct PickerHSV {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(_ color: TextColor) {
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        let delta = maximum - minimum
        brightness = maximum
        saturation = maximum == 0 ? 0 : delta / maximum
        if delta == 0 { hue = 0 }
        else if maximum == color.red { hue = ((color.green - color.blue) / delta).truncatingRemainder(dividingBy: 6) / 6 }
        else if maximum == color.green { hue = ((color.blue - color.red) / delta + 2) / 6 }
        else { hue = ((color.red - color.green) / delta + 4) / 6 }
        if hue < 0 { hue += 1 }
    }

    static func color(hue: Double, saturation: Double, brightness: Double, alpha: Double) -> TextColor {
        let h = (hue - floor(hue)) * 6
        let chroma = brightness * saturation
        let second = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let offset = brightness - chroma
        let rgb: (Double, Double, Double)
        switch Int(h) {
        case 0: rgb = (chroma, second, 0)
        case 1: rgb = (second, chroma, 0)
        case 2: rgb = (0, chroma, second)
        case 3: rgb = (0, second, chroma)
        case 4: rgb = (second, 0, chroma)
        default: rgb = (chroma, 0, second)
        }
        return TextColor(rgb.0 + offset, rgb.1 + offset, rgb.2 + offset, alpha)
    }
}

private struct EasyPicColorPopover: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @Binding var selection: TextColor
    @State private var hue: Double
    @State private var radius: Double
    @State private var saturation = 1.0
    @State private var brightness: Double
    @State private var opacity: Double
    private let diameter = 220.0
    private static var presets: [(String, TextColor)] { [
        (L10n.text("白色"), TextColor(1, 1, 1)), (L10n.text("黑色"), TextColor(0, 0, 0)),
        (L10n.text("灰色"), TextColor(0.5, 0.5, 0.5)), (L10n.text("红色"), TextColor(1, 0, 0)),
        (L10n.text("橙色"), TextColor(1, 0.5, 0)), (L10n.text("黄色"), TextColor(1, 1, 0)),
        (L10n.text("绿色"), TextColor(0.1, 0.75, 0.25)), (L10n.text("蓝色"), TextColor(0, 0.4, 1)),
        (L10n.text("紫色"), TextColor(0.6, 0.2, 0.9)), (L10n.text("粉色"), TextColor(1, 0.3, 0.6))
    ] }

    init(selection: Binding<TextColor>) {
        _selection = selection
        let hsv = PickerHSV(selection.wrappedValue)
        _hue = State(initialValue: hsv.hue)
        _radius = State(initialValue: hsv.saturation)
        _brightness = State(initialValue: 1)
        _opacity = State(initialValue: 1)
    }

    var body: some View {
        let _ = languageSettings.language
        VStack(spacing: 14) {
            wheel
            slider(L10n.text("亮度"), value: $brightness)
            slider(L10n.text("饱和度"), value: $saturation)
            slider(L10n.text("透明度"), value: $opacity)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 10), count: 5), spacing: 10) {
                ForEach(Self.presets.indices, id: \.self) { index in
                    let preset = Self.presets[index]
                    Button { choose(preset.1) } label: {
                        ColorSwatch(color: preset.1).frame(width: 34, height: 28)
                    }
                    .buttonStyle(GlassButtonStyle(radius: 6, horizontalPadding: 0, verticalPadding: 0)).quickHelp(preset.0).accessibilityLabel(preset.0)
                }
            }
        }
        .padding(16).frame(width: 252).glassPopover(radius: 20)
        .onAppear {
            let hsv = PickerHSV(selection)
            hue = hsv.hue; radius = hsv.saturation; saturation = 1
            brightness = 1; opacity = 1
        }
    }

    private var wheel: some View {
        ZStack {
            AngularGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
                            center: .center, startAngle: .zero, endAngle: .degrees(360))
            RadialGradient(stops: [.init(color: .white, location: 0),
                                   .init(color: .white.opacity(1 - saturation), location: 1)],
                           center: .center, startRadius: 0, endRadius: diameter / 2)
            Color.black.opacity(1 - brightness)
            Circle().fill(Color(cgColor: PickerHSV.color(hue: hue, saturation: radius * saturation,
                                                       brightness: brightness, alpha: opacity).cgColor))
                .frame(width: 13, height: 13)
                .glassSurface(.control, radius: 6.5)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.7), radius: 1)
                .offset(x: cos(hue * 2 * .pi) * radius * (diameter / 2 - 7),
                        y: sin(hue * 2 * .pi) * radius * (diameter / 2 - 7))
        }
        .frame(width: diameter, height: diameter).clipShape(Circle())
        .overlay(Circle().strokeBorder(EasyPicGlass.edge(.control), lineWidth: 1).allowsHitTesting(false))
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let x = value.location.x - diameter / 2, y = value.location.y - diameter / 2
            let distance = hypot(x, y)
            if distance > 0.001 {
                let angle = atan2(y, x) / (2 * .pi)
                hue = angle < 0 ? angle + 1 : angle
            }
            radius = min(1, distance / (diameter / 2))
            updateSelection()
        })
        .accessibilityElement().accessibilityLabel(L10n.text("圆形色盘"))
        .accessibilityHint(L10n.text("拖动选择颜色；圆心为灰白，边缘色彩更浓。"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: hue = (hue + 1 / 36).truncatingRemainder(dividingBy: 1)
            case .decrement: hue = (hue + 1 - 1 / 36).truncatingRemainder(dividingBy: 1)
            @unknown default: return
            }
            updateSelection()
        }
    }

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 12))
            GlassSlider(value: Binding(get: { value.wrappedValue }, set: { next in
                value.wrappedValue = next
                updateSelection()
            }), in: 0...1).accessibilityLabel(title)
        }
    }

    private func updateSelection() {
        selection = PickerHSV.color(hue: hue, saturation: radius * saturation, brightness: brightness, alpha: opacity)
    }

    private func choose(_ color: TextColor) {
        let hsv = PickerHSV(color)
        hue = hsv.hue; radius = hsv.saturation; saturation = 1
        brightness = hsv.brightness; opacity = color.alpha
        updateSelection()
    }
}
