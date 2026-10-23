import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pageflow_reader/scan_enhance.dart';
import 'package:pageflow_reader/library_names.dart';
import 'package:pageflow_reader/reading_state.dart';

void main() {
  Uint8List fixture() {
    final image = img.Image(width: 400, height: 200);
    for (final p in image) {
      final level = 100 + p.x * 130 / 399;
      p
        ..r = level
        ..g = level
        ..b = level;
    }
    img.fillRect(
      image,
      x1: 80,
      y1: 80,
      x2: 120,
      y2: 120,
      color: img.ColorRgb8(10, 10, 10),
    );
    return Uint8List.fromList(img.encodeJpg(image, quality: 100));
  }

  test('Cleanup reduces uneven lighting while retaining dark content and image dimensions', () {
    final before = img.decodeJpg(fixture())!;
    final after = img.decodeJpg(
      enhanceScan({
        'bytes': fixture(),
        'brightness': 1.0,
        'contrast': 1.0,
        'shadows': true,
      }),
    )!;
    expect(after.width, 400);
    expect(after.height, 200);
    final originalDifference =
        (before.getPixel(30, 30).luminance - before.getPixel(370, 30).luminance)
            .abs();
    final cleanedDifference =
        (after.getPixel(30, 30).luminance - after.getPixel(370, 30).luminance)
            .abs();
    expect(cleanedDifference, lessThan(originalDifference * .5));
    expect(after.getPixel(100, 100).luminance, lessThan(40));
    expect(
      () => enhanceScan({
        'bytes': fixture(),
        'brightness': double.nan,
        'contrast': 1.0,
        'shadows': false,
      }),
      throwsArgumentError,
    );
  });
  test('Bulk names preserve extensions, avoid existing names and reject unsafe prefixes', () {
    expect(
      bulkLibraryNames(
        ['one.pdf', 'two.XLSX'],
        'Invoice',
        usedNames: {'invoice 1.pdf'},
      ),
      ['Invoice 2.pdf', 'Invoice 3.XLSX'],
    );
    expect(
      () => bulkLibraryNames(['a.pdf'], '../private'),
      throwsArgumentError,
    );
    expect(() => bulkLibraryNames(['a.pdf'], ''), throwsArgumentError);
  });
  test('PDF view rotation and fit survive metadata sanitization', () {
    final result = ReadingStateStore.sanitize({
      'unit': 4,
      'viewTurns': 999,
      'mode': 'page',
    });
    expect(result['unit'], 4);
    expect(result['viewTurns'], 3);
    expect(result['mode'], 'page');
  });
  testWidgets('Image cleanup fits short phone windows', (tester) async {
    tester.view.physicalSize = const Size(320, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: ScanAdjustPage(bytes: fixture())),
    );
    await tester.pump();
    expect(find.text('Image cleanup'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
