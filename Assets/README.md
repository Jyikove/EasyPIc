# EasyPic 图标

`EasyPicIcon.png` 使用用户在 2026-10-05 提供的蓝色玻璃齿轮图标。外部深蓝背景已移除，保留玻璃底板、齿轮、交叉辐条和中央蓝色图案，输出 1254 × 1254 透明 PNG。

内置 imagegen 多次直接提取仍存在蓝色碎边，经用户明确允许后，最终使用 `scripts/extract-icon.swift` 从原始图按圆角轮廓提取；没有重绘内部图案。`EasyPicIcon-original.png` 保留原始输入，[IconEditingPrompt.md](IconEditingPrompt.md) 记录完整提示词及处理方式。旧图标备份位于 build/IconBackups。

`scripts/make-assets.swift` 用 AppKit 高质量缩放，保留源 PNG 的透明通道和圆角，不再额外裁切。生成标准 macOS iconset 后，构建脚本用 `iconutil` 打包为 `EasyPicIcon.icns`，写入应用资源并通过 Info.plist 和启动时的 applicationIconImage 应用。“关于”窗口直接加载当前图标。
