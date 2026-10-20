import 'dart:typed_data';

/// Document formats this package knows about.
enum DocumentFormat {
  /// Rendered natively by PDFium. Never uses the WebView bridge.
  pdf(
    extensions: <String>['pdf'],
    fidelity: FidelityLevel.full,
    family: FormatFamily.pdf,
  ),

  /// Word, rendered by the bundled `docx-preview` engine.
  docx(
    extensions: <String>['docx', 'docm'],
    fidelity: FidelityLevel.high,
    family: FormatFamily.word,
    ooxmlMainPart: 'word/document.xml',
  ),

  /// Excel, rendered by SheetJS plus this package's own style layer.
  ///
  /// SheetJS Community Edition reads cell fills but not borders, fonts or
  /// alignment; the package parses `xl/styles.xml` itself to fill that gap.
  xlsx(
    extensions: <String>['xlsx', 'xlsm'],
    fidelity: FidelityLevel.high,
    family: FormatFamily.excel,
    ooxmlMainPart: 'xl/workbook.xml',
  ),

  /// PowerPoint, rendered by the bundled `PPTXjs` engine.
  pptx(
    extensions: <String>['pptx', 'pptm'],
    fidelity: FidelityLevel.high,
    family: FormatFamily.powerPoint,
    ooxmlMainPart: 'ppt/presentation.xml',
  ),

  /// Legacy binary Excel. Values only — the old format carries no style data
  /// the engine can read.
  xls(
    extensions: <String>['xls'],
    fidelity: FidelityLevel.partial,
    family: FormatFamily.excel,
  ),

  /// Comma/tab separated values.
  csv(
    extensions: <String>['csv', 'tsv'],
    fidelity: FidelityLevel.full,
    family: FormatFamily.excel,
  ),

  /// Rich Text Format. Text and basic formatting.
  rtf(
    extensions: <String>['rtf'],
    fidelity: FidelityLevel.partial,
    family: FormatFamily.word,
  ),

  /// Legacy binary Word. Text extraction only.
  doc(
    extensions: <String>['doc'],
    fidelity: FidelityLevel.textOnly,
    family: FormatFamily.word,
  ),

  /// Legacy binary PowerPoint. Text extraction only.
  ppt(
    extensions: <String>['ppt'],
    fidelity: FidelityLevel.textOnly,
    family: FormatFamily.powerPoint,
  );

  const DocumentFormat({
    required this.extensions,
    required this.fidelity,
    required this.family,
    this.ooxmlMainPart,
  });

  /// Associated file extensions, lowercase and without the dot.
  final List<String> extensions;

  /// How faithful the rendered result is to the original.
  ///
  /// Worth surfacing in your UI — users should know when they are looking at
  /// an approximation.
  final FidelityLevel fidelity;

  /// Grouping and badge colour hint.
  final FormatFamily family;

  /// For OOXML formats, the zip entry that must be present. `null` otherwise.
  final String? ooxmlMainPart;

  /// Whether this is a zip-based Office Open XML format.
  bool get isOoxml => ooxmlMainPart != null;

  /// Whether this is a legacy binary (OLE compound file) format.
  bool get isLegacyBinary =>
      this == DocumentFormat.doc ||
      this == DocumentFormat.ppt ||
      this == DocumentFormat.xls;
}

/// How faithful a rendered document is to the original.
enum FidelityLevel {
  /// Pixel-accurate; the original layout engine is being used.
  full,

  /// Layout, styling and images preserved, with known gaps.
  high,

  /// Content correct, styling partial.
  partial,

  /// Text only; page layout is not preserved.
  textOnly,
}

/// Broad family a format belongs to.
enum FormatFamily {
  /// Portable Document Format.
  pdf,

  /// Word processing documents.
  word,

  /// Spreadsheets.
  excel,

  /// Presentations.
  powerPoint,

  /// Plain text and anything without a richer family.
  plain,
}

/// Identifies a document from its bytes.
///
/// **The extension is not trusted.** Detection goes magic bytes → OOXML main
/// part → extension, and content always wins over the file name.
abstract final class FormatDetector {
  static const List<int> _zip = <int>[0x50, 0x4b];
  static const List<int> _ole = <int>[
    0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, //
  ];
  static const List<int> _pdf = <int>[0x25, 0x50, 0x44, 0x46]; // %PDF
  static const List<int> _rtf = <int>[0x7b, 0x5c, 0x72, 0x74, 0x66]; // {\rtf

  /// Physical container type, from the leading bytes.
  static ContainerKind containerOf(Uint8List head) {
    if (_matches(head, _pdf)) {
      return ContainerKind.pdf;
    }
    if (_matches(head, _rtf)) {
      return ContainerKind.rtf;
    }
    if (_matches(head, _ole)) {
      return ContainerKind.ole;
    }
    if (_matches(head, _zip)) {
      return ContainerKind.zip;
    }
    return ContainerKind.unknown;
  }

  /// Best guess from the file name. Only consulted when the content is
  /// ambiguous, such as CSV which has no signature.
  static DocumentFormat? fromExtension(String fileName) {
    final int dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) {
      return null;
    }
    final String ext = fileName.substring(dot + 1).toLowerCase();
    for (final DocumentFormat format in DocumentFormat.values) {
      if (format.extensions.contains(ext)) {
        return format;
      }
    }
    return null;
  }

  /// Resolves an OOXML format from the names of the zip entries.
  static DocumentFormat? fromOoxmlParts(Set<String> entryNames) {
    for (final DocumentFormat format in DocumentFormat.values) {
      final String? main = format.ooxmlMainPart;
      if (main != null && entryNames.contains(main)) {
        return format;
      }
    }
    return null;
  }

  /// Resolves a legacy binary format from OLE stream names.
  static DocumentFormat? fromOleStreams(Set<String> streamNames) {
    if (streamNames.contains('WordDocument')) {
      return DocumentFormat.doc;
    }
    if (streamNames.contains('PowerPoint Document')) {
      return DocumentFormat.ppt;
    }
    if (streamNames.contains('Workbook') || streamNames.contains('Book')) {
      return DocumentFormat.xls;
    }
    return null;
  }

  static bool _matches(Uint8List data, List<int> magic) {
    if (data.length < magic.length) {
      return false;
    }
    for (int i = 0; i < magic.length; i++) {
      if (data[i] != magic[i]) {
        return false;
      }
    }
    return true;
  }
}

/// The physical container a document is stored in.
enum ContainerKind {
  /// Zip archive — every Office Open XML format.
  zip,

  /// OLE compound file — legacy binary formats, and encrypted OOXML.
  ole,

  /// PDF.
  pdf,

  /// Rich Text Format.
  rtf,

  /// No recognised signature.
  unknown,
}
