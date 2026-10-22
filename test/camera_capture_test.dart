import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pageflow_reader/camera_capture.dart';

void main() {
  test(
    'Camera formats preserve orientation, scan output and valid PDF',
    () async {
      final image = img.Image(width: 80, height: 40);
      img.fill(image, color: img.ColorRgb8(160, 80, 40));
      final bytes = Uint8List.fromList(img.encodeJpg(image));
      final png = await convertCapture({
        'bytes': bytes,
        'format': 'png',
        'turns': 1,
        'scan': true,
      });
      final decoded = img.decodePng(png)!;
      expect(decoded.width, 40);
      expect(decoded.height, 80);
      expect(decoded.getPixel(10, 10).r, decoded.getPixel(10, 10).g);
      final jpeg = await convertCapture({
        'bytes': bytes,
        'format': 'jpeg',
        'turns': 0,
        'scan': false,
      });
      expect(img.decodeJpg(jpeg)!.width, 80);
      final pdf = await convertCapture({
        'bytes': bytes,
        'format': 'pdf',
        'turns': 0,
        'scan': false,
      });
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    },
  );
  test('Camera invalid input fails without writing a file', () async {
    await expectLater(
      convertCapture({
        'bytes': Uint8List(3),
        'format': 'png',
        'turns': 0,
        'scan': false,
      }),
      throwsStateError,
    );
  });
}
