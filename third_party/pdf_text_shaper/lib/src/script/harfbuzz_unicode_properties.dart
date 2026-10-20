import 'package:harfbuzz_ffi/harfbuzz_ffi_bindings.dart' as hb;

final class HarfBuzzScriptProperties {
  const HarfBuzzScriptProperties({
    required this.tag,
    required this.isRightToLeft,
    required this.isCommon,
    required this.isInherited,
    required this.isUnknown,
  });

  final int tag;
  final bool isRightToLeft;
  final bool isCommon;
  final bool isInherited;
  final bool isUnknown;

  bool get isStrong => !isCommon && !isInherited && !isUnknown;
}

/// Unicode script properties backed by HarfBuzz's Unicode database.
///
/// Keeping this internal means the shaping pipeline follows the same Unicode
/// data HarfBuzz uses instead of maintaining a second language/script table.
abstract final class HarfBuzzUnicodeProperties {
  static final _unicodeFunctions = hb.hb_unicode_funcs_get_default();

  static final int _commonTag = _tag('Zyyy');
  static final int _inheritedTag = _tag('Zinh');
  static final int _unknownTag = _tag('Zzzz');

  static HarfBuzzScriptProperties ofRune(int rune) {
    final script = hb.hb_unicode_script(_unicodeFunctions, rune);
    final tag = hb.hb_script_to_iso15924_tag(script);
    final direction = hb.hb_script_get_horizontal_direction(script);

    return HarfBuzzScriptProperties(
      tag: tag,
      isRightToLeft: direction == hb.hb_direction_t.HB_DIRECTION_RTL,
      isCommon: tag == _commonTag,
      isInherited: tag == _inheritedTag,
      isUnknown: tag == _unknownTag,
    );
  }

  static bool firstStrongIsRightToLeft(String text) {
    for (final rune in text.runes) {
      final properties = ofRune(rune);
      if (properties.isStrong) return properties.isRightToLeft;
    }
    return false;
  }

  static int _tag(String value) {
    assert(value.length == 4);
    final units = value.codeUnits;
    return (units[0] << 24) | (units[1] << 16) | (units[2] << 8) | units[3];
  }
}
