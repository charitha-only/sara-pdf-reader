import '../font/shaped_font.dart';

final class ShapedFontDiagnostics {
  const ShapedFontDiagnostics(this.font);

  final ShapedFont font;

  Set<int> missingCodePoints(String text) {
    return <int>{
      for (final rune in text.runes)
        if (!_isIgnorable(rune) && !font.supportsRune(rune)) rune,
    };
  }

  bool supports(String text) => missingCodePoints(text).isEmpty;

  String report(String text) {
    final missing = missingCodePoints(text);
    if (missing.isEmpty) {
      return '${font.name}: all required code points are supported.';
    }

    final values = missing
        .map(
          (rune) => 'U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}',
        )
        .join(', ');

    return '${font.name}: missing ${missing.length} code point(s): $values';
  }

  static bool _isIgnorable(int rune) =>
      rune == 0x09 ||
      rune == 0x0A ||
      rune == 0x0D ||
      rune == 0x20 ||
      rune == 0x00A0;
}
