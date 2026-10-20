import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:pageflow_reader/pdfium_object_editor.dart';
import 'package:pageflow_reader/pdf_page_manager.dart';
import 'package:pageflow_reader/pdf_redaction.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('page ranges reject invalid input and preserve selected order', () {
    expect(parsePdfPages('3,1-2,3', 3), [3, 1, 2]);
    for (final value in ['0', '4', '3-1', '1-x', '']) {
      expect(() => parsePdfPages(value, 3), throwsArgumentError);
    }
  });
  test(
    'native insert, crop, split, delete, overwrite and undo preserve text',
    () async {
      final folder = await Directory.systemTemp.createTemp('page-tools-');
      pdfrx.Pdfrx.cacheDirectoryPath ??= folder.path;
      final pdf = pw.Document();
      for (final text in ['FIRST VECTOR TEXT', 'SECOND VECTOR TEXT']) {
        pdf.addPage(pw.Page(build: (_) => pw.Text(text)));
      }
      final path = '${folder.path}/source.pdf';
      await File(path).writeAsBytes(await pdf.save());
      final editor = await PdfiumObjectEditor.open(path);
      try {
        await editor.insertPdf(2, await File(path).readAsBytes());
        expect(editor.pageCount, 4);
        await editor.cropPage(1, left: 0, bottom: 0, right: 500, top: 700);
        final pieces = await editor.splitPages([
          [4],
          [1, 3],
        ]);
        final part = await pdfrx.PdfDocument.openData(pieces[0]);
        try {
          expect(part.pages.length, 1);
          expect(
            (await part.pages.first.loadText())!.fullText,
            contains('SECOND VECTOR TEXT'),
          );
        } finally {
          await part.dispose();
        }
        await expectLater(editor.deletePages([1, 2, 3, 4]), throwsException);
        expect(editor.pageCount, 4);
        await editor.deletePages([2, 3]);
        expect(editor.pageCount, 2);
        await editor.saveTo(path);
        final saved = await pdfrx.PdfDocument.openFile(path);
        try {
          expect(saved.pages.length, 2);
          expect(
            (await saved.pages.first.loadText())!.fullText,
            contains('FIRST VECTOR TEXT'),
          );
        } finally {
          await saved.dispose();
        }
        await editor.undo();
        expect(editor.pageCount, 4);
      } finally {
        await editor.dispose();
        await folder.delete(recursive: true);
      }
    },
  );
  test('permanent redaction drops original text and metadata', () async {
    final pdf = pw.Document(title: 'CONFIDENTIAL SECRET');
    pdf.addPage(pw.Page(build: (_) => pw.Text('SECRET ACCOUNT 12345')));
    final redacted = await PermanentPdfRedaction.create(await pdf.save(), {
      1: [const Rect.fromLTWH(0, 0, 1, 1)],
    });
    final document = await pdfrx.PdfDocument.openData(redacted);
    try {
      expect(document.pages.length, 1);
      expect((await document.pages.first.loadText())!.fullText.trim(), isEmpty);
    } finally {
      await document.dispose();
    }
    expect(
      String.fromCharCodes(redacted),
      isNot(contains('CONFIDENTIAL SECRET')),
    );
  });
}
