# 应用图标

`AppIcon-source.png` 是用户选定的 A「原版重绘」方案，保留原始透明通道。
图形参考来自用户本机 `cg_se_3000.exe` 的原版 CG 图标，由内置 image_gen 生成；
本文件为选定生成图的原样副本，未重新生成或修改造型。

构建时 `scripts/build_icon.sh` 使用 macOS `sips` / `iconutil` 生成标准 16–1024 像素表示，
打包为 `Contents/Resources/AppIcon.icns`。应用包图标及窗口内图标共用这份资源。

原生成提示词：

> Use case: identity-preserve / logo-brand. The attached tiny raster is the actual original Windows icon extracted from the classic Cross Gate MMORPG cg_se_3000.exe. Redesign THIS SAME icon into a high-resolution macOS app icon, keeping the recognizable original composition, overlapping classic C and G letterforms, navy/royal-blue accents, light silver-white diamond and angular silhouette. This is a homage requested by an existing player: visual fidelity to the supplied original is the highest priority. Faithfully enlarge and simplify its specific symbol, not a generic new CG corporate logo. Reconstruct the letters and central pale diamond carefully from the reference. Use crisp understated vector-like geometry, only gentle shading, slight 2000s game logo personality. No new motifs or characters. Center the original diamond and CG at a very large readable scale on a soft warm-white macOS rounded-square tile. Tile occupies about 84% of a 1024 square canvas, surrounding background transparent. Very light ambient shadow. No added text beyond the original CG, no labels, no extra small details, no stars, no crystals, no portal, no excessive 3D bevel.
