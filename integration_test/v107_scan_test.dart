import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:pageflow_reader/camera_capture.dart';
import 'package:pageflow_reader/scan_searchable.dart';
import 'package:pageflow_reader/task_progress.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Offline scan OCR produces searchable PDF with unchanged raster appearance',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
        final painter = TextPainter(
          text: const TextSpan(
            text: 'SARA READER OFFLINE TEST\nInvoice 12345',
            style: TextStyle(color: Colors.black, fontSize: 64),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 1700);
        painter.paint(canvas, const Offset(60, 60));
        painter.dispose();
        final picture = recorder.endRecording();
        final image = await picture.toImage(1800, 500);
        picture.dispose();
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        final jpeg = await convertCapture({
          'bytes': png,
          'turns': 0,
          'scan': false,
          'format': 'jpeg',
        });
        final imagePdf = await scanPagesPdf([jpeg, jpeg]);
        final progress = TaskProgress();
        final searchable = await searchableScanPdf(
          [jpeg, jpeg],
          imagePdf,
          progress,
          language: 'eng',
        );
        progress.dispose();
        final original = await pdfrx.PdfDocument.openData(imagePdf);
        final result = await pdfrx.PdfDocument.openData(searchable);
        try {
          expect(result.pages.length, 2);
          for (var index = 0; index < 2; index++) {
            final text = (await result.pages[index].loadText())!.fullText
                .toUpperCase();
            expect(text, contains('READER'));
            expect(text, contains('12345'));
            final a = (await original.pages[index].render(
              width: 900,
              height: 637,
            ))!;
            final b = (await result.pages[index].render(
              width: 900,
              height: 637,
            ))!;
            try {
              expect(
                b.pixels,
                orderedEquals(a.pixels),
                reason: 'Invisible OCR must not change the document image',
              );
            } finally {
              a.dispose();
              b.dispose();
            }
          }
        } finally {
          await original.dispose();
          await result.dispose();
        }
      });
    },
  );
}
