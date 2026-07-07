# LongScreenShot

<p align="center">
  <img src="docs/images/app-icon.png" width="128" alt="LongScreenShot App Icon">
</p>

<p align="center">
  <strong>原生 macOS 菜单栏截图工具，支持普通截图、标注、OCR、图钉与长截图。</strong>
</p>

<p align="center">
  <a href="#中文">中文</a> ·
  <a href="#english">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.0%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-AppKit-orange" alt="Swift AppKit">
  <img src="https://img.shields.io/badge/OCR-Vision-green" alt="Vision OCR">
  <img src="https://img.shields.io/badge/Privacy-Local%20First-lightgrey" alt="Local First">
</p>

---

## 中文

**LongScreenShot** 是一款原生 macOS 菜单栏截图工具，基于 **Swift、AppKit、Vision、ScreenCaptureKit** 和系统框架实现。

它的目标是提供一个轻量、顺手、尽可能原生的截图体验：  
普通截图、窗口识别、自由框选、标注、马赛克、OCR、悬浮图钉和长截图，都可以直接从菜单栏快速启动。

> 当前支持 macOS 14 及以上版本。

---

## 预览

> 建议把截图放到 `docs/images/` 目录，然后替换下面的图片路径。

<p align="center">
  <img src="docs/images/preview-capture.png" width="760" alt="Screenshot Preview">
</p>

<p align="center">
  <img src="docs/images/preview-longshot.png" width="760" alt="Long Screenshot Preview">
</p>

---

## 核心特性

### 截图与选区

- 菜单栏常驻入口
- 可录制全局快捷键，默认 `⌘⇧2`
- 悬停自动识别应用窗口
- 单击选择窗口，拖拽自由框选
- 支持多显示器，按鼠标所在屏幕独立截图
- 截图期间支持全局 `Esc` 紧急退出
- 选区创建后可移动位置
- 支持通过四边与四角手柄精细调整选区大小
- 工具栏自动跟随选区位置

### 标注工具

- 矩形
- 圆圈
- 箭头
- 文字
- 自由画笔
- 马赛克
- 高斯模糊
- 像素化
- 撤销 / 重做
- 支持 `⌘Z` 与 `⌘⇧Z`
- 文字字号、线条粗细、画笔颜色可实时调整
- 工具栏图标带即时悬停说明

### OCR 与图钉

- 使用 Apple Vision 进行离线 OCR
- 截图可作为悬浮图钉固定在屏幕上
- OCR 识别结果可作为附着子窗显示在图钉右侧
- 图钉和 OCR 结果窗支持跨显示器拖动
- 图钉与 OCR 内容窗支持缩放
- 支持一键关闭全部图钉

### 长截图

LongScreenShot 的长截图不是简单拼接静态图片，而是基于连续帧流和位移匹配实现。

- 基于 ScreenCaptureKit 获取连续帧
- 用户手动滚动，不模拟滚轮
- 不需要“控制电脑”权限
- NCC 重叠匹配
- 相邻原始帧位移跟踪
- 实时 minimap 预览
- 使用有界顺序队列保留快速滚动中的中间帧
- 匹配失效后可从下一原始帧重新建立锚点
- 长截图接缝会尝试避开文字行，优先寻找低纹理空白行
- 点击完成时会先排空待处理帧，尽量避免丢失尾部内容

### 设置

- 支持跟随系统语言
- 支持手动选择主流语言
- 支持配置开机启动
- 支持选择翻译引擎
- 内置关于信息
- 翻译引擎可选择百度或谷歌
- 翻译优先在 App 内显示原文 / 译文双栏结果
- 网页接口不可用时自动打开对应翻译网页

---

## 隐私说明

LongScreenShot 尽量使用系统原生能力，并优先在本地完成处理。

- OCR 使用 Apple Vision 本地识别
- 长截图由用户手动滚动
- 不模拟鼠标或滚轮
- 不申请“辅助功能 / 控制电脑”权限
- 截图、OCR 和标注处理均在本机完成

首次使用截图能力时，macOS 会要求授予：

```text
隐私与安全性 → 屏幕与系统音频录制

---

## English

**LongScreenShot** is a native macOS menu bar screenshot tool built with **Swift, AppKit, Vision, ScreenCaptureKit**, and Apple system frameworks.

It aims to provide a lightweight, smooth, and native screenshot experience on macOS.  
Regular screenshots, window detection, free region selection, annotations, mosaic, OCR, floating pins, and long screenshots can all be launched quickly from the menu bar.

> Requires macOS 14 or later.

---

## Preview

> Place screenshots under `docs/images/` and replace the image paths below.

<p align="center">
  <img src="docs/images/preview-capture.png" width="760" alt="Screenshot Preview">
</p>

<p align="center">
  <img src="docs/images/preview-longshot.png" width="760" alt="Long Screenshot Preview">
</p>

---

## Features

### Capture and Selection

- Menu bar entry
- Customizable global shortcut, default: `⌘⇧2`
- Hover to detect application windows
- Click to select a window
- Drag to create a free selection
- Multi-display support based on the screen where the mouse is located
- Global `Esc` emergency exit during capture
- Move the selection after it is created
- Resize the selection using edges and corner handles
- Toolbar automatically follows the selection

### Annotation Tools

- Rectangle
- Circle
- Arrow
- Text
- Freehand brush
- Mosaic
- Gaussian blur
- Pixelation
- Undo / Redo
- Supports `⌘Z` and `⌘⇧Z`
- Realtime adjustment for text size, line width, brush size, and color
- Toolbar icons provide instant hover tooltips

### OCR and Floating Pins

- Offline OCR powered by Apple Vision
- Pin screenshots as floating windows
- OCR results can be displayed as an attached side window
- Floating pins and OCR result windows can be moved across displays
- Pinned image and OCR result windows are resizable
- Close all pins with one action

### Long Screenshot

LongScreenShot does not simply stitch static screenshots.  
It uses continuous frame capture and displacement matching to generate long screenshots.

- Continuous frame stream powered by ScreenCaptureKit
- Manual scrolling by the user
- No simulated scrolling
- No Accessibility permission required
- NCC overlap matching
- Adjacent raw frame displacement tracking
- Realtime minimap preview
- Bounded ordered queue to preserve intermediate frames during fast scrolling
- Re-anchor from the next raw frame after matching failure
- Seam selection tries to avoid cutting through text lines
- Pending frames are drained before final stitching to reduce the chance of losing tail content

### Settings

- Follow system language
- Manually select supported languages
- Launch at login
- Choose translation engine
- Built-in About page
- Baidu or Google translation engine
- Prefer in-app bilingual original / translated result view
- Automatically open the corresponding translation web page when the web interface is unavailable

---

## Privacy

LongScreenShot uses native system capabilities and processes data locally whenever possible.

- OCR is performed locally with Apple Vision
- Long screenshots are created through manual scrolling
- No mouse or wheel simulation
- No Accessibility / Control Computer permission required
- Screenshot, OCR, and annotation processing are performed on device

When using screenshot features for the first time, macOS requires Screen Recording permission:

```text
Privacy & Security → Screen & System Audio Recording