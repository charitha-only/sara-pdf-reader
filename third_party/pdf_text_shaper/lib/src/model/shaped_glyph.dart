final class ShapedGlyph {
  const ShapedGlyph({
    required this.glyphId,
    required this.cluster,
    required this.xAdvance,
    required this.yAdvance,
    required this.xOffset,
    required this.yOffset,
  });

  final int glyphId;
  final int cluster;
  final int xAdvance;
  final int yAdvance;
  final int xOffset;
  final int yOffset;
}
