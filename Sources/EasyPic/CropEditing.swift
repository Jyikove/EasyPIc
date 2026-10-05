import EasyPicCore
import SwiftUI
import AppKit

enum CropRatio: String, CaseIterable, Identifiable {
    case free, original, square, portrait3x4, landscape4x3, wide16x9, tall9x16
    case portrait2x3, landscape3x2, wide18x9, tall9x18, cinema
    var id: Self { self }
    var title: String {
        switch self {
        case .free: return L10n.text("自由比例")
        case .original: return L10n.text("原图比例")
        case .square: return "1 : 1"
        case .portrait3x4: return "3 : 4"
        case .landscape4x3: return "4 : 3"
        case .wide16x9: return "16 : 9"
        case .tall9x16: return "9 : 16"
        case .portrait2x3: return "2 : 3"
        case .landscape3x2: return "3 : 2"
        case .wide18x9: return "18 : 9"
        case .tall9x18: return "9 : 18"
        case .cinema: return "2.39 : 1"
        }
    }
    func value(in size: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return size.width / size.height
        case .square: return 1
        case .portrait3x4: return 3 / 4
        case .landscape4x3: return 4 / 3
        case .wide16x9: return 16 / 9
        case .tall9x16: return 9 / 16
        case .portrait2x3: return 2 / 3
        case .landscape3x2: return 3 / 2
        case .wide18x9: return 18 / 9
        case .tall9x18: return 9 / 18
        case .cinema: return 2.39
        }
    }
}

enum CropHandle: CaseIterable {
    case move, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    var isLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var isRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var isTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var isBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
}

/// Image-pixel geometry, independent of the displayed zoom or SwiftUI gestures.
enum CropGeometry {
    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }
    static func handle(at p: CGPoint, rect r: CGRect, tolerance: CGFloat) -> CropHandle? {
        let corners: [(CGPoint, CropHandle)] = [
            (CGPoint(x: r.minX, y: r.minY), .topLeft), (CGPoint(x: r.maxX, y: r.minY), .topRight),
            (CGPoint(x: r.maxX, y: r.maxY), .bottomRight), (CGPoint(x: r.minX, y: r.maxY), .bottomLeft)
        ]
        if let corner = corners.min(by: { hypot(p.x - $0.0.x, p.y - $0.0.y) < hypot(p.x - $1.0.x, p.y - $1.0.y) }),
           hypot(p.x - corner.0.x, p.y - corner.0.y) <= tolerance { return corner.1 }
        if p.x >= r.minX - tolerance && p.x <= r.maxX + tolerance {
            if abs(p.y - r.minY) <= tolerance { return .top }
            if abs(p.y - r.maxY) <= tolerance { return .bottom }
        }
        if p.y >= r.minY - tolerance && p.y <= r.maxY + tolerance {
            if abs(p.x - r.minX) <= tolerance { return .left }
            if abs(p.x - r.maxX) <= tolerance { return .right }
        }
        return r.contains(p) ? .move : nil
    }
    static func fit(_ rect: CGRect, ratio: CGFloat, in size: CGSize) -> CGRect {
        let area = max(1, rect.width * rect.height)
        var width = sqrt(area * ratio), height = sqrt(area / ratio)
        let scale = min(1, min(size.width / width, size.height / height))
        width *= scale; height *= scale
        return CGRect(x: clamp(rect.midX - width / 2, 0, size.width - width),
                      y: clamp(rect.midY - height / 2, 0, size.height - height), width: width, height: height)
    }
    static func adjust(_ r: CGRect, handle: CropHandle, delta: CGSize, in size: CGSize, ratio: CGFloat?) -> CGRect {
        if handle == .move {
            return CGRect(x: clamp(r.minX + delta.width, 0, size.width - r.width),
                          y: clamp(r.minY + delta.height, 0, size.height - r.height), width: r.width, height: r.height)
        }
        let minimum = min(1, min(r.width, r.height))
        guard let ratio else {
            var left = r.minX, right = r.maxX, top = r.minY, bottom = r.maxY
            if handle.isLeft { left = clamp(r.minX + delta.width, 0, r.maxX - minimum) }
            if handle.isRight { right = clamp(r.maxX + delta.width, r.minX + minimum, size.width) }
            if handle.isTop { top = clamp(r.minY + delta.height, 0, r.maxY - minimum) }
            if handle.isBottom { bottom = clamp(r.maxY + delta.height, r.minY + minimum, size.height) }
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
        let horizontal = handle.isLeft || handle.isRight
        let vertical = handle.isTop || handle.isBottom
        if horizontal && vertical {
            let sx: CGFloat = handle.isRight ? 1 : -1, sy: CGFloat = handle.isBottom ? 1 : -1
            let anchor = CGPoint(x: sx > 0 ? r.minX : r.maxX, y: sy > 0 ? r.minY : r.maxY)
            let maxWidth = sx > 0 ? size.width - anchor.x : anchor.x
            let maxHeight = min(sy > 0 ? size.height - anchor.y : anchor.y, maxWidth / ratio)
            let desired = (ratio * (r.width + sx * delta.width) + r.height + sy * delta.height) / (ratio * ratio + 1)
            let height = clamp(desired, min(maxHeight, max(minimum, minimum / ratio)), maxHeight)
            let width = height * ratio
            return CGRect(x: sx > 0 ? anchor.x : anchor.x - width,
                          y: sy > 0 ? anchor.y : anchor.y - height, width: width, height: height)
        }
        if horizontal {
            let sx: CGFloat = handle.isRight ? 1 : -1, anchor = sx > 0 ? r.minX : r.maxX
            let maxWidth = min(sx > 0 ? size.width - anchor : anchor, 2 * min(r.midY, size.height - r.midY) * ratio)
            let width = clamp(r.width + sx * delta.width, min(maxWidth, max(minimum, minimum * ratio)), maxWidth)
            let height = width / ratio
            return CGRect(x: sx > 0 ? anchor : anchor - width, y: r.midY - height / 2, width: width, height: height)
        }
        let sy: CGFloat = handle.isBottom ? 1 : -1, anchor = sy > 0 ? r.minY : r.maxY
        let maxHeight = min(sy > 0 ? size.height - anchor : anchor, 2 * min(r.midX, size.width - r.midX) / ratio)
        let height = clamp(r.height + sy * delta.height, min(maxHeight, max(minimum, minimum / ratio)), maxHeight)
        let width = height * ratio
        return CGRect(x: r.midX - width / 2, y: sy > 0 ? anchor : anchor - height, width: width, height: height)
    }
    static func pixels(_ rect: CGRect, in size: CGSize) -> CGRect {
        let left = max(0, floor(rect.minX)), top = max(0, floor(rect.minY))
        let right = min(size.width, floor(rect.maxX + 0.000001)), bottom = min(size.height, floor(rect.maxY + 0.000001))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

extension EditorModel {
    var cropImageSize: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    var cropAspectRatio: CGFloat? { cropRatio.value(in: cropImageSize) }
    var cropPixelRect: CGRect? { cropRect.map { CropGeometry.pixels($0, in: cropImageSize) } }
    var canApplyCrop: Bool {
        guard cropping, !busy, let rect = cropPixelRect else { return false }
        let minimum: CGFloat = livePhoto == nil ? 1 : 2
        return rect.width >= minimum && rect.height >= minimum
    }
    func selectCropRatio(_ ratio: CropRatio) {
        guard cropping, !busy, let rect = cropRect else { return }
        cropRatio = ratio
        if let value = cropAspectRatio { cropRect = CropGeometry.fit(rect, ratio: value, in: cropImageSize) }
    }
    func adjustCrop(from rect: CGRect, handle: CropHandle, delta: CGSize) {
        guard cropping, !busy else { return }
        cropRect = CropGeometry.adjust(rect, handle: handle, delta: delta, in: cropImageSize, ratio: cropAspectRatio)
    }
}

struct CropOverlay: View {
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @ObservedObject var model: EditorModel
    let size: CGSize
    let scale: CGFloat
    @State private var dragRect: CGRect?
    @State private var dragHandle: CropHandle?
    var body: some View {
        let _ = languageSettings.language
        Canvas { context, area in
            var mask = Path(CGRect(origin: .zero, size: area))
            if let rect = model.cropRect {
                let r = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                mask.addRect(r)
                context.fill(mask, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                context.stroke(Path(r), with: .color(.white), lineWidth: 1.5)
                var grid = Path()
                for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                    grid.move(to: CGPoint(x: r.minX + r.width * fraction, y: r.minY))
                    grid.addLine(to: CGPoint(x: r.minX + r.width * fraction, y: r.maxY))
                    grid.move(to: CGPoint(x: r.minX, y: r.minY + r.height * fraction))
                    grid.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * fraction))
                }
                context.stroke(grid, with: .color(.white.opacity(0.85)), lineWidth: 1)
                var handles = Path()
                let length = min(14, min(r.width, r.height) / 4)
                for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                                       (r.maxX, r.maxY, -1.0, -1.0), (r.minX, r.maxY, 1.0, -1.0)] {
                    handles.move(to: CGPoint(x: x + sx * length, y: y))
                    handles.addLine(to: CGPoint(x: x, y: y))
                    handles.addLine(to: CGPoint(x: x, y: y + sy * length))
                }
                for y in [r.minY, r.maxY] {
                    handles.move(to: CGPoint(x: r.midX - length / 2, y: y))
                    handles.addLine(to: CGPoint(x: r.midX + length / 2, y: y))
                }
                for x in [r.minX, r.maxX] {
                    handles.move(to: CGPoint(x: x, y: r.midY - length / 2))
                    handles.addLine(to: CGPoint(x: x, y: r.midY + length / 2))
                }
                context.stroke(handles, with: .color(.white), lineWidth: 3)
            } else { context.fill(mask, with: .color(.black.opacity(0.5))) }
        }
        .frame(width: size.width, height: size.height).contentShape(Rectangle())
        .accessibilityLabel(L10n.text("裁剪九宫格选框"))
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard model.cropping, !model.busy, let rect = model.cropRect else { return }
            if dragRect == nil {
                let point = CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale)
                guard let handle = CropGeometry.handle(at: point, rect: rect, tolerance: 10 / scale) else { return }
                dragRect = rect; dragHandle = handle
            }
            if let dragRect, let dragHandle {
                model.adjustCrop(from: dragRect, handle: dragHandle,
                                 delta: CGSize(width: value.translation.width / scale, height: value.translation.height / scale))
            }
        }.onEnded { _ in dragRect = nil; dragHandle = nil })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
            let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
            if model.cropRect?.contains(point) == true { model.commitCrop() }
        })
        .quickHelp(L10n.text("双击选区或按 Enter 应用裁剪；Esc 取消。"))
        .onChange(of: model.cropRatio) { _, _ in dragRect = nil; dragHandle = nil }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                guard let rect = model.cropRect else { return }
                let p = CGPoint(x: point.x / scale, y: point.y / scale)
                switch CropGeometry.handle(at: p, rect: rect, tolerance: 10 / scale) {
                case .move: NSCursor.openHand.set()
                case .left, .right: NSCursor.resizeLeftRight.set()
                case .top, .bottom: NSCursor.resizeUpDown.set()
                case .topLeft, .topRight, .bottomLeft, .bottomRight: NSCursor.crosshair.set()
                case nil: NSCursor.arrow.set()
                }
            case .ended: NSCursor.arrow.set()
            }
        }
        .onDisappear { NSCursor.arrow.set() }
    }
}
