import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:harfbuzz_ffi/harfbuzz_ffi_bindings.dart' as hb;

import '../font/shaped_font.dart';
import '../model/shaped_glyph.dart';
import '../model/shaped_run.dart';
import '../model/text_direction.dart';
import 'text_shaper.dart';

final class HarfBuzzShaper implements TextShaper {
  const HarfBuzzShaper();

  @override
  ShapedRun shape(
    String text, {
    required ShapedFont font,
    ShapedTextDirection direction = ShapedTextDirection.auto,
    String? language,
  }) {
    if (text.isEmpty) {
      return ShapedRun(
        sourceText: text,
        font: font,
        glyphs: const <ShapedGlyph>[],
      );
    }

    final utf8Bytes = utf8.encode(text);
    final nativeText = calloc<Uint8>(utf8Bytes.length);
    nativeText.asTypedList(utf8Bytes.length).setAll(0, utf8Bytes);

    final buffer = hb.hb_buffer_create();
    if (buffer == nullptr) {
      calloc.free(nativeText);
      throw StateError('HarfBuzz could not allocate a shaping buffer.');
    }

    try {
      hb.hb_buffer_add_utf8(
        buffer,
        nativeText.cast<Char>(),
        utf8Bytes.length,
        0,
        utf8Bytes.length,
      );

      hb.hb_buffer_guess_segment_properties(buffer);

      if (direction == ShapedTextDirection.leftToRight) {
        hb.hb_buffer_set_direction(buffer, hb.hb_direction_t.HB_DIRECTION_LTR);
      } else if (direction == ShapedTextDirection.rightToLeft) {
        hb.hb_buffer_set_direction(buffer, hb.hb_direction_t.HB_DIRECTION_RTL);
      }

      if (language != null && language.trim().isNotEmpty) {
        final languageBytes = utf8.encode(language);
        final nativeLanguage = calloc<Uint8>(languageBytes.length + 1);
        nativeLanguage.asTypedList(languageBytes.length + 1).setAll(0, <int>[
          ...languageBytes,
          0,
        ]);
        try {
          final hbLanguage = hb.hb_language_from_string(
            nativeLanguage.cast<Char>(),
            languageBytes.length,
          );
          hb.hb_buffer_set_language(buffer, hbLanguage);
        } finally {
          calloc.free(nativeLanguage);
        }
      }

      hb.hb_shape(
        font.harfbuzzFont,
        buffer,
        nullptr.cast<hb.hb_feature_t>(),
        0,
      );

      final length = hb.hb_buffer_get_length(buffer);
      if (length == 0) {
        return ShapedRun(
          sourceText: text,
          font: font,
          glyphs: const <ShapedGlyph>[],
        );
      }

      final infos = hb.hb_buffer_get_glyph_infos(buffer, nullptr);
      final positions = hb.hb_buffer_get_glyph_positions(buffer, nullptr);

      final glyphs = List<ShapedGlyph>.generate(length, (index) {
        final info = infos[index];
        final position = positions[index];

        return ShapedGlyph(
          glyphId: info.codepoint,
          cluster: info.cluster,
          xAdvance: position.x_advance,
          yAdvance: position.y_advance,
          xOffset: position.x_offset,
          yOffset: position.y_offset,
        );
      }, growable: false);

      return ShapedRun(sourceText: text, font: font, glyphs: glyphs);
    } finally {
      hb.hb_buffer_destroy(buffer);
      calloc.free(nativeText);
    }
  }
}
