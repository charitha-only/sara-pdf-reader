import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/pdfium_object_editor.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'support/pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '350-page document opens, edits last page and splits without flattening',
    () async {
      final folder = await Directory.systemTemp.createTemp('large-pdf-');
      pdfrx.Pdfrx.cacheDirectoryPath ??= folder.path;
      final file = File('${folder.path}/large.pdf');
      await file.writeAsBytes(fixturePdf(pages: 350));
      final editor = await PdfiumObjectEditor.open(file.path);
      try {
        expect(editor.pageCount, 350);
        expect(await editor.listObjects(350), hasLength(3));
        final split = await editor.splitPages([
          [350, 1],
        ]);
        final document = await pdfrx.PdfDocument.openData(split.single);
        try {
          expect(document.pages.length, 2);
          expect(
            (await document.pages.first.loadText())!.fullText,
            contains('350'),
          );
        } finally {
          await document.dispose();
        }
        await editor.deletePages([349]);
        expect(editor.pageCount, 349);
        await editor.undo();
        expect(editor.pageCount, 350);
      } finally {
        await editor.dispose();
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'rotated pages keep text and rotation through native splitting',
    () async {
      await pdfrx.pdfrxFlutterInitialize();
      final source = await pdfrx.PdfDocument.openData(fixturePdf());
      try {
        source.pages = [
          source.pages.first.rotatedTo(pdfrx.PdfPageRotation.clockwise90),
          ...source.pages.skip(1),
        ];
        final bytes = await source.encodePdf();
        final document = await pdfrx.PdfDocument.openData(bytes);
        try {
          expect(
            document.pages.first.rotation,
            pdfrx.PdfPageRotation.clockwise90,
          );
          expect(
            (await document.pages.first.loadText())!.fullText,
            contains('Hello Pageflow'),
          );
        } finally {
          await document.dispose();
        }
      } finally {
        await source.dispose();
      }
    },
  );
}
