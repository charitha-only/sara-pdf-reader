import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:harfbuzz_ffi/harfbuzz_ffi_bindings.dart' as hb;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../model/font_metrics.dart';
import '../rendering/glyph_outline.dart';

final class ShapedFont {
  ShapedFont._({
    required this.name,
    required Uint8List bytes,
    required this.pdfFont,
    required this._blob,
    required this._face,
    required this._hbFont,
    required this.metrics,
  }) : _bytes = Uint8List.fromList(bytes),
       _outlineExtractor = HarfBuzzGlyphOutlineExtractor();

  factory ShapedFont.fromBytes(
    Uint8List bytes, {
    String name = 'Custom Unicode font',
    int faceIndex = 0,
  }) {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'Font bytes cannot be empty.');
    }

    final ownedBytes = Uint8List.fromList(bytes);
    final nativeBytes = calloc<Uint8>(ownedBytes.length);
    nativeBytes.asTypedList(ownedBytes.length).setAll(0, ownedBytes);

    final nullDestroy = nullptr
        .cast<NativeFunction<hb.hb_destroy_func_tFunction>>();

    final blob = hb.hb_blob_create(
      nativeBytes.cast<Char>(),
      ownedBytes.length,
      hb.hb_memory_mode_t.HB_MEMORY_MODE_DUPLICATE,
      nullptr,
      nullDestroy,
    );

    calloc.free(nativeBytes);

    if (blob == nullptr) {
      throw StateError('HarfBuzz could not create a font blob for "$name".');
    }

    final face = hb.hb_face_create(blob, faceIndex);
    if (face == nullptr) {
      hb.hb_blob_destroy(blob);
      throw StateError('HarfBuzz could not create a font face for "$name".');
    }

    final hbFont = hb.hb_font_create(face);
    if (hbFont == nullptr) {
      hb.hb_face_destroy(face);
      hb.hb_blob_destroy(blob);
      throw StateError(
        'HarfBuzz could not create a font instance for "$name".',
      );
    }

    hb.hb_ot_font_set_funcs(hbFont);

    final unitsPerEm = hb.hb_face_get_upem(face);
    if (unitsPerEm <= 0) {
      hb.hb_font_destroy(hbFont);
      hb.hb_face_destroy(face);
      hb.hb_blob_destroy(blob);
      throw StateError('Font "$name" reports an invalid units-per-em value.');
    }

    hb.hb_font_set_scale(hbFont, unitsPerEm, unitsPerEm);

    final extents = calloc<hb.hb_font_extents_t>();
    final hasExtents = hb.hb_font_get_h_extents(hbFont, extents) != 0;
    final metrics = ShapedFontMetrics(
      unitsPerEm: unitsPerEm,
      ascender: hasExtents ? extents.ref.ascender : unitsPerEm,
      descender: hasExtents ? extents.ref.descender : -(unitsPerEm ~/ 4),
      lineGap: hasExtents ? extents.ref.line_gap : 0,
    );
    calloc.free(extents);

    final byteData = ByteData.sublistView(ownedBytes);

    return ShapedFont._(
      name: name,
      bytes: ownedBytes,
      pdfFont: pw.Font.ttf(byteData),
      blob: blob,
      face: face,
      hbFont: hbFont,
      metrics: metrics,
    );
  }

  final String name;
  final Uint8List _bytes;
  final pw.Font pdfFont;
  final Pointer<hb.hb_blob_t> _blob;
  final Pointer<hb.hb_face_t> _face;
  final Pointer<hb.hb_font_t> _hbFont;
  final HarfBuzzGlyphOutlineExtractor _outlineExtractor;
  final ShapedFontMetrics metrics;

  final Map<int, bool> _coverageCache = <int, bool>{};
  bool _disposed = false;

  Uint8List get bytes => Uint8List.fromList(_bytes);

  bool get isDisposed => _disposed;

  bool supportsRune(int rune) {
    _ensureAlive();

    return _coverageCache.putIfAbsent(rune, () {
      final glyph = calloc<hb.hb_codepoint_t>();
      try {
        return hb.hb_font_get_nominal_glyph(_hbFont, rune, glyph) != 0;
      } finally {
        calloc.free(glyph);
      }
    });
  }

  bool supportsText(String text, {bool ignoreWhitespace = true}) {
    return text.runes.every((rune) {
      if (ignoreWhitespace && _isWhitespace(rune)) return true;
      return supportsRune(rune);
    });
  }

  Pointer<hb.hb_font_t> get harfbuzzFont {
    _ensureAlive();
    return _hbFont;
  }

  void paintGlyph(
    PdfGraphics canvas,
    int glyphId, {
    required double originX,
    required double originY,
    required double scale,
  }) {
    _ensureAlive();
    final outline = _outlineExtractor.outline(_hbFont, glyphId);
    if (outline.isEmpty) return;

    for (final command in outline.commands) {
      command.replay(canvas, originX: originX, originY: originY, scale: scale);
    }
    canvas.fillPath();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _outlineExtractor.dispose();
    hb.hb_font_destroy(_hbFont);
    hb.hb_face_destroy(_face);
    hb.hb_blob_destroy(_blob);
    _coverageCache.clear();
  }

  void _ensureAlive() {
    if (_disposed) {
      throw StateError('AnyPdfFont "$name" has already been disposed.');
    }
  }

  static bool _isWhitespace(int rune) =>
      rune == 0x20 ||
      rune == 0x09 ||
      rune == 0x0A ||
      rune == 0x0D ||
      rune == 0x00A0;
}
