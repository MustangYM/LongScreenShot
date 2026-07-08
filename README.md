# LongScreenShot

<p align="center">
  <img src="docs/images/app-icon.png" width="128" alt="LongScreenShot App Icon">
</p>

<p align="center">
  <strong>一个常驻菜单栏的 macOS 截图工具。轻一点，顺一点，够日常用。</strong>
</p>

<p align="center">
  <a href="./README.md">简体中文</a> ·
  <a href="./README.en.md">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.0%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-AppKit-orange" alt="Swift AppKit">
  <img src="https://img.shields.io/badge/License-Apache--2.0-lightgrey" alt="Apache-2.0">
</p>

---

## 这是什么

LongScreenShot 是我给 macOS 写的截图工具。它从菜单栏启动，支持普通框选截图、窗口识别、标注、马赛克、图钉、OCR、翻译和手动滚动长截图。
简单轻量，杜绝花里胡哨百宝箱。

---

## 预览

<p align="center">
  <img src="docs/images/preview-capture.png" width="760" alt="Screenshot Preview">
</p>

<p align="center">
  <img src="docs/images/preview-longshot.png" width="760" alt="Long Screenshot Preview">
</p>

---

## 主要能力

- 常规截图：窗口识别、自由框选、多显示器、选区移动和缩放。
- 标注：矩形、圆圈、箭头、文字、画笔、马赛克、撤销/重做。
- 图钉：把截图固定在屏幕上，窗口可拖动、可缩放。
- OCR 与翻译：OCR 使用 Apple Vision，本地识别；翻译可选择百度或谷歌。
- 长截图：用户手动滚动，App 负责采集、匹配和拼接，并显示实时预览。
- 历史截图：支持查看历史截图，并自行设置缓存位置与阈值。
- 更新：可在设置中自动检查 GitHub Releases，也可以手动检查更新。

---

## 下载

正式版本会放在 [GitHub Releases](https://github.com/MustangYM/LongScreenShot/releases)。

下载 DMG 后，把 `LongScreenShot.app` 拖到 `Applications` 即可。

---

## 权限

macOS 会要求截图类 App 授予屏幕录制权限：

```text
系统设置 → 隐私与安全性 → 屏幕与系统音频录制
```

授权后如果仍然无法截图，完全退出 LongScreenShot 后重新打开一次。

LongScreenShot 不需要“辅助功能/控制电脑”权限。长截图由你自己滚动页面，App 不会自动操控鼠标或滚轮。

---

## 使用

启动后，LongScreenShot 会出现在菜单栏。你可以点击菜单栏图标开始截图，也可以使用全局快捷键。

默认快捷键：

```text
⌘⇧2
```

如果快捷键冲突，可以在设置里重新录制。

---

## 从源码运行

```bash
git clone https://github.com/MustangYM/LongScreenShot.git
cd LongScreenShot
open LongScreenShot.xcodeproj
```

也可以直接用脚本构建：

```bash
./scripts/build-app.sh
```

生成 DMG：

```bash
./scripts/package-dmg.sh
```

---

## 说明

长截图会受到页面动画、视频、透明层、重复纹理和滚动速度影响。如果页面内容一直在变化，任何拼接方案都会更难稳定。

如果你遇到问题，欢迎在 Issues 里附上系统版本、网页/应用场景和截图结果。

---

## License

Apache License 2.0
