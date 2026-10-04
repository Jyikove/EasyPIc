# EasyPic

轻量原生 macOS 图片查看与编辑器。当前版本 **0.1.1 / 第 1 步 + 动图播放**，要求 macOS 26 或更新。GitHub 仓库名称为 **EasyPIc**，应用名称为 **EasyPic**。

目前已完成基础查看、裁剪、旋转、镜像、PNG/JPG 导出和只读动图播放。按照“先功能、后 UI”的顺序继续开发，下一步是贴纸、图层和可编辑项目保存。完整工作进度见 [PROGRESS.md](PROGRESS.md)，实测记录见 [VALIDATION.md](VALIDATION.md)。

## 运行

先按下文构建，再双击 `build/EasyPic.app`，或在项目目录执行：

```sh
open build/EasyPic.app
```

打开图片、拖入图片，或打开一个文件夹用左右方向键浏览。右侧面板提供裁剪、旋转与镜像。裁剪时拖出选区，点击“应用裁剪”；取消用 Esc。底部提供撤销/重做、缩放和适应窗口；大图可以滚动，触控板捏合可缩放。

GIF、APNG 和动态 WebP 自动按原始帧时长循环播放，右侧可暂停、继续和从头播放。动图只读，不能编辑或导出为静态图；单帧 GIF 也只读。它们仍支持缩放、滚动和文件夹前后浏览。多页 TIFF 是静态文档，目前只查看和编辑首页，不当作动画播放。

| 操作 | 快捷键 |
| --- | --- |
| 打开图片/文件夹 | ⌘O |
| 导出 | ⌘S |
| 撤销 / 重做 | ⌘Z / ⇧⌘Z |
| 右转 / 左转 | ⌘R / ⇧⌘R |
| 开始裁剪 | ⌘K |
| 适应窗口 / 实际像素 | ⌘0 / ⌘1 |
| 上一张 / 下一张 | ← / → |

## 构建和验证

需要包含 macOS 26 SDK 和 Swift 6 工具链的 Apple Command Line Tools；也可使用配套 Xcode。应用无需第三方运行时库。首次下载源码并构建：

```sh
git clone https://github.com/Jyikove/EasyPIc.git
cd EasyPIc
./scripts/build.sh
./scripts/check.sh
```

`check.sh` 运行 13 项独立验证，检查像素结果、裁剪、历史、EXIF、透明度、PNG/JPG 编码以及动画识别、帧时长、帧合成、播放控制和文件切换。测试图片已包含在项目中，不需要安装 Pillow；仅重新生成动画测试图片的脚本 `make-animation-fixtures.py` 需要 Pillow。Command Line Tools 没有 XCTest，所以此项目不使用 `swift test`。

## 当前能力和边界

- 原生 Liquid Glass 控件和面板、系统透材质窗口背景、简洁中性图片画布。
- JPG、PNG、HEIC、TIFF、WebP、BMP、GIF 等 ImageIO 可解码格式；GIF/APNG/动态 WebP 只读播放，多页 TIFF 只处理首页。
- 裁剪、90° 旋转、水平/垂直镜像、撤销/重做。
- 原像素尺寸 PNG/JPG 导出，PNG 保留透明，JPG 填白底并可调质量。
- 原图保留，导出使用新文件名；切图和退出前提醒未导出的修改。
- 静态编辑工作空间为 8-bit sRGB，尚不提供 RAW/HDR/16-bit 专业色彩管理。
- 图片编辑状态目前只保存在运行内存中，退出前需导出。可编辑项目保存安排在第二步。
- 贴纸、文字、擦除、马赛克和 AI 暂未实现；详细设计见 [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)。

构建脚本使用本机临时签名，方便本机运行，尚未做 Developer ID 公证或 App Store 分发。仓库不包含编译后的应用、构建缓存或私人照片；测试图片由脚本生成。
