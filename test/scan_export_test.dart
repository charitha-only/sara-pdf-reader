import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pageflow_reader/scan_export.dart';

void main() {
  test(
    'Scan export presets retain orientation and bound compact dimensions',
    () {
      final image = img.Image(width: 2400, height: 1600);
      img.fill(image, color: img.ColorRgb8(200, 200, 200));
      final bytes = Uint8List.fromList(img.encodeJpg(image));
      final compact = prepareScanExport({
        'pages': [bytes],
        'quality': 'compact',
      }).single;
      final high = prepareScanExport({
        'pages': [bytes],
        'quality': 'high',
      }).single;
      expect(img.decodeJpg(compact)!.width, 1400);
      expect(img.decodeJpg(high)!.width, 2400);
      expect(compact.length, lessThan(high.length));
      expect(
        () => prepareScanExport({
          'pages': [bytes],
          'quality': 'invalid',
        }),
        throwsArgumentError,
      );
      expect(
        () => prepareScanExport({'pages': <Uint8List>[], 'quality': 'high'}),
        throwsArgumentError,
      );
    },
  );
  test('Dark and featureless photos give advisory retake guidance', () {
    final image = img.Image(width: 160, height: 100);
    img.fill(image, color: img.ColorRgb8(35, 35, 35));
    final hint = scanQualityHint(Uint8List.fromList(img.encodeJpg(image)));
    expect(hint, contains('Low light'));
    expect(hint, contains('check focus'));
  });
}
