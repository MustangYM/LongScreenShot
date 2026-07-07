# LongScreenShot

<p align="center">
  <img src="docs/images/app-icon.png" width="128" alt="LongScreenShot App Icon">
</p>

<p align="center">
  <strong>A native macOS menu bar screenshot tool with capture, annotation, OCR, pins, and long screenshots.</strong>
</p>

<p align="center">
  <a href="./README.zh-CN.md">简体中文</a> ·
  <a href="./README.md">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.0%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-AppKit-orange" alt="Swift AppKit">
  <img src="https://img.shields.io/badge/OCR-Vision-green" alt="Vision OCR">
  <img src="https://img.shields.io/badge/Privacy-Local%20First-lightgrey" alt="Local First">
</p>

---

## Introduction

**LongScreenShot** is a native macOS menu bar screenshot tool built with **Swift**, **AppKit**, **Vision**, **ScreenCaptureKit**, and other system frameworks.

It is designed for a lightweight and natural screenshot workflow on macOS. From the menu bar, you can quickly start normal captures, select windows, draw custom regions, annotate screenshots, apply mosaic effects, run OCR, pin images on screen, and create long screenshots.

LongScreenShot focuses on a simple native experience: fast to launch, easy to control, local-first, and careful about requesting unnecessary permissions.

> LongScreenShot currently supports **macOS 14.0 and later**.

---

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

- Always available from the macOS menu bar
- Global hotkey recording, with `⌘⇧2` as the default shortcut
- Automatic window detection on hover
- Click to capture a window, or drag to create a custom selection
- Multi-display support, with capture based on the screen under the cursor
- Global `Esc` support to cancel capture immediately
- Move the selection after it is created
- Resize the selection precisely with edge and corner handles
- Floating toolbar that follows the current selection

### Annotation Tools

- Rectangle, ellipse, arrow, and text
- Freehand brush
- Mosaic, Gaussian blur, and pixelation
- Undo and redo
- `⌘Z` and `⌘⇧Z` shortcuts
- Real-time adjustment for font size, stroke width, and brush color
- Toolbar icons with instant hover hints

### OCR, Translation, and Pins

- Local OCR powered by Apple Vision
- OCR results can be displayed inside the app
- Baidu and Google translation engines are supported
- Translation results are shown in a side-by-side original / translated layout when available
- If the web interface is unavailable, the app can open the corresponding translation page automatically
- Screenshots can be pinned as floating image windows
- OCR results can be attached as a child window next to a pinned image
- Pins and OCR windows can be dragged across displays
- Pins and OCR windows can be resized
- Close all pins with one action

### Long Screenshots

LongScreenShot does not simply stitch a few static images together. Its long screenshot workflow is based on a continuous frame stream and displacement matching.

- Continuous frame capture powered by ScreenCaptureKit
- Manual scrolling by the user
- No simulated mouse wheel events
- No Accessibility / Control Your Computer permission required
- NCC-based overlap matching between adjacent frames
- Displacement tracking between raw frames
- Real-time minimap preview for progress feedback
- Bounded ordered queue to preserve intermediate frames during fast scrolling
- Ability to rebuild the anchor from the next raw frame after matching failure
- Seam selection tries to avoid text rows and prefers low-texture blank areas
- Pending frames are drained before finishing to reduce missing content at the end

### Settings

- Follow system language
- Manually select common languages
- Configure launch at login
- Select translation engine
- Built-in About view

---

## Privacy and Permissions

LongScreenShot uses native macOS capabilities whenever possible and keeps processing local first.

- OCR is performed locally with Apple Vision
- Screenshot, annotation, pin, and long screenshot processing are handled on the device
- Long screenshots are created through manual scrolling
- The app does not simulate mouse movement or wheel events
- The app does not request Accessibility / Control Your Computer permission

When using screenshot features for the first time, macOS will ask you to grant:

```text
System Settings → Privacy & Security → Screen & System Audio Recording
```

This is a system-level permission required by macOS for screen capture, screen recording, and ScreenCaptureKit.

---

## Run from Source

1. Clone the repository:

```bash
git clone https://github.com/MustangYM/LongScreenShot.git
cd LongScreenShot
```

2. Open the `.xcodeproj` or `.xcworkspace` file in Xcode.
3. Select the macOS app target for LongScreenShot.
4. Click Run.
5. When prompted, grant the Screen & System Audio Recording permission.

If screen capture still does not work after granting permission, quit the app completely and launch it again.

---

## Usage

After launch, LongScreenShot lives in the macOS menu bar.

You can use the menu bar icon to start screenshot capture, create long screenshots, open settings, close pins, and access other actions. You can also use the recorded global hotkey to start capture quickly.

Default shortcut:

```text
⌘⇧2
```

If this shortcut conflicts with another app, you can record a different one in Settings.

---

## Use Cases

- Daily screenshots and quick annotation
- Capturing long web pages, documents, or chat records
- Pinning temporary images, text, codes, or references on screen
- Extracting text from screenshots with local OCR
- Quickly translating text recognized from screenshots
- Organizing captures and pins across multiple displays

---

## Notes

LongScreenShot is still being improved. Long screenshot quality may be affected by page content, scroll speed, animations, transparent layers, video regions, and repeated textures.

If stitching is inaccurate, try scrolling more slowly or avoiding areas with heavy dynamic content.
