import SwiftUI
import EasyPicCore

struct RecognitionOverlay: View {
    @ObservedObject var model: EditorModel
    let size: CGSize
    private var imageSize: CGSize { model.cropImageSize }
    private var scale: CGFloat { size.width / max(1, imageSize.width) }
    private var selection: Binding<CGRect?> {
        Binding(get: {
            let unit = model.recognitionRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            return CGRect(x: unit.minX * imageSize.width, y: unit.minY * imageSize.height,
                          width: unit.width * imageSize.width, height: unit.height * imageSize.height)
        }, set: { pixels in
            guard let pixels else { return }
            model.recognitionRegion = CGRect(x: pixels.minX / imageSize.width, y: pixels.minY / imageSize.height,
                                             width: pixels.width / imageSize.width, height: pixels.height / imageSize.height)
        })
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.sidePanel == .text {
                if model.recognitionPresentation == .separate {
                    ForEach(model.recognitionResult.lines) { line in marker(line.bounds, id: line.id, color: .cyan) }
                }
                ImageSelectionOverlay(rect: selection, imageSize: imageSize, size: size, scale: scale,
                                      enabled: !model.busy, showsGrid: false, label: L10n.text("文字识别选区"),
                                      finished: { model.recognizeRegion(model.recognitionRegion) }, tapped: { point in
                    guard model.recognitionPresentation == .separate else { return }
                    let unit = CGPoint(x: point.x / imageSize.width, y: point.y / imageSize.height)
                    if let line = model.recognitionResult.lines.first(where: { $0.bounds.contains(unit) }) {
                        model.highlightedRecognitionID = line.id; model.recognitionScrollTarget = line.id
                    }
                })
            } else if model.sidePanel == .qr {
                ForEach(model.recognitionResult.codes) { code in marker(code.bounds, id: code.id, color: .purple) }
            }
        }
        .frame(width: size.width, height: size.height)
    }
    private func marker(_ normalized: CGRect, id: UUID, color: Color) -> some View {
        let rect = CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
                          width: normalized.width * size.width, height: normalized.height * size.height)
        let selected = model.highlightedRecognitionID == id
        return Rectangle().fill(color.opacity(selected ? 0.20 : 0.02))
            .overlay(Rectangle().stroke(color.opacity(selected ? 1 : 0.5), lineWidth: selected ? 2 : 0.7))
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture { model.highlightedRecognitionID = id; model.recognitionScrollTarget = id }
    }
}
