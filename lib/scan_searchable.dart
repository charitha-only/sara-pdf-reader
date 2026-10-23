import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:image/image.dart' as img;

import 'sinhala_ocr.dart';
import 'task_progress.dart';

class ScanTextPage {
  const ScanTextPage(this.width, this.height, this.lines);
  final int width, height;
  final List<OcrLine> lines;
}

Future<Uint8List> buildSearchableScanPdf(
  List<Uint8List> images,
  List<ScanTextPage> textPages,
) async {
  if (images.isEmpty || images.length != textPages.length || images.length > 20) {
    throw ArgumentError('Invalid searchable scan pages');
  }
  final font = pw.Font.ttf(
    await rootBundle.load('assets/fonts/NotoSansSinhala-Regular.ttf'),
  );
  final document = pw.Document();
  for (var index = 0; index < images.length; index++) {
    final text = textPages[index], bytes = images[index];
    if (text.width <= 0 || text.height <= 0) {
      throw ArgumentError('Invalid OCR dimensions');
    }
    final info = img.JpegDecoder().startDecode(bytes)!;
    final page = info.width > info.height
        ? PdfPageFormat.a4.landscape
        : PdfPageFormat.a4;
    document.addPage(
      pw.Page(
        pageFormat: page,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.SizedBox(
          width: page.width,
          height: page.height,
          child: pw.Stack(
            children: [
              pw.Positioned.fill(
                child: pw.Padding(
                  padding: const pw.EdgeInsets.all(18),
                  child: pw.Center(
                    child: pw.Image(
                      pw.MemoryImage(bytes),
                      fit: pw.BoxFit.contain,
                    ),
                  ),
                ),
              ),
              for (final line in text.lines)
                if (line.text.trim().isNotEmpty && !line.pixels.isEmpty)
                  pw.Positioned(
                    left: line.pixels.left / text.width * page.width,
                    top: line.pixels.top / text.height * page.height,
                    child: pw.SizedBox(
                      width: line.pixels.width / text.width * page.width,
                      height: line.pixels.height / text.height * page.height,
                      child: pw.FittedBox(
                        fit: pw.BoxFit.fill,
                        child: pw.Text(
                          line.text,
                          maxLines: 1,
                          style: pw.TextStyle(
                            font: font,
                            fontSize: 12,
                            renderingMode: PdfTextRenderingMode.invisible,
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
  return document.save();
}

Future<Uint8List> searchableScanPdf(
  List<Uint8List> images,
  Uint8List imagePdf,
  TaskProgress progress, {
  String language = 'sin+eng',
}) async {
  final textPages = <ScanTextPage>[];
  var count = 0;
  progress.onCancel = () {
    OfflineSinhalaOcr.cancel();
  };
  for (var index = 0; index < images.length; index++) {
    await progress.step(
      'Recognizing page ${index + 1} of ${images.length}',
      done: index,
      total: images.length,
    );
    final ocr = await OfflineSinhalaOcr.recognize(
      imagePdf,
      index + 1,
      language: language,
    );
    progress.check();
    count += ocr.text.length;
    if (count > 1000000) {
      throw StateError(
        'OCR text exceeds the export limit. Use an image-only PDF.',
      );
    }
    textPages.add(ScanTextPage(ocr.width, ocr.height, ocr.lines));
  }
  if (count == 0) {
    throw StateError(
      'No text was recognized. Try another OCR language or use an image-only PDF.',
    );
  }
  await progress.step(
    'Building searchable PDF',
    done: images.length,
    total: images.length,
  );
  return buildSearchableScanPdf(images, textPages);
}
