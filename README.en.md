# LongScreenShot

<p align="center">
  <img src="docs/images/app-icon.png" width="128" alt="LongScreenShot App Icon">
</p>

<p align="center">
  <strong>A small macOS menu bar screenshot app, built to feel quick and natural.</strong>
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

## What it is

LongScreenShot is a native macOS screenshot tool that lives in the menu bar. It supports area capture, window detection, annotation, mosaic, pins, OCR, translation, and manually controlled scrolling screenshots.

The goal is not to bury you under options. The app is meant to stay direct: select the right area, annotate quickly, pin when useful, and capture long pages without asking for control of your computer.

---

## Preview

<p align="center">
  <img src="docs/images/preview-capture.png" width="760" alt="Screenshot Preview">
</p>

<p align="center">
  <img src="docs/images/preview-longshot.png" width="760" alt="Long Screenshot Preview">
</p>

---

## Highlights

- Capture: window detection, custom regions, multi-display support, movable and resizable selections.
- Annotation: rectangles, circles, arrows, text, pen, mosaic, undo and redo.
- Pins: keep a screenshot floating on screen; pin windows can be moved and resized.
- OCR and translation: OCR runs locally with Apple Vision; translation can use Baidu or Google.
- Long screenshots: you scroll manually while the app captures, matches, stitches, and shows a live preview.
- Updates: the app can check GitHub Releases automatically or on demand from Settings.

---

## Download

Releases are published on [GitHub Releases](https://github.com/MustangYM/LongScreenShot/releases).

Download the DMG and drag `LongScreenShot.app` into `Applications`.

---

## Permission

macOS requires screen recording permission for screenshot apps:

```text
System Settings → Privacy & Security → Screen & System Audio Recording
```

If capture still does not work after granting permission, quit LongScreenShot completely and open it again.

LongScreenShot does not need Accessibility / Control Your Computer permission. For long screenshots, you scroll the page yourself; the app does not drive the mouse or wheel.

---

## Usage

After launch, LongScreenShot appears in the macOS menu bar. Click the menu bar icon to start capture, or use the global shortcut.

Default shortcut:

```text
⌘⇧2
```

You can record a different shortcut in Settings if it conflicts with another app.

---

## Run from source

```bash
git clone https://github.com/MustangYM/LongScreenShot.git
cd LongScreenShot
open LongScreenShot.xcodeproj
```

You can also build the app with:

```bash
./scripts/build-app.sh
```

Create a DMG with:

```bash
./scripts/package-dmg.sh
```

For distribution, sign and notarize the app with a Developer ID certificate.

---

## Notes

Long screenshots are affected by animations, video regions, transparent layers, repeated textures, and scroll speed. Pages that constantly change are naturally harder to stitch reliably.

If something breaks, please open an issue with your macOS version, the page/app you captured, and the resulting image.

---

## License

Apache License 2.0
