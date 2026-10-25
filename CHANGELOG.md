## v1.10

- Camera captures open page-corner review before cleanup. Apply perspective correction or go back to keep the full photo. The Review page edges chip can turn this step off.
- Advisory low-light/dark-surround and weak-edge/focus hints help you decide whether to retake. These are heuristic hints, not a guarantee that a page is blurry or readable.
- High quality (2400 px/JPEG 94), Balanced size (2000 px/JPEG 86), and Small file (1400 px/JPEG 76) export choices control PDF/JPEG size. PNG exports use the chosen resolution. Upscaling is never used; earlier capture detail cannot be recovered.
- Searchable OCR and print use the same prepared page images as the PDF, preserving alignment. Existing selected-page retake, original comparison, cleanup and draft recovery remain available.

## v1.09.4

- EPUB reading position is restored after the actual chapter list has laid out, instead of before the asynchronous book view exists. Chapter navigation resets and saves the new chapter position after layout.
- Office zoom choices wait until the viewer is ready, catch failures, and update the displayed scale only after a successful change. The fit menu uses the same guarded path as zoom buttons.
- Includes the v1.09.3 logo animation and all previous scanning/reader features.

## v1.09.3

- Replace Get Started with an automatic 1.8-second logo animation.
- Animate the existing cap and stars independently, honour reduced motion, and skip animation for external document launches.
- Keep first-time permission/default-reader setup and previous scan/reader features.

## v1.09.2

- Retake only the selected scan page; cancelled retakes retain the existing page.
- Clean-colour/black-and-white cleanup presets and original comparison.
- Faster background estimation and smooth illumination/ink transitions.

## v1.09.1

- Add-source menu with separate document/image opening.
- Automatic offline camera shadow cleanup with recoverable original comparison and saved per-page selection.
- Bounded illumination estimation and scan input validation.

# v1.09

Scan brightness/contrast/shadow cleanup, saved PDF view rotation and fit, bulk display-name renaming, accessible header controls, bounded spreadsheet/merged-cell rendering and native import queue limits. See release-notes/v1.09.md.

# v1.08

Android printing for PDF/images/scans and Office previews, welcome label visibility fix, print-specific layout and stricter local viewer navigation. See release-notes/v1.08.md.

# v1.07

Office zoom/pan and Excel print-range previews; recoverable scan drafts; reviewed page-edge suggestions and perspective correction; searchable offline OCR PDF export; multi-photo Gallery imports. Physical-phone validation remains pending. See release-notes/v1.07.md.

# v1.06

First-open Android Camera/Photos permission requests, partial photo-access status, settings/retry controls and denial-safe camera capture.

# v1.05

Manual scan page crop and multi-page PDF capture/export, per-page selection, ordering and deletion.

# v1.04

Camera capture and PNG/JPEG/PDF save/share, scan contrast, Office zoom/pan controls and first-open reader/access guidance. See release-notes/v1.04.md for limits.

# Changelog

## v1.03 — 2026-10-21

- EPUB chapter/text/image reading, book appearance and resume support.
- Read-only offline Sinhala/English OCR search/copy for scanned PDFs.
- PDF contents navigation and internal document links.
- Sinhala Office font fallbacks, Word endnotes, common Excel chart/conditional-format previews and cell navigation.
- Virtual library folders/tags and persistent folder filtering.
- Full screen, orientation and keep-screen-on controls across readers.
- Corrupt-index recovery snapshot, bounded image memory and OCR cache cleanup.
- Android build 8, retaining signing identity and version-specific downloads.

See [v1.03 release notes](release-notes/v1.03.md) for supported scope and verification.

## v1.02 — 2026-10-21

- Eight reader improvements: Office fit/search, Android incoming files, PDF search, reading positions, library browsing, cancellable imports, memory/loading polish, and release links.
- New cyan/pink Sara launcher and splash logo, with PNG download.
- Android build 7; same publisher certificate and application ID for updates.
- Smaller ARM64/ARMv7 downloads and universal APK retained.

See [v1.02 release notes](release-notes/v1.02.md) for verification and limits.

## v1.01 — 2026-10-21

- First public GitHub APK release under the Sara PDF Reader name.
- Visible app version v1.01, Android build 6 (Flutter 1.0.1+6).
- Offline PDF, Office, text and image reader; editing deferred.
- Version-specific signed APK and checksum, update notes and download links.
- Added smaller ARM64 (53.8 MB) and ARMv7 (47.7 MB) APK downloads with the same
  reader features and offline resources; universal APK retained.

See [release notes](release-notes/v1.01.md) for supported scope and limitations.
