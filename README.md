---

## English

**LongScreenShot** is a native macOS menu bar screenshot tool built with **Swift, AppKit, Vision, ScreenCaptureKit**, and Apple system frameworks.

It aims to provide a lightweight, smooth, and native screenshot experience on macOS.  
Regular screenshots, window detection, free region selection, annotations, mosaic, OCR, floating pins, and long screenshots can all be launched quickly from the menu bar.

> Requires macOS 14 or later.

---

<p align="center">
  <a href="./README.md">English</a>
  <a href="./README.zh-CN.md">简体中文</a> ·
</p>

## Preview

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