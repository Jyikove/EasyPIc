import EasyPicCore

enum BrushConfigurationGroup: Hashable {
    case brush, mosaic, erase, clone, alphaErase
    init(_ tool: BrushTool) {
        switch tool {
        case .solid: self = .brush
        case .pixelate, .blur: self = .mosaic
        case .repair: self = .erase
        case .clone: self = .clone
        case .eraser: self = .alphaErase
        }
    }
}

struct BrushConfiguration {
    var size = 40.0
    var hardness = 1.0
    var opacity = 1.0
    var strength = 16.0
    var color = TextColor(1, 0, 0)
    var rectangularSelection = false
    var shape = BrushShape.freehand
    var cornerRadius = 12.0
    var circle = false
}

extension EditorModel {
    private var currentBrushConfiguration: BrushConfiguration {
        get {
            let group = BrushConfigurationGroup(brushTool)
            return brushConfigurations[group] ?? BrushConfiguration(size: group == .brush ? 20 : 40)
        }
        set { brushConfigurations[BrushConfigurationGroup(brushTool)] = newValue }
    }
    var brushSize: Double {
        get { currentBrushConfiguration.size }
        set { currentBrushConfiguration.size = newValue }
    }
    var brushHardness: Double {
        get { currentBrushConfiguration.hardness }
        set { currentBrushConfiguration.hardness = newValue }
    }
    var brushOpacity: Double {
        get { currentBrushConfiguration.opacity }
        set { currentBrushConfiguration.opacity = newValue }
    }
    var brushStrength: Double {
        get { currentBrushConfiguration.strength }
        set { currentBrushConfiguration.strength = newValue }
    }
    var brushColor: TextColor {
        get { currentBrushConfiguration.color }
        set { currentBrushConfiguration.color = newValue }
    }
    var brushRectangle: Bool {
        get { currentBrushConfiguration.rectangularSelection }
        set { currentBrushConfiguration.rectangularSelection = newValue }
    }
    var brushShape: BrushShape {
        get { currentBrushConfiguration.shape }
        set { currentBrushConfiguration.shape = newValue }
    }
    var brushCornerRadius: Double {
        get { currentBrushConfiguration.cornerRadius }
        set { currentBrushConfiguration.cornerRadius = newValue }
    }
    var brushCircle: Bool {
        get { currentBrushConfiguration.circle }
        set { currentBrushConfiguration.circle = newValue }
    }
}
