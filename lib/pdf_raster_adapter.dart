import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'task_progress.dart';

enum PdfPageImageFormat { png, jpeg }

class PdfRasterImage {
  const PdfRasterImage(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int? width, height;
}

class PdfRenderDocument {
  PdfRenderDocument._(this.document);
  final pdfrx.PdfDocument document;
  static Future<PdfRenderDocument> openFile(String path) async {
    await pdfrx.pdfrxFlutterInitialize();
    return PdfRenderDocument._(await pdfrx.PdfDocument.openFile(path));
  }

  int get pagesCount => document.pages.length;
  Future<PdfRenderPage> getPage(int number) async {
    if (number < 1 || number > pagesCount) throw RangeError('Invalid page.');
    return PdfRenderPage(document.pages[number - 1]);
  }

  Future<void> close() => document.dispose();
}

class PdfRenderPage {
  PdfRenderPage(this.page);
  final pdfrx.PdfPage page;
  double get width => page.width;
  double get height => page.height;
  Future<void> close() async {}
  Future<PdfRasterImage?> render({
    required double width,
    required double height,
    PdfPageImageFormat format = PdfPageImageFormat.png,
    String? backgroundColor,
    int quality = 95,
    bool forPrint = false,
    TaskProgress? progress,
  }) async {
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      throw ArgumentError('Invalid page image dimensions.');
    }
    final limit = math.min(
      math.min(1.0, math.sqrt(12000000 / (width * height))),
      math.min(8192 / width, 8192 / height),
    );
    progress?.check();
    final token = page.createCancellationToken();
    final previous = progress?.onCancel;
    if (progress != null) {
      progress.onCancel = () {
        token.cancel();
        previous?.call();
      };
    }
    pdfrx.PdfImage? image;
    try {
      image = await page.render(
        fullWidth: (width * limit).roundToDouble(),
        fullHeight: (height * limit).roundToDouble(),
        backgroundColor: 0xffffffff,
        cancellationToken: token,
      );
    } finally {
      if (progress != null) progress.onCancel = previous;
    }
    if (image == null) {
      progress?.check();
      return null;
    }
    try {
      progress?.check();
      final raster = img.Image.fromBytes(
        width: image.width,
        height: image.height,
        bytes: image.pixels.buffer,
        bytesOffset: image.pixels.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.bgra,
      );
      final bytes = format == PdfPageImageFormat.png
          ? img.encodePng(raster)
          : img.encodeJpg(raster, quality: quality.clamp(1, 100));
      progress?.check();
      return PdfRasterImage(bytes, image.width, image.height);
    } finally {
      image.dispose();
    }
  }
}
