import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:pageflow_reader/camera_capture.dart';
import 'package:image/image.dart' as img;
import 'package:pageflow_reader/scan_draft.dart';
import 'package:pageflow_reader/scan_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Uint8List jpeg(int value) {
    final image = img.Image(width: 80, height: 100);
    img.fill(image, color: img.ColorRgb8(value, value, value));
    return Uint8List.fromList(img.encodeJpg(image));
  }

  Map<String, dynamic> page(int value) => {
    'original': jpeg(value),
    'preview': jpeg(value),
    'turns': 1,
    'scan': true,
  };
  test('Draft survives reopen and corrupt primary falls back without losing prior snapshot', () async {
    final root = await Directory.systemTemp.createTemp('sara-draft-');
    addTearDown(() => root.delete(recursive: true));
    final store = ScanDraftStore(root);
    await store.save([page(60)], 0);
    await store.save([page(100), page(140)], 1);
    final reopened = await ScanDraftStore(root).load();
    expect((reopened!['pages'] as List).length, 2);
    expect(reopened['selected'], 1);
    await File('${root.path}/draft.json').writeAsString('broken');
    final recovered = await store.load();
    expect((recovered!['pages'] as List).length, 1);
    expect((recovered['pages'] as List).first['turns'], 1);
    await store.save([page(200)], 0);
    await File('${root.path}/draft.json').writeAsString('broken again');
    expect(((await store.load())!['pages'] as List).length, 1);
    final manifest = jsonDecode(
      await File('${root.path}/draft.json.bak').readAsString(),
    ) as Map;
    final imageName = (manifest['pages'] as List).first['original'];
    await File('${root.path}/$imageName').writeAsBytes([1, 2, 3]);
    await store.save([page(60)], 0);
    expect(
      ((await store.load())!['pages'] as List).single['preview'],
      jpeg(60),
    );
  });
  test('Save/clear ordering is serialized across store instances', () async {
    final root = await Directory.systemTemp.createTemp('sara-draft-');
    addTearDown(() => root.delete(recursive: true));
    final first = ScanDraftStore(root), second = ScanDraftStore(root);
    final saved = first.save([page(50)], 0);
    final cleared = second.clear();
    final latest = first.save([page(210)], 0);
    await Future.wait([saved, cleared, latest]);
    final result = await second.load();
    expect((result!['pages'] as List).length, 1);
    expect((result['pages'] as List).first['preview'], jpeg(210));
  });
  test(
    'Bright page corners are suggested and ambiguous images are rejected',
    () {
      final image = img.Image(width: 400, height: 400);
      img.fill(image, color: img.ColorRgb8(20, 20, 20));
      img.fillRect(
        image,
        x1: 70,
        y1: 40,
        x2: 330,
        y2: 360,
        color: img.ColorRgb8(245, 245, 245),
      );
      final result = suggestScanCorners(
        Uint8List.fromList(img.encodeJpg(image)),
      )!;
      expect(result[0], closeTo(.175, .025));
      expect(result[1], closeTo(.1, .025));
      expect(result[4], closeTo(.825, .025));
      expect(suggestScanCorners(jpeg(255)), isNull);
      expect(validScanCorners([0, 0, 1, 1, 1, 0, 0, 1]), isFalse);
    },
  );
  test('Projective correction keeps rectangular image proportions and rejects crossed corners', () {
    final bytes = jpeg(200);
    final output = rectifyScan({
      'bytes': bytes,
      'corners': <double>[0, 0, 1, 0, 1, 1, 0, 1],
    });
    final image = img.decodeJpg(output)!;
    expect(image.width, 80);
    expect(image.height, 100);
    expect(
      () => rectifyScan({
        'bytes': bytes,
        'corners': <double>[0, 0, 1, 1, 1, 0, 0, 1],
      }),
      throwsArgumentError,
    );
  });
  test('Rejected draft save preserves the prior valid snapshot', () async {
    final root = await Directory.systemTemp.createTemp('sara-draft-');
    addTearDown(() => root.delete(recursive: true));
    final store = ScanDraftStore(root);
    await store.save([page(80)], 0);
    await expectLater(
      store.save(List.generate(21, (_) => page(90)), 0),
      throwsFormatException,
    );
    await expectLater(store.save([page(90)], 3), throwsFormatException);
    expect((await store.load())!['selected'], 0);
    expect(
      ((await store.load())!['pages'] as List).single['preview'],
      jpeg(80),
    );
  });
  test('Perspective correction maps a trapezoid diagonal intersection to page center', () {
    final source = img.Image(width: 401, height: 401);
    img.fill(source, color: img.ColorRgb8(20, 20, 20));
    img.fillRect(
      source,
      x1: 190,
      y1: 153,
      x2: 210,
      y2: 173,
      color: img.ColorRgb8(240, 20, 240),
    );
    final result = img.decodeJpg(
      rectifyScan({
        'bytes': Uint8List.fromList(img.encodeJpg(source, quality: 100)),
        'corners': <double>[.25, .1, .75, .1, .9, .9, .1, .9],
      }),
    )!;
    final pixel = result.getPixel(result.width ~/ 2, result.height ~/ 2);
    expect(pixel.r, greaterThan(200));
    expect(pixel.g, lessThan(60));
    expect(pixel.b, greaterThan(200));
  });
  testWidgets('Restored scan pages can be reordered, deleted and reopened', (
    tester,
  ) async {
    final store = _MemoryDraftStore([page(70), page(200)], 1);
    await tester.pumpWidget(
      MaterialApp(home: CameraCapturePage(autoCapture: false, store: store)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Page 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Move page earlier'));
    await tester.pumpAndSettle();
    expect(store.selected, 0);
    expect(store.pages.first['preview'], jpeg(200));
    await tester.tap(find.byTooltip('Delete selected page'));
    await tester.pumpAndSettle();
    expect(store.pages.length, 1);
    expect(store.pages.single['preview'], jpeg(70));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(home: CameraCapturePage(autoCapture: false, store: store)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Page 1'), findsOneWidget);
    expect(find.text('Page 2'), findsNothing);
    expect(find.text('Restored your saved scan draft.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _MemoryDraftStore extends ScanDraftStore {
  _MemoryDraftStore(this.pages, this.selected) : super(Directory.systemTemp);
  List<Map<String, dynamic>> pages;
  int selected;
  @override
  Future<Map<String, dynamic>?> load() async => {
    'pages': pages,
    'selected': selected,
  };
  @override
  Future<void> save(List<Map<String, dynamic>> value, int index) async {
    pages = value;
    selected = index;
  }
}
