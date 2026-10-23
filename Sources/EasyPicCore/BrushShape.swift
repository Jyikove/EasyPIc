import Foundation
import CoreGraphics

public enum BrushShape: String, Codable, CaseIterable, Identifiable {
    case freehand, line, arrow, rectangle, ellipse
    public var id: Self { self }
    public var elementTitle: String { self == .freehand ? L10n.text("纯色画笔") : title }
    public var title: String {
        switch self {
        case .freehand: return L10n.text("自由画笔")
        case .line: return L10n.text("直线")
        case .arrow: return L10n.text("箭头")
        case .rectangle: return L10n.text("矩形")
        case .ellipse: return L10n.text("椭圆")
        }
    }
}

/// Shared geometry for the live outline and the committed brush mask.
public enum BrushShapeGeometry {
    public static func path(for stroke: BrushStroke) -> CGPath? {
        guard let shape = stroke.shape, shape != .freehand,
              let start = stroke.points.first, let end = stroke.points.last,
              start != end else { return nil }
        let path = CGMutablePath()
        switch shape {
        case .freehand: return nil
        case .line:
            path.move(to: start); path.addLine(to: end)
        case .arrow:
            let dx = end.x - start.x, dy = end.y - start.y, length = hypot(dx, dy)
            let head = min(length * 0.4, max(12, stroke.diameter * 2.5))
            let ux = dx / length, uy = dy / length
            let center = CGPoint(x: end.x - ux * head, y: end.y - uy * head)
            path.move(to: start); path.addLine(to: end)
            path.move(to: CGPoint(x: center.x - uy * head * 0.55, y: center.y + ux * head * 0.55))
            path.addLine(to: end)
            path.addLine(to: CGPoint(x: center.x + uy * head * 0.55, y: center.y - ux * head * 0.55))
        case .rectangle, .ellipse:
            var dx = end.x - start.x, dy = end.y - start.y
            if shape == .ellipse && stroke.constrainCircle == true {
                let side = min(abs(dx), abs(dy))
                dx = dx < 0 ? -side : side; dy = dy < 0 ? -side : side
            }
            let rect = CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy))
            guard rect.width > 0, rect.height > 0 else { return nil }
            if shape == .rectangle {
                let radius = min(stroke.cornerRadius ?? 0, min(rect.width, rect.height) / 2)
                path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
            } else { path.addEllipse(in: rect) }
        }
        return path
    }
}
