import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/pdfium_object_editor.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'pdf_fixture.dart';

Future<List<String>> extractedText(Uint8List bytes) async {
  final doc = await pdfrx.PdfDocument.openData(bytes);
  try {
    return [
      for (final page in doc.pages) (await page.loadStructuredText()).fullText,
    ];
  } finally {
    await doc.dispose();
  }
}

void editorRegressions() {
  late Directory directory;
  late File source;
  late PdfiumObjectEditor editor;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pageflow-regression-');
    pdfrx.Pdfrx.cacheDirectoryPath ??= directory.path;
    source = File('${directory.path}/original.pdf');
    await source.writeAsBytes(fixturePdf());
    editor = await PdfiumObjectEditor.open(source.path, historyLimit: 2);
  });
  tearDown(() async {
    await editor.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'native text, image and path transforms survive save and reopen',
    () async {
      expect(editor.pageCount, 3);
      final objects = await editor.listObjects(1);
      expect(objects.map((o) => o.type), containsAll([1, 2, 3]));
      for (final type in [1, 2, 3]) {
        final object = (await editor.listObjects(1))
            .firstWhere((o) => o.type == type);
        await editor.transformObject(
          1,
          object.index,
          left: 60,
          bottom: 120,
          width: object.width * 1.5,
          height: object.height * 1.5,
        );
        final moved = (await editor.listObjects(1))
            .firstWhere((o) => o.type == type);
        expect(moved.left, closeTo(60, .1));
        expect(moved.bottom, closeTo(120, .1));
        expect(moved.width, closeTo(object.width * 1.5, .1));
      }
      final saved = '${directory.path}/saved.pdf';
      await editor.saveTo(saved);
      final reopened = await PdfiumObjectEditor.open(saved);
      try {
        expect((await reopened.listObjects(1)).length, 3);
        expect(
          (await extractedText(reopened.currentBytes)).first,
          contains('Hello'),
        );
        expect(await source.readAsBytes(), orderedEquals(fixturePdf()));
      } finally {
        await reopened.dispose();
      }
    },
  );

  test('replace-all is one undo step even when history is full', () async {
    await editor.transformObject(
      1,
      0,
      left: 50,
      bottom: 420,
      width: 240,
      height: 20,
    );
    await editor.transformObject(
      1,
      0,
      left: 60,
      bottom: 420,
      width: 240,
      height: 20,
    );
    final before = (await editor.listObjects(1)).first.left;
    expect(await editor.replaceTextMatchesEverywhere('Hello', 'Updated'), 3);
    for (final text in await extractedText(editor.currentBytes)) {
      expect(text, contains('Updated'));
      expect(text, isNot(contains('Hello')));
    }
    await editor.undo();
    expect(
      (await extractedText(editor.currentBytes))
          .every((t) => t.contains('Hello')),
      isTrue,
    );
    expect((await editor.listObjects(1)).first.left, closeTo(before, .1));
    await editor.undo();
    expect((await editor.listObjects(1)).first.left, closeTo(50, .1));
    expect(editor.canUndo, isFalse);
    await editor.redo();
    await editor.redo();
    expect(
      (await extractedText(editor.currentBytes))
          .every((t) => t.contains('Updated')),
      isTrue,
    );
  });

  test(
    'delete and add selectable text have reversible native content',
    () async {
      final image = (await editor.listObjects(1))
          .firstWhere((o) => o.type == 3);
      await editor.deleteObject(1, image.index);
      expect((await editor.listObjects(1)).any((o) => o.type == 3), isFalse);
      await editor.undo();
      expect((await editor.listObjects(1)).any((o) => o.type == 3), isTrue);
      await editor.addTextObject(
        1,
        text: 'Selectable added text',
        fontName: 'Helvetica',
        fontSize: 18,
        left: 200,
        bottom: 200,
        red: 10,
        green: 20,
        blue: 30,
        alignment: 'center',
      );
      expect(
        (await extractedText(editor.currentBytes)).first,
        contains('Selectable added text'),
      );
      final added = (await editor.listObjects(1)).last;
      expect((added.left + added.right) / 2, closeTo(200, .1));
      await editor.undo();
      expect(
        (await extractedText(editor.currentBytes)).first,
        isNot(contains('Selectable added text')),
      );
      await editor.redo();
      expect(
        (await extractedText(editor.currentBytes)).first,
        contains('Selectable added text'),
      );
    },
  );

  test(
    'invalid edits preserve content and history; closing twice is safe',
    () async {
      await editor.deleteObject(1, 2);
      final before = editor.currentBytes;
      await expectLater(
        editor.transformObject(
          1,
          0,
          left: double.nan,
          bottom: 0,
          width: 20,
          height: 20,
        ),
        throwsA(predicate((e) => e.toString().contains('Invalid argument'))),
      );
      await expectLater(
        editor.deleteObject(1, 99),
        throwsA(predicate((e) => e.toString().contains('RangeError'))),
      );
      await expectLater(
        editor.replaceTextMatchesEverywhere('', 'X'),
        throwsA(predicate((e) => e.toString().contains('Invalid argument'))),
      );
      expect(await editor.replaceTextMatchesEverywhere('missing', 'X'), 0);
      expect(
        await extractedText(editor.currentBytes),
        await extractedText(before),
      );
      await editor.undo();
      expect((await editor.listObjects(1)).length, 3);
      expect(editor.canUndo, isFalse);
      await editor.dispose();
      await editor.dispose();
      await expectLater(editor.listObjects(1), throwsStateError);
    },
  );

  test(
    'editing can share the worker with text extraction and queued close',
    () async {
      final bytes = editor.currentBytes;
      await Future.wait([
        extractedText(bytes),
        editor.replaceTextMatchesEverywhere('Hello', 'Shared'),
      ]);
      expect(
        (await extractedText(editor.currentBytes)).first,
        contains('Shared'),
      );
      final pending = editor.deleteObject(1, 2);
      final closing = editor.dispose();
      await pending;
      await closing;
      expect(editor.canUndo, isFalse);
      await expectLater(editor.listObjects(1), throwsStateError);
    },
  );

  test('a failed save preserves the undo history and original file', () async {
    await editor.deleteObject(1, 2);
    await expectLater(
      editor.saveTo('${directory.path}/missing/subfolder/result.pdf'),
      throwsException,
    );
    expect(editor.canUndo, isTrue);
    expect(await source.readAsBytes(), orderedEquals(fixturePdf()));
    await editor.undo();
    expect((await editor.listObjects(1)).length, 3);
  });

  test(
    'empty, damaged and zero-page files fail without opening a session',
    () async {
      for (final bytes in [
        Uint8List(0),
        Uint8List.fromList([1, 2, 3]),
        fixturePdf(pages: 0),
      ]) {
        final bad = File('${directory.path}/invalid.pdf');
        await bad.writeAsBytes(bytes);
        await expectLater(PdfiumObjectEditor.open(bad.path), throwsException);
      }
      await expectLater(
        PdfiumObjectEditor.open(source.path, historyLimit: 0),
        throwsArgumentError,
      );
      expect((await editor.listObjects(1)).length, 3);
    },
  );
}
