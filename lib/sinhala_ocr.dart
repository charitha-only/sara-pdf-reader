import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:tesseract_ocr/tesseract_ocr.dart';
import 'package:tesseract_ocr/ocr_engine_config.dart';
import 'package:xml/xml.dart';

import 'text_box.dart';

class OcrLine {
  const OcrLine(this.text, this.pixels, this.confidence);
  final String text;
  final Rect pixels;
  final double confidence;
}

class OcrPage {
  const OcrPage({
    required this.png,
    required this.width,
    required this.height,
    required this.pageWidth,
    required this.pageHeight,
    required this.rotation,
    required this.lines,
  });
  final Uint8List png;
  final int width, height, rotation;
  final double pageWidth, pageHeight;
  final List<OcrLine> lines;
  String get text => lines.map((line) => line.text).join('\n');
  PdfTextBox suggestedBox(OcrLine line) {
    final left = (line.pixels.left / width * pageWidth - 2)
        .clamp(0, pageWidth - 12)
        .toDouble();
    final top = (line.pixels.top / height * pageHeight - 2)
        .clamp(0, pageHeight - 12)
        .toDouble();
    final boxWidth = math.min(
      pageWidth - left,
      math.max(120.0, line.pixels.width / width * pageWidth + 20),
    );
    final boxHeight = math.min(
      pageHeight - top,
      math.max(100.0, line.pixels.height / height * pageHeight * 4),
    );
    return PdfTextBox(
      id: 'scan-${DateTime.now().microsecondsSinceEpoch}',
      text: line.text,
      size: (line.pixels.height / height * pageHeight * .7)
          .clamp(6, 36)
          .toDouble(),
      left: left,
      bottom: math.max(0, pageHeight - top - boxHeight),
      width: boxWidth,
      height: boxHeight,
    );
  }

  PdfTextBox nativeBox(PdfTextBox visual) {
    final rawWidth = rotation.isOdd ? pageHeight : pageWidth;
    final rawHeight = rotation.isOdd ? pageWidth : pageHeight;
    return switch (rotation) {
      1 => visual.copyWith(
        left: rawWidth - visual.bottom - visual.height,
        bottom: visual.left,
        rotation: 3,
      ),
      2 => visual.copyWith(
        left: rawWidth - visual.left - visual.width,
        bottom: rawHeight - visual.bottom - visual.height,
        rotation: 2,
      ),
      3 => visual.copyWith(
        left: visual.bottom,
        bottom: rawHeight - visual.left - visual.width,
        rotation: 1,
      ),
      _ => visual,
    };
  }

  Future<Uint8List> correctedBackground(Rect area, {int? background}) async {
    final raster = img.decodePng(png);
    if (raster == null) throw StateError('Could not decode scanned page.');
    final clipped = area
        .inflate(3)
        .intersect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
    if (clipped.width < 1 || clipped.height < 1) {
      throw ArgumentError('Choose a valid scanned text area.');
    }
    final samples = <int>[];
    for (final point in [
      Offset(clipped.left, clipped.top),
      Offset(clipped.right - 1, clipped.top),
      Offset(clipped.left, clipped.bottom - 1),
      Offset(clipped.right - 1, clipped.bottom - 1),
    ]) {
      final pixel = raster.getPixel(point.dx.toInt(), point.dy.toInt());
      samples.add(
        pixel.r.toInt() << 16 | pixel.g.toInt() << 8 | pixel.b.toInt(),
      );
    }
    samples.sort();
    final color = background ?? samples[samples.length ~/ 2];
    img.fillRect(
      raster,
      x1: clipped.left.floor(),
      y1: clipped.top.floor(),
      x2: clipped.right.ceil() - 1,
      y2: clipped.bottom.ceil() - 1,
      color: img.ColorRgb8(
        (color >> 16) & 255,
        (color >> 8) & 255,
        color & 255,
      ),
    );
    final raw = rotation == 0
        ? raster
        : img.copyRotate(raster, angle: -rotation * 90);
    final rawWidth = rotation.isOdd ? pageHeight : pageWidth;
    final rawHeight = rotation.isOdd ? pageWidth : pageHeight;
    final document = pw.Document();
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(rawWidth, rawHeight),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(
          pw.MemoryImage(img.encodeJpg(raw, quality: 98)),
          fit: pw.BoxFit.fill,
        ),
      ),
    );
    return document.save();
  }
}

class OfflineSinhalaOcr {
  static Future<void> cancel() => TesseractOcr.cancel();
  static List<OcrLine> parseHocr(String hocr, int width, int height) {
    if (hocr.trim().isEmpty) return [];
    final document = XmlDocument.parse(hocr);
    final lines = <OcrLine>[];
    for (final node in document.descendants.whereType<XmlElement>()) {
      if (!(node.getAttribute('class') ?? '').split(' ').contains('ocr_line')) {
        continue;
      }
      final match = RegExp(r'bbox\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)')
          .firstMatch(node.getAttribute('title') ?? '');
      if (match == null) continue;
      final values = [
        for (var i = 1; i <= 4; i++) double.parse(match.group(i)!),
      ];
      final rect = Rect.fromLTRB(
        values[0],
        values[1],
        values[2],
        values[3],
      ).intersect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
      final words = node.descendants
          .whereType<XmlElement>()
          .where(
            (n) => (n.getAttribute('class') ?? '')
                .split(' ')
                .contains('ocrx_word'),
          )
          .toList();
      final text = words
          .map((n) => n.innerText.trim())
          .where((t) => t.isNotEmpty)
          .join(' ');
      if (text.isEmpty || rect.isEmpty) continue;
      final confidence = words
          .map(
            (n) =>
                RegExp(r'x_wconf\s+(\d+)')
                    .firstMatch(n.getAttribute('title') ?? ''),
          )
          .whereType<RegExpMatch>()
          .map((m) => double.parse(m.group(1)!))
          .toList();
      lines.add(
        OcrLine(
          text,
          rect,
          confidence.isEmpty
              ? 0
              : confidence.reduce((a, b) => a + b) / confidence.length,
        ),
      );
    }
    return List.unmodifiable(lines);
  }

  static Future<OcrPage> recognize(
    Uint8List pdfBytes,
    int pageNumber, {
    String language = 'sin',
  }) async {
    if (!['sin', 'eng', 'sin+eng'].contains(language)) {
      throw ArgumentError('Unsupported OCR language');
    }
    await pdfrx.pdfrxFlutterInitialize();
    final document = await pdfrx.PdfDocument.openData(pdfBytes);
    pdfrx.PdfImage? image;
    File? imageFile;
    try {
      if (pageNumber < 1 || pageNumber > document.pages.length) {
        throw RangeError('Invalid PDF page.');
      }
      final page = document.pages[pageNumber - 1];
      final scale = math.min(
        300 / 72,
        math.sqrt(12000000 / (page.width * page.height)),
      );
      image = await page.render(
        fullWidth: (page.width * scale).roundToDouble(),
        fullHeight: (page.height * scale).roundToDouble(),
      );
      if (image == null) {
        throw StateError('Could not render this page for OCR.');
      }
      final raster = img.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: image.pixels.buffer,
        bytesOffset: image.pixels.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.bgra,
      );
      final png = Uint8List.fromList(img.encodePng(raster));
      final directory = await getTemporaryDirectory();
      imageFile = File(
        '${directory.path}/pageflow-ocr-${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await imageFile.writeAsBytes(png, flush: true);
      final hocr = await TesseractOcr.extractHocr(
        imageFile.path,
        config: OCRConfig(
          language: language,
          engine: OCREngine.tesseract,
          options: {
            'preserve_interword_spaces': '1',
            'tessedit_pageseg_mode': '3',
          },
        ),
      );
      return OcrPage(
        png: png,
        width: image.width,
        height: image.height,
        pageWidth: page.width,
        pageHeight: page.height,
        rotation: page.rotation.index,
        lines: parseHocr(hocr, image.width, image.height),
      );
    } finally {
      image?.dispose();
      await document.dispose();
      if (imageFile != null && await imageFile.exists()) {
        await imageFile.delete();
      }
    }
  }
}
