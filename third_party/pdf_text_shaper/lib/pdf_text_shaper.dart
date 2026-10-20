/// HarfBuzz-powered complex-script text shaping for `package:pdf`.
///
/// The package renders shaped glyph outlines and can additionally emit an
/// invisible Unicode text layer so generated PDFs remain searchable and
/// copyable.
///
/// Author: AR Rahman
/// GitHub: https://github.com/ardevcraft
library;

export 'src/diagnostics/font_diagnostics.dart';
export 'src/font/shaped_font.dart';
export 'src/model/font_metrics.dart';
export 'src/model/shaped_glyph.dart';
export 'src/model/shaped_run.dart';
export 'src/model/text_direction.dart';
export 'src/model/text_style.dart';
export 'src/script/unicode_script.dart';
export 'src/script/unicode_script_detector.dart';
export 'src/shaping/harfbuzz_shaper.dart';
export 'src/shaping/text_shaper.dart';
export 'src/widgets/shaped_text.dart';
