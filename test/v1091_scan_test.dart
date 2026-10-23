import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pageflow_reader/add_document_menu.dart';
import 'package:pageflow_reader/scan_enhance.dart';
import 'package:pageflow_reader/scan_draft.dart';

void main() {
  testWidgets(
    'Add menu waits for a choice and routes each source independently',
    (tester) async {
      for (final item in {
        'Documents': 'documents',
        'Images': 'images',
        'Camera / scan': 'camera',
        'Gallery photos → scan': 'gallery',
        'Resume saved scan': 'resume',
      }.entries) {
        String? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Add'),
                  onPressed: () async {
                    selected = await showModalBottomSheet<String>(
                      context: context,
                      builder: (_) => const AddDocumentMenu(),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(selected, isNull);
        await tester.tap(find.text(item.key));
        await tester.pumpAndSettle();
        expect(selected, item.value);
      }
    },
  );
  test('Deep paper shadow is reduced without whitening lettering or removing stamp colour', () {
    final image = img.Image(width: 500, height: 300);
    for (final p in image) {
      final v = 65 + p.x * 175 / 499;
      p
        ..r = v
        ..g = v
        ..b = v;
    }
    img.fillRect(
      image,
      x1: 60,
      y1: 100,
      x2: 68,
      y2: 180,
      color: img.ColorRgb8(6, 6, 6),
    );
    img.fillRect(
      image,
      x1: 250,
      y1: 110,
      x2: 260,
      y2: 170,
      color: img.ColorRgb8(100, 15, 15),
    );
    final result = img.decodeJpg(
      enhanceScan({
        'bytes': Uint8List.fromList(img.encodeJpg(image, quality: 100)),
        'brightness': 1.0,
        'contrast': 1.0,
        'shadows': true,
      }),
    )!;
    expect(result.getPixel(30, 30).luminance, greaterThan(180));
    expect(result.getPixel(64, 140).luminance, lessThan(45));
    expect(
      result.getPixel(255, 140).r,
      greaterThan(result.getPixel(255, 140).g * 2),
    );
    expect(result.width, 500);
    expect(result.height, 300);
  });
  test(
    'Thin images stay valid and oversized headers are rejected before decoding',
    () {
      final thin = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 2400, height: 1)),
      );
      expect(
        img
            .decodeJpg(
              enhanceScan({
                'bytes': thin,
                'brightness': 1.0,
                'contrast': 1.0,
                'shadows': true,
              }),
            )!
            .height,
        1,
      );
      final wide = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 2401, height: 1)),
      );
      expect(
        () => enhanceScan({
          'bytes': wide,
          'brightness': 1.0,
          'contrast': 1.0,
          'shadows': true,
        }),
        throwsArgumentError,
      );
    },
  );
  test(
    'Automatic cleanup selection and original survive draft restart',
    () async {
      final root = await Directory.systemTemp.createTemp('sara-clean-test');
      try {
        final store = ScanDraftStore(root);
        final original = Uint8List.fromList([1, 2, 3]);
        final preview = Uint8List.fromList([4, 5, 6]);
        await store.save([
          {
            'original': original,
            'preview': preview,
            'scan': false,
            'turns': 1,
            'clean': true,
          },
        ], 0);
        final record =
            ((await ScanDraftStore(root).load())!['pages'] as List).single
                as Map;
        expect(record['clean'], true);
        expect(record['original'], original);
        expect(record['preview'], preview);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
