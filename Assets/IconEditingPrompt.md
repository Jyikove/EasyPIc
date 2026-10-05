# EasyPic 图标透明处理记录

使用内置 image_gen（非 CLI 模式），输入为用户于 2026-10-05 提供的 EasyPicIcon.png。五次处理均存在蓝色碎边，未采用；随后用户明确答复“允许，使用本地蒙版清理”。最终由 scripts/extract-icon.swift 直接从原始图提取平滑圆角轮廓，保留内部图案及色彩，不使用 AI 中间图。输出为 Assets/EasyPicIcon.png，1254 × 1254，含透明通道；原始输入保存为 Assets/EasyPicIcon-original.png，候选图位于 build/IconInputs。

第一步提示词：

```text
Use case: background-extraction.
Asset type: EasyPic macOS application icon, transparent PNG.
Input image: edit target is the attached EasyPicIcon.png, the square blue glass tile with a pale icy gear and crossed spokes around a glossy blue central hub.
Primary request: remove ONLY the surrounding navy/blue background outside the rounded square glass tile. Preserve the ENTIRE rounded blue glass tile, the gear, diagonal crossed spokes, blue center, all original colors, gradients, geometry, highlights and edge reflections unchanged. This is a precise background cutout, not a redesign or reinterpretation.
Composition: one centered square icon with narrow even transparent margins, all four rounded corners fully visible, no cropping of the tile or edges, suitable for a macOS app icon.
Output: real transparent alpha outside the tile; keep the tile interior intact. No new background, no checkerboard baked into pixels, no added objects, no text, no added shadows or external glow. Preserve fine antialiased edges and the source artwork.
```

第二步清理提示词：

```text
Use case: background-extraction, cleanup pass.
Edit target: the supplied partially extracted transparent EasyPic app icon. Keep the entire rounded-square blue glass tile and its central white gear/cross/blue hub pixel-perfect unchanged.
Single change: CLEAN THE ALPHA MATTE OUTSIDE THE TILE. There are unwanted floating blue/cyan/white pixel specks above, below and beside the icon. Remove ALL disconnected pixels and ALL background residue outside the actual smooth rounded-square boundary. All margins and corner cutouts must be completely transparent, alpha 0. Remove the irregular external cyan/blue fringes, preserve the tile's legitimate thin bright reflective edge and smooth antialiased boundary.
Preserve original canvas size, position, tile shape, artwork, colors, all interior pixels, geometry, original reflections and highlights. Do not regenerate/repaint the icon. Do not add a background, external halo, cast shadow, checkerboard or new content. Output a clean transparent PNG ready for an application icon.
```

第三步轮廓清理提示词（重新使用原始图片）：

```text
Use case: background-extraction. Input: edit the supplied EasyPic icon. Remove the navy rectangle outside the rounded blue glass square. Produce a polished transparent PNG cutout with a geometrically smooth continuous rounded square silhouette, not a color-key cutout. The icon silhouette follows the glass tile (roughly x 60 to 1194, y 50 to 1166 in the 1254-square source). Reconstruct/clean the outermost few pixels as needed to make the boundary perfectly smooth, including corner arcs; the entire exterior must be truly alpha zero. Do not preserve any external glow, blue/cyan fringe, scattered flecks, shadow, or the original dark rectangular backdrop. Preserve the glass square inside, icy white gear with four diagonal crossed spokes, blue center hub, highlights, gradients, composition and colors as closely as possible. Keep the original proportions and rounded corner shape, center on transparent square canvas with even margins. Single opaque rounded-square object on transparency. Crisp smooth edge, no speckled alpha, no extra objects, no new text.
```

第四步白底中间图提示词：

```text
Edit this exact image. Replace ONLY the dark navy background outside the blue rounded-square glass icon with solid pure white (#FFFFFF). The outer rectangular backdrop and all external shadows/glow must become clean white. Keep the complete blue glass tile, its smooth rounded boundary, white gear/crossed spokes and blue center hub intact. This is a background replacement for an icon cutout: smooth exact rounded-square edge, no leftover blue/cyan flecks outside it. Preserve the inside of the tile closely, its original colors and detail. Do not turn the blue interior white, do not remove the blue glass tile. Canvas same square proportions, white margins all around, no new objects, text or patterns.
```

第五步从白底中间图提取透明背景提示词：

```text
Use case: background-extraction. The supplied edit target is an EasyPic app icon on PURE WHITE outside the blue rounded-square tile. Remove ONLY the solid white exterior backdrop to real transparent alpha. Preserve the entire blue rounded glass square, icy white gear, diagonal crossed spokes, blue center hub, interior gradients, highlights, thin blue/purple border, artwork and composition exactly. White within the gear or glass is part of the foreground and must remain opaque. Background is only the white connected to the canvas edges. Maintain clean smooth rounded-square silhouette, antialiasing, no white halo, no scattered pixels, no extra shadows or glow. Square transparent PNG ready for a macOS icon. Keep canvas size and position.
```
