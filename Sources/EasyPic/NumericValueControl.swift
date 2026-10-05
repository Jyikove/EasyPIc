import SwiftUI
import EasyPicCore

enum EditorValueLayout {
    static let fieldWidth: CGFloat = 64
    static let adjustmentWidth: CGFloat = 20
    static let spacing: CGFloat = 5
    static let fieldTrailingInset = adjustmentWidth + spacing
}

struct NumericValueControl: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1_000_000...1_000_000
    var step: Double = 1
    var updatesContinuously = true
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: EditorValueLayout.spacing) {
            Text(title)
            Spacer(minLength: 4)
            adjustment("minus", amount: -step)
            TextField(title, text: $input)
                .labelsHidden().textFieldStyle(.plain)
                .multilineTextAlignment(.trailing).padding(.horizontal, 6)
                .frame(width: EditorValueLayout.fieldWidth, height: 24)
                .glassSurface(.input, radius: 7, selected: focused)
                .focused($focused)
                .onSubmit { commitInput(); focused = false }
                .onChange(of: input) { _, _ in
                    if focused && updatesContinuously { commitInput() }
                }
            adjustment("plus", amount: step)
        }
        .onAppear { input = formatted(value) }
        .onChange(of: value) { _, next in if !focused { input = formatted(next) } }
        .onChange(of: focused) { _, editing in
            if !editing { commitInput(); input = formatted(value) }
        }
    }
    private func formatted(_ number: Double) -> String {
        number.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }
    private func clamped(_ number: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, number))
    }
    private func commitInput() {
        guard let number = Double(input), number.isFinite else { return }
        let next = clamped(number)
        if next != value { value = next }
    }
    private func adjustment(_ symbol: String, amount: Double) -> some View {
        Button {
            let current = Double(input).flatMap { $0.isFinite ? $0 : nil } ?? value
            let next = clamped(current + amount)
            input = formatted(next)
            if next != value { value = next }
            focused = false
        } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .frame(width: EditorValueLayout.adjustmentWidth, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(GlassButtonStyle(radius: 7, horizontalPadding: 0, verticalPadding: 0))
        .accessibilityLabel(title + " " + (amount > 0 ? "+" : "−"))
        .disabled(amount > 0 ? value >= range.upperBound : value <= range.lowerBound)
    }
}
