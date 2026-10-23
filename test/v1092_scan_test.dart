import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pageflow_reader/camera_capture.dart';
import 'package:pageflow_reader/scan_draft.dart';
import 'package:pageflow_reader/scan_enhance.dart';

Uint8List photo(int value) {
  final image = img.Image(width: 120, height: 80);
  img.fill(image, color: img.ColorRgb8(value, 30, 30));
  return Uint8List.fromList(img.encodeJpg(image));
}

class MemoryStore extends ScanDraftStore {
  MemoryStore(this.pages) : super(Directory.systemTemp);
  List<Map<String, dynamic>> pages;
  @override
  Future<Map<String, dynamic>?> load() async => {
    'pages': pages,
    'selected': pages.length - 1,
  };
  @override
  Future<void> save(List<Map<String, dynamic>> value, int selected) async {
    pages = value;
  }
}

void main() {
  test(
    'Colour cleanup retains stamp colour and monochrome preset removes chroma',
    () {
      final bytes = photo(160);
      Uint8List run(bool mono) => enhanceScan({
        'bytes': bytes,
        'brightness': 1.0,
        'contrast': 1.0,
        'shadows': true,
        'monochrome': mono,
      });
      final colour = img.decodeJpg(run(false))!.getPixel(60, 40);
      final mono = img.decodeJpg(run(true))!.getPixel(60, 40);
      expect(colour.r, greaterThan(colour.g * 2));
      expect((mono.r - mono.g).abs(), lessThanOrEqualTo(2));
      expect((mono.g - mono.b).abs(), lessThanOrEqualTo(2));
    },
  );
  test('Shadow correction has no abrupt jump at the old ink threshold', () {
    final image = img.Image(width: 200, height: 100);
    img.fill(image, color: img.ColorRgb8(75, 75, 75));
    for (var x = 50; x < 150; x++) {
      final v = 20 + (x - 50) * .3;
      for (var y = 40; y < 60; y++) {
        image.setPixelRgb(x, y, v, v, v);
      }
    }
    final result = img.decodeJpg(
      enhanceScan({
        'bytes': Uint8List.fromList(img.encodeJpg(image, quality: 100)),
        'brightness': 1.0,
        'contrast': 1.0,
        'shadows': true,
      }),
    )!;
    for (var x = 60; x < 140; x++) {
      expect(
        (result.getPixel(x + 1, 50).luminance -
                result.getPixel(x, 50).luminance)
            .abs(),
        lessThan(15),
      );
    }
  });
  for (final cancel in [true, false]) {
    testWidgets(
      'Retake ${cancel ? "cancel preserves" : "replaces only"} selected page',
      (tester) async {
        final original = photo(80);
        final store = MemoryStore(
          List.generate(
            2,
            (_) => {
              'original': original,
              'preview': original,
              'scan': false,
              'turns': 0,
            },
          ),
        );
        final root = Directory.systemTemp.createTempSync('sara-retake');
        final file = File('${root.path}/photo.jpg');
        file.writeAsBytesSync(photo(180));
        var captures = 0;
        const channel = MethodChannel('pageflow_reader/incoming');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'requestReaderPermissions') {
              return {'camera': true};
            }
            if (call.method == 'capturePhoto') {
              captures++;
              return cancel ? null : file.path;
            }
            return null;
          },
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: CameraCapturePage(autoCapture: false, store: store),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Retake page'));
          for (var i = 0; i < 100; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await tester.pump();
            if (captures > 0 && (cancel || store.pages.last['clean'] == true)) {
              break;
            }
          }
          await tester.pumpAndSettle();
          expect(captures, 1);
          expect(store.pages.length, 2);
          expect(store.pages.first['original'], original);
          if (cancel) {
            expect(store.pages.last['original'], original);
          } else {
            expect(store.pages.last['original'], isNot(original));
            expect(store.pages.last['clean'], true);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          );
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await root.delete(recursive: true);
          });
        }
      },
    );
  }
}
