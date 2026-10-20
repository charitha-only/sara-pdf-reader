final class ShapedFontMetrics {
  const ShapedFontMetrics({
    required this.unitsPerEm,
    required this.ascender,
    required this.descender,
    required this.lineGap,
  });

  final int unitsPerEm;
  final int ascender;
  final int descender;
  final int lineGap;

  double scaleFor(double fontSize) => fontSize / unitsPerEm;

  double lineHeightFor(double fontSize) {
    final raw = (ascender - descender + lineGap) * scaleFor(fontSize);
    return raw > 0 ? raw : fontSize * 1.2;
  }

  double ascentFor(double fontSize) => ascender * scaleFor(fontSize);
}
