# mPDF

[简体中文](README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md)

A lightweight native macOS PDF toolbox (formerly "PDF Seal") with four sections: **Preview / Stamp / Pages / Edit**. Built with SwiftUI + PDFKit/CoreGraphics — zero third-party dependencies, fully local processing, no uploads.

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

### Seam Stamps (骑缝章)
- Seam edges: right / left
- Page range: all pages or a custom start–end range
- **Vertical offset**: adjust a seam stamp's position on the edge in real time — place multiple seam stamps without overlap
- Add multiple seam stamp instances; each locks in its own seal, edge, range and offset
- **First-page larger**: the first page takes a fixed ratio (default 25%), with an optional **middle-page ratio control** (default 5%)
  - Control on: middle pages each take the fixed ratio; **the last page takes whatever remains and always reaches the right edge of the seal**
  - Control off: first and last pages share the same ratio; middle pages split the remainder evenly
  - When the ratios exceed 100%, multiple seal copies tile automatically along the seam
- **Last-page inset**: the last-page slice is inset toward the page center by 1/3 of the seal width, matching real-world stamping
- Per-page **delete / restore** of seam slices (context menu)
- Adjustable overall opacity

### Body Stamps
- Click anywhere on a page to place a stamp; add as many as you need
- Select a stamp to reveal the control frame: drag to move, bottom-right handle to resize
- **Rotation**: ↺ / ↻ buttons (15° steps, hold ⌥ for 1° fine steps) + a 0–180° slider with live preview
- Every stamp instance **locks in the seal used at creation time** — switching the library selection never affects placed stamps
- Per-page **delete / restore** (context menu)
- `⌘Z` / `Ctrl+Z` undoes the last move / resize

### Watermarks
- Text watermark: content, font, size, color, opacity and rotation
- Tiled mode (repeated across the page) or single placement
- Page-range filter; watermarks render beneath stamps

### Seal Library
- Create seals from PNG / JPG images
- **White-to-transparent** conversion with a live-preview tolerance slider — works with scanned or photographed stamps
- Physical size setting in centimeters, with optional aspect-ratio lock; a seal keeps its real-world size across different paper sizes
- **Drag to reorder** seals, or reorder with ↑ / ↓ keys; library column width adjustable (150–420pt)
- Context-menu rename; library persists across launches

### Merge & Convert ("Tools" menu / workspace hub shortcuts)
- **Merge files**: add multiple / drag in / drag to reorder; page size: keep original or unify (A3/A4/A5/B5/Letter presets or custom W×H in cm, portrait/landscape); the save folder defaults to the first file's directory and can be changed via "Browse…"; applying writes directly without a save panel — duplicate names are auto-suffixed (merged 2, merged 3…)
- **Convert PDF**: blank pages (preset size + orientation + count), from images / clipboard / files, from Word / Excel / PowerPoint (via Office), batch conversion of multiple PDFs; results open in a new tab automatically

### Preview & Files
- Multi-tab workspace: open several PDFs at once; drag tabs to reorder, × to close; unsaved tabs show a dot marker and confirm before closing
- Zoom: pinch gesture / text field / presets (25%–200%)
- Page jumping, bottom status bar
- Save (overwrite) / Save As / Close; large files save in the background with a progress bar
- "More" menu: compress, password encryption, export as images, image-based PDF
- WYSIWYG preview matching exported output (including opacity)
- `Esc` deselects
- UI languages: 简体中文 / 繁體中文 / English

### Page Management
- Grid thumbnail view: click to select, `⌘` / `⇧` multi-select, drag to reorder
- Insert: from file / clipboard image / blank pages, with **interleaved insert** (odd-even positions + reverse order, with a diagram)
- Rotate / delete / extract selected pages; reverse all with one click
- Split: by page count / by file size, with background size estimation in the dialog
- Print (`⌘P`)

### Edit (Annotations)
- **Highlight / underline / strikeout**: on pages with a text layer, **select text** to place annotations line by line (underline incl. wavy style; color and line width match output exactly); on scanned or unreadable pages it automatically falls back to drag-to-draw boxes / lines — hold ⌥ to force free drawing
- **Pen**: freehand drawing with adjustable color / width
- **Shapes**: rectangle / ellipse / line / arrow / double arrow, with border style, line width, fill color and fill pattern
- **Text box**: font / size / color / background color / 90° rotation, live preview while typing; **double-click** a text annotation to edit it in place
- **Redact** (cover-up): optional fill color, flattened automatically on save; optional "same position on every page" to cover all pages at once
- **Eraser**: erase whole strokes or just the touched part (strokes split automatically)
- **Annotation selection**: hovering shows a pointing hand → click to show handles; move, 8-handle resize (rect/ellipse), endpoint dragging (lines/arrows), rotation (text), delete (`Delete` or ✕); handles show direction-aware resize cursors
- **`Shift` modifiers**: hold `Shift` while dragging a corner handle to keep the aspect ratio; hold `Shift` while drawing rectangles / ellipses for squares / circles; press `Esc` mid-draw to discard the gesture
- **Global undo / redo / undo all** (`⌘Z` / `⇧⌘Z`): one unified timeline for annotations, stamps and page operations, effective in every section

## Usage

1. Open a PDF (drag it onto the window / ⌘O / "Choose File" in the workspace)
2. Switch sections at the top: **Preview** to review → **Stamp** for seam/body stamps → **Pages** to organize pages → **Edit** for highlights, shapes, text and redactions
3. Annotations are selected right after drawing — drag / resize / delete as needed; `⌘Z` undoes any step
4. Save or Save As to export (redactions are flattened automatically)

## Download

- [Download from Releases](https://github.com/mianlier-wahaha/pdf-seal/releases/latest) —— `mPDF.dmg` (standard installer image, drag to Applications) or `mPDF.zip` (portable archive), macOS Apple Silicon

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
├── SealCore/    # Stamping engine: seam/body geometry, PDF export, watermarks, test assets
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
