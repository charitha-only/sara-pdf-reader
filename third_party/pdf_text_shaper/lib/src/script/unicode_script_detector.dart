import 'unicode_script.dart';

abstract final class UnicodeScriptDetector {
  static UnicodeScript ofRune(int rune) {
    if (_between(rune, 0x0041, 0x024F) || _between(rune, 0x1E00, 0x1EFF)) {
      return UnicodeScript.latin;
    }
    if (_between(rune, 0x0980, 0x09FF)) return UnicodeScript.bengali;
    if (_between(rune, 0x0900, 0x097F)) return UnicodeScript.devanagari;
    if (_between(rune, 0x0B80, 0x0BFF)) return UnicodeScript.tamil;
    if (_between(rune, 0x0C00, 0x0C7F)) return UnicodeScript.telugu;
    if (_between(rune, 0x0D00, 0x0D7F)) return UnicodeScript.malayalam;
    if (_between(rune, 0x0C80, 0x0CFF)) return UnicodeScript.kannada;
    if (_between(rune, 0x0A80, 0x0AFF)) return UnicodeScript.gujarati;
    if (_between(rune, 0x0A00, 0x0A7F)) return UnicodeScript.gurmukhi;
    if (_between(rune, 0x0B00, 0x0B7F)) return UnicodeScript.odia;
    if (_between(rune, 0x0D80, 0x0DFF)) return UnicodeScript.sinhala;
    if (_between(rune, 0x0E00, 0x0E7F)) return UnicodeScript.thai;
    if (_between(rune, 0x0E80, 0x0EFF)) return UnicodeScript.lao;
    if (_between(rune, 0x1780, 0x17FF) || _between(rune, 0x19E0, 0x19FF)) {
      return UnicodeScript.khmer;
    }
    if (_between(rune, 0x1000, 0x109F) ||
        _between(rune, 0xA9E0, 0xA9FF) ||
        _between(rune, 0xAA60, 0xAA7F)) {
      return UnicodeScript.myanmar;
    }
    if (_between(rune, 0x0F00, 0x0FFF)) return UnicodeScript.tibetan;
    if (_between(rune, 0x0590, 0x05FF)) return UnicodeScript.hebrew;
    if (_between(rune, 0x0600, 0x06FF) ||
        _between(rune, 0x0750, 0x077F) ||
        _between(rune, 0x08A0, 0x08FF) ||
        _between(rune, 0xFB50, 0xFDFF) ||
        _between(rune, 0xFE70, 0xFEFF)) {
      return UnicodeScript.arabic;
    }

    // Combining Diacritical Marks and join controls inherit their context.
    if (_between(rune, 0x0300, 0x036F) ||
        _between(rune, 0x1AB0, 0x1AFF) ||
        _between(rune, 0x1DC0, 0x1DFF) ||
        rune == 0x200C ||
        rune == 0x200D) {
      return UnicodeScript.inherited;
    }

    if (_isCommon(rune)) return UnicodeScript.common;
    return UnicodeScript.unknown;
  }

  static UnicodeScript firstStrongScript(String text) {
    for (final rune in text.runes) {
      final script = ofRune(rune);
      if (script.isStrong) return script;
    }
    return UnicodeScript.common;
  }

  static bool contains(String text, UnicodeScript script) =>
      text.runes.any((rune) => ofRune(rune) == script);

  static bool _between(int rune, int start, int end) =>
      rune >= start && rune <= end;

  static bool _isCommon(int rune) {
    return rune <= 0x0040 ||
        _between(rune, 0x005B, 0x0060) ||
        _between(rune, 0x007B, 0x00BF) ||
        _between(rune, 0x2000, 0x206F) ||
        _between(rune, 0x20A0, 0x20CF) ||
        _between(rune, 0x2100, 0x214F) ||
        _between(rune, 0x2190, 0x2BFF) ||
        _between(rune, 0x1F000, 0x1FAFF);
  }
}
