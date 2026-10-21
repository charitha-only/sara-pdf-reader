import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:offline_document_viewer/offline_document_viewer.dart';
import 'package:pageflow_reader/office_viewer.dart';
import 'package:pageflow_reader/text_file_editor.dart';
import 'package:pageflow_reader/reading_state.dart';
import 'package:pageflow_reader/main.dart' as app;
import 'package:pdfrx/pdfrx.dart';

import '../test/support/pdf_fixture.dart';
import 'generated_reader_fixtures.dart';

Future<void> until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 160 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();
  }
  expect(done(), isTrue);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Office fit, cross-sheet Sinhala/English search and reading position survive reopen',
    (tester) async {
      final dir = await getTemporaryDirectory();
      for (final entry in generatedFixtures.entries) {
        final file = await File('${dir.path}/${entry.key}')
            .writeAsBytes(base64Decode(entry.value));
        await tester.pumpWidget(
          MaterialApp(
            home: OfficeViewer(path: file.path, name: entry.key),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        final view = tester.widget<DocumentView>(find.byType(DocumentView));
        await until(
          tester,
          () =>
              view.controller!.status == DocumentViewStatus.ready ||
              view.controller!.status == DocumentViewStatus.failed,
        );
        expect(view.controller!.failure, isNull);
        await view.controller!.setViewMode('actual');
        await tester.pump(const Duration(milliseconds: 500));
        if (entry.key.endsWith('.xlsx')) {
          expect(view.controller!.info!.unitCount, greaterThanOrEqualTo(2));
          final lastSheet = view.controller!.info!.unitCount - 1;
          await view.controller!.search('INVOICE unique');
          await until(tester, () => view.controller!.searchHits > 0);
          await view.controller!.moveSearch(1);
          await until(tester, () => view.controller!.position == lastSheet);
          await view.controller!.search('සිංහල');
          await until(tester, () => view.controller!.searchHits > 0);
          await view.controller!.moveSearch(1);
          await tester.pump(const Duration(seconds: 1));
          final saved = await ReadingStateStore.load(file.path);
          expect(saved['unit'], lastSheet);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pumpWidget(
            MaterialApp(
              home: OfficeViewer(path: file.path, name: entry.key),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          final reopened = tester.widget<DocumentView>(
            find.byType(DocumentView),
          );
          await until(tester, () => reopened.controller!.position == lastSheet);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 500));
      }
    },
  );
  testWidgets(
    'Text resume and highlighted Sinhala search keep the source read-only',
    (tester) async {
      final dir = await getTemporaryDirectory();
      final text = List.generate(
        500,
        (i) => 'Line $i Sinhala සිංහල',
      ).join('\n');
      final file = await File('${dir.path}/resume-reader.txt')
          .writeAsString(text);
      await tester.pumpWidget(
        MaterialApp(
          home: TextFileEditor(
            directory: dir,
            path: file.path,
            displayName: 'resume-reader.txt',
            readOnly: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      field.scrollController!.jumpTo(
        field.scrollController!.position.maxScrollExtent * .6,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        (await ReadingStateStore.load(file.path))['scroll'],
        greaterThan(.5),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpWidget(
        MaterialApp(
          home: TextFileEditor(directory: dir, path: file.path, readOnly: true),
        ),
      );
      await tester.pumpAndSettle();
      final reopened = tester.widget<TextField>(find.byType(TextField));
      expect(reopened.scrollController!.offset, greaterThan(0));
      await tester.tap(find.byTooltip('Find in text'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'සිංහල');
      await tester.tap(find.text('Find'));
      await tester.pumpAndSettle();
      expect(reopened.controller!.selection.isCollapsed, isFalse);
      expect(await file.readAsString(), text);
    },
  );
  testWidgets('PDF native search counts matches and next/previous navigation', (
    tester,
  ) async {
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/pdfs',
    );
    await dir.create(recursive: true);
    final file = await File('${dir.path}/reader-search.pdf')
        .writeAsBytes(fixturePdf());
    final index = File('${dir.path}/documents.json');
    await index.writeAsString(
      jsonEncode([
        {
          'name': 'reader-search.pdf',
          'kind': 'PDF',
          'size': '1 KB',
          'date': '21/10/2026',
          'path': file.path,
        },
      ]),
    );
    await tester.pumpWidget(
      MaterialApp(home: app.HomePage(onDarkModeChanged: (_) {})),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('reader-search.pdf').first);
    await tester.pump(const Duration(seconds: 2));
    await until(tester, () => find.byType(PdfViewer).evaluate().isNotEmpty);
    await until(
      tester,
      () => find
          .byWidgetPredicate(
            (w) =>
                w is IconButton &&
                w.tooltip == 'Find in PDF' &&
                w.onPressed != null,
          )
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(find.byTooltip('Find in PDF'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Hello');
    await tester.tap(find.text('Find'));
    await until(
      tester,
      () => find.textContaining('/6 — Hello').evaluate().isNotEmpty,
    );
    expect(find.byTooltip('Next result'), findsOneWidget);
    await tester.tap(find.byTooltip('Next result'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('/6 — Hello'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel search'));
    await tester.pump();
    expect(find.byTooltip('Next result'), findsNothing);
  });
}
