import 'package:pdf/pdf.dart';

import '../font/shaped_font.dart';
import 'text_direction.dart';

enum ShapedTextAlign { start, center, end }

final class ShapedTextStyle {
  const ShapedTextStyle({
    required this.font,
    this.fallbackFonts = const <ShapedFont>[],
    this.fontSize = 12,
    this.color = PdfColors.black,
    this.lineHeight,
    this.direction = ShapedTextDirection.auto,
    this.align = ShapedTextAlign.start,
    this.preserveUnicodeText = true,
  }) : assert(fontSize > 0, 'fontSize must be greater than zero.'),
       assert(
         lineHeight == null || lineHeight > 0,
         'lineHeight must be positive.',
       );

  final ShapedFont font;
  final List<ShapedFont> fallbackFonts;
  final double fontSize;
  final PdfColor color;

  /// Multiplier applied to the font's natural line height.
  final double? lineHeight;

  final ShapedTextDirection direction;
  final ShapedTextAlign align;

  /// Emits an invisible Unicode text layer underneath/alongside the shaped
  /// outlines. This keeps copy/search semantics for ordinary Unicode fonts.
  final bool preserveUnicodeText;

  List<ShapedFont> get fonts => <ShapedFont>[font, ...fallbackFonts];

  ShapedTextStyle copyWith({
    ShapedFont? font,
    List<ShapedFont>? fallbackFonts,
    double? fontSize,
    PdfColor? color,
    double? lineHeight,
    ShapedTextDirection? direction,
    ShapedTextAlign? align,
    bool? preserveUnicodeText,
  }) {
    return ShapedTextStyle(
      font: font ?? this.font,
      fallbackFonts: fallbackFonts ?? this.fallbackFonts,
      fontSize: fontSize ?? this.fontSize,
      color: color ?? this.color,
      lineHeight: lineHeight ?? this.lineHeight,
      direction: direction ?? this.direction,
      align: align ?? this.align,
      preserveUnicodeText: preserveUnicodeText ?? this.preserveUnicodeText,
    );
  }
}
