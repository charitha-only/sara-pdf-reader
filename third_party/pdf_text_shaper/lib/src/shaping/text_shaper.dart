import '../font/shaped_font.dart';
import '../model/shaped_run.dart';
import '../model/text_direction.dart';

abstract interface class TextShaper {
  ShapedRun shape(
    String text, {
    required ShapedFont font,
    ShapedTextDirection direction = ShapedTextDirection.auto,
    String? language,
  });
}
