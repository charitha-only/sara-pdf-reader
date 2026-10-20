import '../font/shaped_font.dart';
import 'shaped_glyph.dart';

final class ShapedRun {
  const ShapedRun({
    required this.sourceText,
    required this.font,
    required this.glyphs,
  });

  final String sourceText;
  final ShapedFont font;
  final List<ShapedGlyph> glyphs;

  int get signedAdvance =>
      glyphs.fold<int>(0, (sum, glyph) => sum + glyph.xAdvance);

  int get advance => signedAdvance.abs();

  bool get isEmpty => glyphs.isEmpty;
}
