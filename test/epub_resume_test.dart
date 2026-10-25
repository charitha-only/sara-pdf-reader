import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/epub_reader.dart';
import 'package:pageflow_reader/reading_state.dart';

import 'support/epub_fixture.dart';

void main() {
  testWidgets(
    'EPUB restores scroll after the chapter view has laid out and persists chapter navigation',
    (tester) async {
      // Keep file writes and their chained continuations in the real async zone.
      await tester.runAsync(() async {
        final root = Directory.systemTemp.createTempSync('sara-epub-resume');
        final file = File('${root.path}/book.epub')
          ..writeAsBytesSync(fixtureEpub());
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => root.path,
        );
        try {
          await ReadingStateStore.save(file.path, {'unit': 1, 'scroll': .5});
          await tester.pumpWidget(
            MaterialApp(
              home: EpubReader(path: file.path, name: 'Resume test'),
            ),
          );
          for (var i = 0; i < 100; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await tester.pump();
            if (find.byType(ListView).evaluate().isNotEmpty) break;
          }
          await tester.pump();
          final scroll = tester
              .widget<ListView>(find.byType(ListView))
              .controller!;
          expect(scroll.offset, greaterThan(0));
          await tester.tap(find.byTooltip('Previous chapter'));
          await tester.pumpAndSettle();
          expect(scroll.offset, 0);
          await tester.pumpWidget(const SizedBox());
          await ReadingStateStore.flush();
          final states = Directory('${root.path}/reader-state')
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'));
          expect(jsonDecode(states.single.readAsStringSync())['unit'], 0);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await ReadingStateStore.flush();
          await root.delete(recursive: true);
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          );
        }
      });
    },
  );
}
