# EasyPic 图标

`EasyPicIcon.png` 基于用户在 2026-10-04 最后上传并指定的玻璃眼睛图片，通过内置 imagegen 编辑为透明圆角版本。提示词要点：保留眼睛图案与玻璃边缘，去除圆角外背景，不添加文字或新背景。

`scripts/make-assets.swift` 用 AppKit 缩放并统一裁切透明圆角，生成标准 macOS iconset，构建脚本用 `iconutil` 打包为 `EasyPicIcon.icns`，写入应用资源并通过 Info.plist 和启动时的 applicationIconImage 应用。“关于”窗口直接加载当前图标，避免使用旧的系统图标缓存。

早先尝试的去边框透明版本已被用户最后上传的图片替代，不作为当前应用图标。
