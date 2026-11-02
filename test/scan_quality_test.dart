import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pageflow_reader/camera_capture.dart';
import 'package:pageflow_reader/scan_enhance.dart';

import 'dart:typed_data';

img.Image receipt() {
  final page = img.Image(width: 480, height: 320);
  for (final p in page) {
    final paper = 85 + 155 * p.x / 479;
    p
      ..r = paper
      ..g = paper
      ..b = paper;
  }
  for (final x in [60, 360]) {
    final paper = 85 + 155 * x / 479;
    img.fillRect(
      page,
      x1: x,
      x2: x + 2,
      y1: 80,
      y2: 180,
      color: img.ColorRgb8(
        (paper * .68).round(),
        (paper * .68).round(),
        (paper * .68).round(),
      ),
    );
  }
  img.fillRect(
    page,
    x1: 200,
    x2: 255,
    y1: 210,
    y2: 260,
    color: img.ColorRgb8(8, 8, 8),
  );
  return page;
}

void main() {
  test('Adaptive B&W retains thin receipt strokes across uneven lighting and solid ink', () {
    final result = enhanceScanImage(receipt(), shadows: true, monochrome: true);
    for (final x in [60, 360]) {
      final ink = result.getPixel(x + 1, 130);
      final paper = result.getPixel(x + 12, 130);
      expect(paper.luminance, greaterThan(225));
      expect(paper.luminance - ink.luminance, greaterThan(85));
      expect(ink.r, ink.g);
      expect(ink.g, ink.b);
    }
    expect(result.getPixel(225, 235).luminance, lessThan(40));
  });

  test('Clean PNG export matches decoded processing without intermediate JPEG damage', () async {
    final original = receipt();
    img.fillRect(
      original,
      x1: 300,
      x2: 340,
      y1: 200,
      y2: 240,
      color: img.ColorRgb8(120, 20, 25),
    );
    final bytes = Uint8List.fromList(img.encodePng(original));
    final expected = enhanceScanImage(img.Image.from(original), shadows: true);
    final result = img.decodePng(
      await convertCapture({
        'bytes': bytes,
        'format': 'png',
        'turns': 0,
        'scan': false,
        'clean': true,
      }),
    )!;
    expect(result.width, original.width);
    for (var y = 0; y < result.height; y += 13) {
      for (var x = 0; x < result.width; x += 11) {
        final a = result.getPixel(x, y), b = expected.getPixel(x, y);
        expect([a.r, a.g, a.b], [b.r, b.g, b.b]);
      }
    }
    expect(
      result.getPixel(320, 220).r,
      greaterThan(result.getPixel(320, 220).g * 2),
    );
  });

  test('B&W handles blank and one-pixel-wide pages without artefacts or division by zero', () {
    for (final dims in [(1, 240), (240, 1), (1, 1)]) {
      final page = img.Image(width: dims.$1, height: dims.$2);
      img.fill(page, color: img.ColorRgb8(180, 180, 180));
      final result = enhanceScanImage(page, monochrome: true);
      expect(result.first.luminance, greaterThan(240));
      expect(result.width, dims.$1);
      expect(result.height, dims.$2);
    }
  });
}
