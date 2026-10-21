Upstream: https://github.com/huseyiniriss/offline_document_viewer
Pinned commit: 8904c7bb93ebdc5265476febdd2344bb46a97326 (0.1.0)

Pageflow changes:
- Android WebView keeps its actual viewport and platform identity while loading.
- Navigation policy is explicitly enabled; remote document references remain blocked.
- Embedded font data/blob URLs are allowed, while remote font requests stay blocked.
- Office preview cache uses a completion marker and 200 MB pruning.
- Word rendering waits for bundled fonts before fitting its page.
- Legacy DOC Android preview uses Apache POI 5.5.1 HWPF to preserve tables, run
  styling, margins and inline images, rather than a text-only fallback.
  It does not promise Word's pagination or floating-object layout.

The original MIT license and all bundled engine/font notices are retained.

Additional layout fixes:
- Preserve the legacy Word body's classes, page width, anchored textbox story
  content (MS-DOC PlcftxbxTxt/FTXBXS), and floating/centered table placement.
- Render DOCX VML textboxes as selectable HTML rather than clipping SVG foreignObjects.
- Honor centered floating DOCX tables and explicit horizontal anchors.
- Fit and refit Word pages without changing their authored width or accumulating
  scaling on rotation; remove unscaled layout space from the scroll extent.
- Defer controller status notifications until the first frame has finished.

Sara v1.02 reader changes:
- Cache preparation shares in-flight work without a self-referential future.
- Stable document sources preserve WebView state across reader toolbar updates.
- Fonts/images settle before page measurement; fit/original-size modes and viewport restoration.
- Workbook-wide search, active result navigation and cell highlights after sheet changes.
- Viewport/search index bridge events for reading-position persistence and next/previous controls.
- Archive preflight runs in an isolate; cancellation unmounts the preview and retry starts a fresh renderer.
