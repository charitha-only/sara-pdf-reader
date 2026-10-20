import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/pdfium_object_editor.dart';
import 'package:pageflow_reader/text_box.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'pdf_fixture.dart';
import 'editor_regressions.dart';

void textBoxRegressions() {
  late Directory folder;
  late PdfiumObjectEditor editor;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('pageflow-box-');
    pdfrx.Pdfrx.cacheDirectoryPath ??= folder.path;
    final file = File('${folder.path}/source.pdf');
    await file.writeAsBytes(fixturePdf());
    editor = await PdfiumObjectEditor.open(file.path);
  });
  tearDown(() async {
    await editor.dispose();
    await folder.delete(recursive: true);
  });

  test(
    'Sinhala shaping, embedded fonts and text-box metadata survive reopen',
    () async {
      const text = 'සිංහල භාෂාව\nශ්‍රී ලංකාව';
      await editor.upsertTextBox(
        1,
        const PdfTextBox(
          id: 'sinhala-box',
          text: text,
          left: 40,
          bottom: 80,
          width: 320,
          height: 200,
          size: 24,
        ),
      );
      var boxes = (await editor.listObjects(1))
          .where((o) => o.textBox != null)
          .toList();
      expect(boxes.length, 1);
      expect(boxes.single.textBox!.text, text);
      expect(
        (await extractedText(editor.currentBytes)).first,
        contains('සිංහල භාෂාව'),
      );
      expect(
        (await extractedText(editor.currentBytes)).first,
        contains('ශ්‍රී ලංකාව'),
      );
      final doc = await pdfrx.PdfDocument.openData(editor.currentBytes);
      try {
        final raster = await doc.pages.first.render(
          fullWidth: 800,
          fullHeight: 1000,
        );
        expect(raster, isNotNull);
        raster?.dispose();
      } finally {
        await doc.dispose();
      }
      await editor.saveTo('${folder.path}/saved.pdf');
      final reopened = await PdfiumObjectEditor.open(
        '${folder.path}/saved.pdf',
      );
      try {
        final box = (await reopened.listObjects(1))
            .firstWhere((o) => o.textBox != null);
        expect(box.textBox!.text, text);
        await reopened.upsertTextBox(
          1,
          box.textBox!.copyWith(
            text: 'අලුත් සිංහල',
            font: 'Noto Serif',
            size: 26,
            bold: true,
            color: 0xffc62828,
            align: 'right',
          ),
          objectIndex: box.index,
        );
        expect(
          (await extractedText(reopened.currentBytes)).first,
          contains('අලුත් සිංහල'),
        );
        expect(
          (await extractedText(reopened.currentBytes)).first,
          isNot(contains('සිංහල භාෂාව')),
        );
        final styled = (await reopened.listObjects(1))
            .firstWhere((o) => o.textBox != null)
            .textBox!;
        expect(styled.bold, isTrue);
        expect(styled.font, 'Noto Serif');
        expect(styled.color, 0xffc62828);
        expect(styled.align, 'right');
      } finally {
        await reopened.dispose();
      }
    },
  );

  test('existing text can change font, size, color and alignment without flattening', () async {
    final existing = (await editor.listObjects(1))
        .firstWhere((o) => o.type == 1);
    expect(existing.text, contains('Hello'));
    await editor.upsertTextBox(
      1,
      existing.editableStyle().copyWith(
        font: 'Noto Serif',
        size: 22,
        color: 0xff185abc,
        align: 'center',
        width: 300,
        height: 100,
        left: 40,
        bottom: 380,
      ),
      objectIndex: existing.index,
    );
    final objects = await editor.listObjects(1);
    expect(objects.any((o) => o.type == 2), isTrue);
    expect(objects.any((o) => o.type == 3), isTrue);
    expect(
      objects.firstWhere((o) => o.textBox != null).textBox!.font,
      'Noto Serif',
    );
    expect((await extractedText(editor.currentBytes)).first, contains('Hello'));
    await editor.undo();
    expect((await editor.listObjects(1)).first.type, 1);
    await editor.redo();
    expect((await editor.listObjects(1)).any((o) => o.textBox != null), isTrue);
  });

  test(
    'text boxes resize by reflow, replace-all, delete and undo atomically',
    () async {
      const box = PdfTextBox(
        id: 'reflow',
        text: 'Hello සිංහල Hello',
        size: 18,
        left: 40,
        bottom: 80,
        width: 300,
        height: 150,
      );
      await editor.upsertTextBox(1, box);
      var object = (await editor.listObjects(1)).last;
      await editor.transformObject(
        1,
        object.index,
        left: 60,
        bottom: 80,
        width: 150,
        height: 250,
      );
      object = (await editor.listObjects(1)).last;
      expect(object.textBox!.width, 150);
      expect(object.textBox!.size, 18);
      expect(await editor.replaceTextMatchesEverywhere('Hello', 'Updated'), 4);
      expect(
        (await editor.listObjects(1)).last.textBox!.text,
        'Updated සිංහල Updated',
      );
      await editor.undo();
      expect((await editor.listObjects(1)).last.textBox!.text, box.text);
      await editor.deleteObject(1, object.index);
      expect(
        (await editor.listObjects(1)).any((o) => o.textBox != null),
        isFalse,
      );
      await editor.undo();
      expect((await editor.listObjects(1)).last.textBox!.id, 'reflow');
    },
  );

  test(
    'overflow and invalid style/position leave the document unchanged',
    () async {
      final before = await extractedText(editor.currentBytes);
      await expectLater(
        editor.upsertTextBox(
          1,
          const PdfTextBox(
            id: 'bad',
            text: 'සිංහල\nසිංහල\nසිංහල',
            height: 12,
            size: 30,
          ),
        ),
        throwsStateError,
      );
      await expectLater(
        editor.upsertTextBox(
          1,
          const PdfTextBox(id: 'bad', text: 'Text', left: 999),
        ),
        throwsException,
      );
      expect(await extractedText(editor.currentBytes), before);
      expect(editor.canUndo, isFalse);
    },
  );
}
