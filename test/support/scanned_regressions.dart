import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pageflow_reader/pdfium_object_editor.dart';
import 'package:pageflow_reader/text_box.dart';
import 'package:pageflow_reader/sinhala_ocr.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'editor_regressions.dart';

void scannedRegressions() {
  test('hOCR parses Sinhala text, confidence, escaping and bounded line coordinates', () {
    final lines = OfflineSinhalaOcr.parseHocr(
      '<html><body><span class="ocr_line" title="bbox 5 10 300 40"><span class="ocrx_word" title="x_wconf 91">සිංහල</span><span class="ocrx_word" title="x_wconf 89">&amp; test</span></span></body></html>',
      200,
      100,
    );
    expect(lines.single.text, 'සිංහල & test');
    expect(lines.single.confidence, 90);
    expect(lines.single.pixels.right, 200);
  });

  test(
    'scanned correction preserves editable boxes, page count and undo history',
    () async {
      final folder = await Directory.systemTemp.createTemp('scan-correction-');
      pdfrx.Pdfrx.cacheDirectoryPath ??= folder.path;
      final bitmap = img.Image(width: 400, height: 500);
      img.fill(bitmap, color: img.ColorRgb8(255, 255, 255));
      img.fillRect(
        bitmap,
        x1: 40,
        y1: 50,
        x2: 180,
        y2: 75,
        color: img.ColorRgb8(0, 0, 0),
      );
      final document = pw.Document();
      document.addPage(
        pw.Page(
          pageFormat: const PdfPageFormat(400, 500),
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(
            pw.MemoryImage(img.encodePng(bitmap)),
            fit: pw.BoxFit.fill,
          ),
        ),
      );
      final file = File('${folder.path}/scan.pdf');
      await file.writeAsBytes(await document.save());
      final editor = await PdfiumObjectEditor.open(file.path);
      try {
        await editor.upsertTextBox(
          1,
          const PdfTextBox(
            id: 'preserved',
            text: 'Kept සිංහල',
            left: 40,
            bottom: 50,
            width: 300,
            height: 100,
          ),
        );
        final png = img.encodePng(bitmap);
        final page = OcrPage(
          png: png,
          width: 400,
          height: 500,
          pageWidth: 400,
          pageHeight: 500,
          rotation: 0,
          lines: [],
        );
        final correction = const PdfTextBox(
          id: 'corrected',
          text: 'අලුත් සිංහල',
          left: 40,
          bottom: 300,
          width: 300,
          height: 150,
        );
        await editor.replaceScannedPage(
          1,
          await page.correctedBackground(const Rect.fromLTWH(40, 50, 140, 25)),
          correction,
        );
        var objects = await editor.listObjects(1);
        expect(
          objects.where((o) => o.textBox != null).map((o) => o.textBox!.id),
          containsAll(['preserved', 'corrected']),
        );
        expect(
          (await extractedText(editor.currentBytes)).first,
          contains('අලුත් සිංහල'),
        );
        expect(
          (await extractedText(editor.currentBytes)).first,
          contains('Kept සිංහල'),
        );
        final background = await editor.scanSourceBytes(1);
        expect((await extractedText(background)).first.trim(), isEmpty);
        expect(editor.pageCount, 1);
        await editor.undo();
        expect(
          (await editor.listObjects(1)).where((o) => o.textBox != null).length,
          1,
        );
        await editor.redo();
        expect(
          (await editor.listObjects(1)).where((o) => o.textBox != null).length,
          2,
        );
        await editor.saveTo('${folder.path}/saved.pdf');
        final reopened = await PdfiumObjectEditor.open(
          '${folder.path}/saved.pdf',
        );
        try {
          expect(
            (await reopened.listObjects(1))
                .where((o) => o.textBox != null)
                .length,
            2,
          );
        } finally {
          await reopened.dispose();
        }
      } finally {
        await editor.dispose();
        await folder.delete(recursive: true);
      }
    },
  );
}
