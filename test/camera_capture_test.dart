import 'package:flutter/material.dart';
import 'package:pageflow_reader/scan_crop.dart';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pageflow_reader/camera_capture.dart';

void main() {
  testWidgets('Crop controls fit short windows without overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 260));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bytes = Uint8List.fromList(img.encodeJpg(img.Image(width: 100, height: 200)));
    await tester.pumpWidget(MaterialApp(home: ScanCropPage(bytes: bytes)));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  test(
    'Crop keeps selected pixels and multi-page PDF retains every page',
    () async {
      final source = img.Image(width: 100, height: 80);
      img.fill(source, color: img.ColorRgb8(100, 120, 140));
      final bytes = Uint8List.fromList(img.encodeJpg(source));
      final cropped = await convertCapture({
        'bytes': bytes,
        'format': 'jpeg',
        'turns': 0,
        'scan': false,
        'crop': <double>[.1, .25, .9, .75],
      });
      final image = img.decodeJpg(cropped)!;
      expect(image.width, 80);
      expect(image.height, 40);
      final pdf = await scanPagesPdf([bytes, cropped, bytes]);
      expect(
        RegExp(r'/Type\s*/Page\b').allMatches(String.fromCharCodes(pdf)).length,
        3,
      );
      await expectLater(scanPagesPdf([]), throwsStateError);
      await expectLater(scanPagesPdf(List.filled(21, bytes)), throwsStateError);
    },
  );

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
