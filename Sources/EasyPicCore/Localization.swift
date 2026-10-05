import Foundation
import Combine

public enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"
    public var id: String { rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }
    public var name: String { self == .english ? "English" : "中文" }
}

@MainActor
public final class AppLanguageSettings: ObservableObject {
    public static let shared = AppLanguageSettings()
    private let defaults: UserDefaults
    @Published public var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: L10n.preferenceKey)
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: L10n.preferenceKey) ?? "en") ?? .english
    }
    public func prepareSystemLanguage() {
        defaults.set([language.rawValue], forKey: "AppleLanguages")
    }
}

public enum L10n {
    public static let preferenceKey = "EasyPic.language"
    public static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "en") ?? .english
    }
    public static func text(_ key: String, _ arguments: String...) -> String {
        render(key, arguments: arguments, language: language)
    }
    public static func render(_ key: String, arguments: [String] = [], language: AppLanguage) -> String {
        let template = language == .english ? english[key] ?? key : key
        // Substitute once, so braces in filenames or user input are never interpreted.
        var output = "", position = template.startIndex
        while position < template.endIndex {
            if template[position] == "{", let end = template[position...].firstIndex(of: "}"),
               let index = Int(template[template.index(after: position)..<end]), arguments.indices.contains(index) {
                output += arguments[index]; position = template.index(after: end)
            } else {
                output.append(template[position]); position = template.index(after: position)
            }
        }
        return output
    }
    public static func display(_ value: String) -> String {
        if let key = english.first(where: { $0.key == value || $0.value == value })?.key { return text(key) }
        let prefixes = ["已保存项目 · ", "已导出 · ", "Live Photo 已导出 · ", "无法识别文字：", "动图播放失败：", "Live Photo 导出失败："]
        for key in prefixes {
            for prefix in [key, english[key] ?? key] where value.hasPrefix(prefix) {
                return text(key) + String(value.dropFirst(prefix.count))
            }
        }
        return value
    }
    public static func layerName(_ name: String) -> String {
        for key in ["文字", "合并图层", "纯色画笔"] {
            if name == key || name == english[key] { return text(key) }
        }
        if name == "纯色遮盖" { return text("纯色画笔") }
        return name
    }
    static let english: [String: String] = [
        "切换全屏": "Toggle Full Screen",
        "已开启": "On",
        "已关闭": "Off",
        "已设置克隆取样点，拖动开始绘制": "Clone source set. Drag to paint.",
        "请选择一个图片贴纸图层。文字可先导出再作为贴纸导入。": "Select an image sticker layer. Export text as an image first to use it as a sticker.",
        "纯色画笔": "Brush",
        "像素模糊": "Pixel",
        "高斯模糊": "Gaussian",
        "马赛克样式": "Mosaic Style",
        "直径": "Size",
        "按画布缩放预览直径；超大笔刷适配面板显示。": "Size preview follows the canvas zoom. Very large brushes are scaled to fit.",
        "画笔直径预览": "Brush Size Preview",
        "{0} 像素": "{0} pixels",
        "画笔直径": "Brush Size",
        "硬度 {0}%": "Hardness {0}%",
        "透明度 {0}%": "Opacity {0}%",
        "强度 {0}": "Strength {0}",
        "画笔颜色": "Brush Color",
        "矩形选区": "Rectangular Selection",
        "重新取样": "Set New Source",
        "先点击画布设置取样点，再拖动绘制；Option 点击重新取样。": "Click to set the source, then drag to paint. Option-click to set a new source.",
        "选择": "Select ",
        "白色": "White",
        "黑色": "Black",
        "灰色": "Gray",
        "红色": "Red",
        "橙色": "Orange",
        "黄色": "Yellow",
        "绿色": "Green",
        "蓝色": "Blue",
        "紫色": "Purple",
        "粉色": "Pink",
        "亮度": "Brightness",
        "饱和度": "Saturation",
        "透明度": "Opacity",
        "圆形色盘": "Color Wheel",
        "拖动选择颜色；圆心为灰白，边缘色彩更浓。": "Drag to choose a color. Colors become more saturated toward the edge.",
        "自由比例": "Free",
        "原图比例": "Original",
        "裁剪九宫格选框": "Crop Grid",
        "双击选区或按 Enter 应用裁剪；Esc 取消。": "Double-click the selection or press Enter to crop. Press Esc to cancel.",
        "与原图合并": "Merge with Base",
        "向下合并": "Merge Down",
        "可编辑图层 · 原图保留": "Editable layers · Original preserved",
        "请使用 .easypic 项目文件名，保留原始图片。": "Use an .easypic project filename to preserve the source image.",
        "已保存项目 · ": "Project saved · ",
        "项目已打开 · 可继续编辑": "Project opened · Ready to edit",
        "关于 EasyPic": "About EasyPic",
        "关闭窗口": "Close Window",
        "打开图片或文件夹…": "Open Image or Folder…",
        "保存并替换原图": "Save & Replace",
        "替换原图？": "Replace Original?",
        "退出编辑？": "Leave Edit Mode?",
        "不保存": "Don’t Save",
        "保存更改后退出？": "Save your changes before leaving?",
        "将用当前编辑结果替换“{0}”。是否继续？": "Replace “{0}” with the edited image?",
        "保存可编辑项目…": "Save Project…",
        "导出图片…": "Save As…",
        "撤销": "Undo",
        "重做": "Redo",
        "图片": "Image",
        "本地画笔…": "Brush…",
        "添加文字": "Text",
        "添加图片贴纸…": "Import Sticker…",
        "向右旋转 90°": "Rotate Clockwise 90°",
        "向左旋转 90°": "Rotate Counterclockwise 90°",
        "水平镜像": "Flip Horizontal",
        "垂直镜像": "Flip Vertical",
        "将当前帧设为封面": "Set Current Frame as Cover",
        "裁剪": "Crop",
        "应用裁剪": "Apply Crop",
        "取消裁剪": "Cancel Crop",
        "退出画笔": "Exit Brush",
        "适应窗口": "Fit to Window",
        "实际像素": "Actual Size",
        "上一张": "Previous Image",
        "下一张": "Next Image",
        "播放 / 暂停": "Play / Pause",
        "从头播放": "Replay",
        "本地编辑 · 保留原图": "Local editing · Original preserved",
        "选择图片、Live Photo 配套 MOV，或文件夹。Live Photo 原片和视频需在同一文件夹。": "Choose an image, a paired Live Photo MOV, or a folder. Keep the Live Photo image and video in the same folder.",
        "请打开本机图片文件。": "Open an image file on this Mac.",
        "请先应用或取消当前裁剪。": "Apply or cancel the current crop first.",
        " · 裁剪与封面 · 原件保留": " · Crop and cover · Originals preserved",
        "Live Photo 原片 · 缺少配套 MOV，仅可查看": "Live Photo · Paired MOV missing · View only",
        "动图 · 只读播放": "Animation · View only",
        "GIF · 只读查看": "GIF · View only",
        "多页图片 · 当前查看和编辑首页": "Multi-page image · First page only",
        "请使用新的文件名导出，以保留原图。": "Save with a new filename to preserve the original.",
        "已导出 · ": "Saved · ",
        "保存 Live Photo 配对文件夹": "Save Live Photo Pair",
        "会创建新的文件夹，内含配对 JPG 与 MOV，保留动态内容和声音。": "Creates a new folder with a paired JPG and MOV, preserving motion and audio.",
        "Live Photo 已导出 · ": "Live Photo saved · ",
        "当前图片还有未保存的修改": "This image has unsaved changes",
        "保存项目后可继续编辑；也可以导出图片或放弃修改。": "Save a project to keep editing later, save an image, or discard your changes.",
        "保存项目后继续": "Save Project and Continue",
        "导出后继续": "Save Image and Continue",
        "放弃修改": "Discard Changes",
        "取消": "Cancel",
        "重做（取消撤销）": "Redo",
        "逆时针旋转": "Rotate Counterclockwise",
        "添加贴纸": "Sticker",
        "添加文本": "Text",
        "新增文字": "Add Text",
        "贴纸": "Sticker",
        "马赛克画笔": "Mosaic",
        "消除画笔": "Erase",
        "另存为": "Save As",
        "请先输入有效的文字设置。": "Enter valid text settings first.",
        "文字": "Text",
        "编辑工具栏": "Editing Toolbar",
        "收起工具详情": "Close Tool Details",
        "导入贴纸…": "Import Sticker…",
        "裁剪比例": "Crop Ratio",
        "开始裁剪": "Start Crop",
        "编辑当前文字": "Edit Selected Text",
        "预览": "Preview",
        "提取文本": "Extract Text",
        "逆时针旋转 90°": "Rotate Counterclockwise 90°",
        "编辑": "Edit",
        "操作未完成": "Unable to Complete",
        "好": "OK",
        "打开图片": "Open Image",
        "处理中…": "Processing…",
        "按当前图片的完整像素尺寸导出。缩放比例不影响导出质量。": "Saves at full image resolution. Canvas zoom does not affect quality.",
        "格式": "Format",
        "尺寸": "Dimensions",
        "质量": "Quality",
        "透明区域会填充白色背景。": "Transparent areas are filled with white.",
        "无损导出，保留透明区域。": "Lossless output with transparency.",
        "选择保存位置…": "Choose Location…",
        "暂停": "Pause",
        "播放": "Play",
        "静音": "Mute",
        "Live Photo 封面时间": "Live Photo Cover Time",
        "%.2f / %.2f 秒": "%.2f / %.2f s",
        "查看封面": "Show Cover",
        "恢复原始封面": "Restore Original Cover",
        "导出 Live Photo": "Save Live Photo",
        "创建新的配对文件夹，包含 LivePhoto.JPG 和 LivePhoto.MOV。照片与视频同步裁剪，保留声音，并记录所选封面的时间。": "Creates a new folder with LivePhoto.JPG and LivePhoto.MOV. Crops the image and video together, preserves audio, and records the cover time.",
        "可直接在 EasyPic 中重新打开导出的 JPG 或 MOV。向 Apple“照片”导入时，请同时选择这两个文件。": "Reopen the saved JPG or MOV in EasyPic. Select both files when importing into Apple Photos.",
        "MOV 使用 H.264 编码；照片为 JPG。当前输出为 SDR，不保留原始 HEVC/HDR 编码。": "Saves H.264 video and a JPG image in SDR. Original HEVC/HDR encoding is not preserved.",
        "已保存并替换原图": "Saved and replaced the original",
        "合并可见图层": "Merge Visible Layers",
        "合并图层": "Merge Layers",
        "合并为图片，可撤销恢复文字和贴纸；合并可见图层保留隐藏图层与原图。": "Merges into an image. Undo restores text and stickers. Merging visible layers preserves hidden layers and the base image.",
        "编辑文字…": "Edit Text…",
        "中心 X": "Center X",
        "中心 Y": "Center Y",
        "宽度": "Width",
        "高度": "Height",
        "旋转 °": "Rotation °",
        "透明度 %": "Opacity %",
        "置顶": "Bring to Front",
        "置底": "Send to Back",
        "复制": "Duplicate",
        "删除": "Delete",
        "删除图层（可撤销）": "Delete Layer (undoable)",
        "删除图层": "Delete Layer",
        "字体": "Font",
        "预览文字": "Sample Text",
        "选择字体": "Choose Font",
        "字号": "Font Size",
        "粗体": "Bold",
        "斜体": "Italic",
        "文字颜色": "Text Color",
        "对齐": "Alignment",
        "横向左对齐": "Align Left",
        "横向居中对齐": "Align Horizontally Center",
        "横向右对齐": "Align Right",
        "纵向上对齐": "Align Top",
        "纵向居中对齐": "Align Vertically Center",
        "纵向下对齐": "Align Bottom",
        "左 / 起始": "Left / Start",
        "居中": "Center",
        "右 / 末尾": "Right / End",
        "竖排（列从右向左）": "Vertical (right to left)",
        "字距": "Letter Spacing",
        "行距": "Line Spacing",
        "描边颜色": "Stroke Color",
        "描边宽度": "Stroke Width",
        "阴影颜色": "Shadow Color",
        "阴影 X": "Shadow X",
        "阴影 Y": "Shadow Y",
        "阴影模糊": "Shadow Blur",
        "背景颜色": "Background Color",
        "背景内边距": "Background Padding",
        "圆角背景": "Rounded Background",
        "圆角半径 px": "Corner Radius (px)",
        "背景圆角半径": "Background Corner Radius",
        "恢复默认圆角（12 px）": "Reset Corner Radius (12 px)",
        "取消修改": "Cancel Changes",
        "应用文字": "Apply Text",
        "无法识别文字：": "Text recognition failed: ",
        "查看 ": "View ",
        "复制全部文本": "Copy All Text",
        "正在识别…": "Recognizing…",
        "重试": "Retry",
        "未识别到文字": "No Text Found",
        "擦除": "Erase",
        "取样克隆": "Clone",
        "消除": "Retouch",
        "像素马赛克": "Pixel Mosaic",
        "模糊": "Blur",
        "动态 WebP": "Animated WebP",
        "HEIC 序列": "HEIC Sequence",
        "动图播放失败：": "Animation playback failed: ",
        "无法读取这张图片。文件可能损坏，或系统不支持此格式。": "Cannot read this image. The file may be damaged or its format unsupported.",
        "图片处理失败。请尝试较小的图片。": "Image processing failed. Try a smaller image.",
        "裁剪范围过小或超出了图片边界。": "The crop is too small or outside the image.",
        "无法写入导出文件。请检查空间和文件夹权限。": "Cannot save the file. Check available space and folder permissions.",
        "此原图暂不支持直接替换，请另存为 JPG 或 PNG。": "This image cannot be replaced directly. Save as JPG or PNG instead.",
        "请选择可见图层；向下合并时，下方图层也需要可见。": "Select a visible layer. To merge down, the layer below must also be visible.",
        "至少需要两个可见图层才能合并。": "At least two visible layers are required to merge.",
        "未找到标识匹配的 Live Photo 照片与 MOV。请将从“照片”导出的未修改原片和视频放在同一文件夹。": "No matching Live Photo image and MOV were found. Keep the unmodified originals exported from Photos in the same folder.",
        "动态照片的视频无法读取，或时长、尺寸无效。": "Cannot read the motion video, or its duration or dimensions are invalid.",
        "Live Photo 只支持有效范围内的裁剪和封面选择。": "Live Photo only supports valid crops and cover selection.",
        "Live Photo 导出失败：": "Live Photo save failed: ",
        "请选择一个不存在的新文件夹名称，以保留已有文件。": "Choose a new folder name to preserve existing files.",
        "配对标识或封面时间验证失败。": "Pairing identifier or cover time verification failed.",
        "无法保留此视频的声音。": "Cannot preserve this video's audio.",
        "无法创建封面标记。": "Cannot create the cover marker.",
        "无法写入封面标记。": "Cannot write the cover marker.",
        "视频编码未完成。": "Video encoding did not complete.",
        "视频写入中断。": "Video writing was interrupted.",
        "无法写入视频或音频帧。": "Cannot write a video or audio frame.",
        "动态照片播放失败。": "Motion photo playback failed.",
        "双击编辑文字": "Double-click to edit text",
        "语言": "Language",
        "设置": "Settings",
        "设置…": "Settings…",
        "重新启动 EasyPic 后，系统菜单和文件选择窗口也会使用所选语言。": "Restart EasyPic to apply this language to system menus and file dialogs.",
        "界面语言": "Interface Language"
    ]
}
