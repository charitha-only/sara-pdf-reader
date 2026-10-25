import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

List<Uint8List> prepareScanExport(Map<String, dynamic> args) {
  final pages = (args['pages'] as List).cast<Uint8List>();
  final quality = args['quality'] as String;
  if (!const ['compact', 'balanced', 'high'].contains(quality) ||
      pages.isEmpty ||
      pages.length > 20 ||
      pages.fold<int>(0, (n, p) => n + p.length) > 60 * 1024 * 1024) {
    throw ArgumentError('Invalid scan export');
  }
  final edge = quality == 'compact'
      ? 1400
      : quality == 'balanced'
      ? 2000
      : 2400;
  final jpegQuality = quality == 'compact'
      ? 76
      : quality == 'balanced'
      ? 86
      : 94;
  return pages.map((bytes) {
    final info = img.JpegDecoder().startDecode(bytes);
    if (info == null || info.width > 2400 || info.height > 2400) {
      throw ArgumentError('Invalid scan page');
    }
    var image = img.decodeJpg(bytes)!;
    if (math.max(image.width, image.height) > edge) {
      image = img.copyResize(
        image,
        width: image.width >= image.height ? edge : null,
        height: image.height > image.width ? edge : null,
        interpolation: img.Interpolation.average,
      );
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: jpegQuality));
  }).toList();
}

/// Advisory only: blank pages and dark surrounds can also trigger these hints.
String scanQualityHint(Uint8List bytes) {
  final decoded = img.decodeJpg(bytes);
  if (decoded == null) return 'Check the photo before saving.';
  final scale = math.min(1.0, 320 / math.max(decoded.width, decoded.height));
  final image = img.copyResize(
    decoded,
    width: math.max(1, (decoded.width * scale).round()),
    height: math.max(1, (decoded.height * scale).round()),
  );
  var dark = 0, n = 0;
  double sum = 0, squares = 0;
  for (final p in image) {
    if (p.luminance < 70) dark++;
  }
  for (var y = 1; y < image.height - 1; y++) {
    for (var x = 1; x < image.width - 1; x++) {
      final lap =
          4 * image.getPixel(x, y).luminance -
          image.getPixel(x - 1, y).luminance -
          image.getPixel(x + 1, y).luminance -
          image.getPixel(x, y - 1).luminance -
          image.getPixel(x, y + 1).luminance;
      sum += lap;
      squares += lap * lap;
      n++;
    }
  }
  final hints = <String>[];
  if (dark > image.width * image.height * .35) {
    hints.add('Low light or dark surround: add even light or crop the page.');
  }
  if (n == 0 || squares / n - (sum / n) * (sum / n) < 35) {
    hints.add('Few sharp edges: check focus and retake if text looks blurred.');
  }
  return hints.join(' ');
}
