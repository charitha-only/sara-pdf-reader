import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

class PermanentPdfRedaction {
  /// Rebuilds a fresh document from rendered pixels. No original text streams,
  /// annotations, attachments or document metadata enter the output.
  static Future<Uint8List> create(
    Uint8List bytes,
    Map<int, List<Rect>> normalizedAreas, {
    void Function(int, int)? progress,
  }) async {
    if (normalizedAreas.isEmpty) {
      throw ArgumentError('Select at least one redaction area.');
    }
    await pdfrx.pdfrxFlutterInitialize();
    final source = await pdfrx.PdfDocument.openData(bytes);
    final output = pw.Document(title: 'Redacted PDF', creator: 'Pageflow');
    try {
      if (source.pages.length > 200) {
        throw ArgumentError(
          'Redact documents of up to 200 pages per operation.',
        );
      }
      if (normalizedAreas.keys.any((p) => p < 1 || p > source.pages.length)) {
        throw RangeError('Invalid redaction page.');
      }
      for (var i = 0; i < source.pages.length; i++) {
        final page = source.pages[i];
        final scale = (1800 / page.width).clamp(1.0, 3.0);
        final rendered = await page.render(
          fullWidth: (page.width * scale).roundToDouble(),
          fullHeight: (page.height * scale).roundToDouble(),
        );
        if (rendered == null) {
          throw StateError('Could not render page ${i + 1} for redaction.');
        }
        try {
          final bitmap = img.Image.fromBytes(
            width: rendered.width,
            height: rendered.height,
            bytes: rendered.pixels.buffer,
            bytesOffset: rendered.pixels.offsetInBytes,
            numChannels: 4,
            order: img.ChannelOrder.bgra,
          );
          for (final rect in normalizedAreas[i + 1] ?? const <Rect>[]) {
            if (![
                  rect.left,
                  rect.top,
                  rect.right,
                  rect.bottom,
                ].every((v) => v.isFinite) ||
                rect.isEmpty ||
                rect.left < 0 ||
                rect.top < 0 ||
                rect.right > 1 ||
                rect.bottom > 1) {
              throw ArgumentError('Select an area inside the page.');
            }
            img.fillRect(
              bitmap,
              x1: (rect.left * bitmap.width).floor(),
              y1: (rect.top * bitmap.height).floor(),
              x2: (rect.right * bitmap.width).ceil() - 1,
              y2: (rect.bottom * bitmap.height).ceil() - 1,
              color: img.ColorRgb8(0, 0, 0),
            );
          }
          final image = pw.MemoryImage(img.encodeJpg(bitmap, quality: 98));
          output.addPage(
            pw.Page(
              pageFormat: PdfPageFormat(page.width, page.height),
              margin: pw.EdgeInsets.zero,
              build: (_) => pw.Image(image, fit: pw.BoxFit.fill),
            ),
          );
        } finally {
          rendered.dispose();
        }
        progress?.call(i + 1, source.pages.length);
      }
      return await output.save();
    } finally {
      await source.dispose();
    }
  }
}
