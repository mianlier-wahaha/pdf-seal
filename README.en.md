# PDF Seal

[简体中文](README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md)

A native macOS app for stamping **electronic seam stamps (骑缝章)** and **body stamps** on PDF files. Built with SwiftUI + PDFKit/CoreGraphics — zero third-party dependencies, fully local processing, no uploads.

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Interface Preview

| Main Window — Stamping | New Seal Dialog |
|---|---|
| ![Main](screenshots/main-stamped.png) | ![New Seal](screenshots/seal-create.png) |

| Launch Screen | |
|---|---|
| ![Launch](screenshots/main-empty.png) | |

## Features

### Seam Stamps (骑缝章)
- Four seam edges: right / left / top / bottom
- Page range: all pages or a custom start–end range
- **Vertical offset**: adjust a seam stamp's position on the edge in real time — place multiple seam stamps without overlap
- Add multiple seam stamp instances; each locks in its own seal, edge, range and offset

### Body Stamps
- Click anywhere on a page to place a stamp; add as many as you need
- Select a stamp to reveal the control frame: drag to move, bottom-right handle to resize
- Every stamp instance **locks in the seal used at creation time** — switching the library selection never affects placed stamps

### Seal Library
- Create seals from PNG / JPG images
- **White-to-transparent** conversion with a live-preview tolerance slider — works with scanned or photographed stamps
- Physical size setting in centimeters, with optional aspect-ratio lock; a seal keeps its real-world size across different paper sizes
- Library persists across launches

### Preview & Files
- Zoom: pinch gesture / text field / presets (25%–200%)
- Page jumping, bottom status bar
- Save (overwrite) / Save As / Close
- `Esc` deselects, `⌘Z` / `Ctrl+Z` undoes the last adjustment

## Requirements

- macOS 13.0+
- Xcode Command Line Tools (`xcode-select --install`)

## Build & Run

```bash
# Run directly
swift run PDFSeal

# Package as .app (also produces zip & dmg in release/)
./scripts/make_app.sh
```

> Note: newer SwiftPM sandboxing may conflict with local machine policies — build with `--disable-sandbox` (the script already does).

## Project Layout

```
Sources/
├── SealCore/    # Stamping engine: seam/body geometry, PDF export, test assets
├── PDFSeal/     # SwiftUI app UI
└── SealTool/    # Headless verification CLI (test PDFs, stamping, rendering)
scripts/         # Packaging scripts (.app / zip / dmg) and icon generator
```

## Technical Notes

- Stamps are composited as native vector content via CoreGraphics — **never rasterized**, so output files stay small and text remains selectable
- Page `/Rotate` handling done right: seam slices follow the displayed orientation on rotated pages
- Uses a "group pages by size → temp PDFs → merge in order with PDFKit" pipeline to work around per-page MediaBox being ignored on macOS 26

## License

[MIT](LICENSE)
