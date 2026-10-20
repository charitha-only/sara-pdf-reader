import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:pageflow_reader/pdfium_object_editor.dart';

import 'support/pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'click targets follow rendered rotation and crop without altering PDF',
    () async {
      final folder = await Directory.systemTemp.createTemp('click-geometry-');
      pdfrx.Pdfrx.cacheDirectoryPath ??= folder.path;
      final file = File('${folder.path}/test.pdf');
      await file.writeAsBytes(fixturePdf());
      final source = await pdfrx.PdfDocument.openFile(file.path);
      source.pages = [source.pages.first.rotatedCW90()];
      await file.writeAsBytes(await source.encodePdf());
      await source.dispose();
      final editor = await PdfiumObjectEditor.open(file.path);
      try {
        final before = editor.currentBytes;
        final targets = await editor.tapTargets(1);
        expect(targets.where((t) => t.object.canEditText), hasLength(1));
        final text = targets.firstWhere((t) => t.object.canEditText);
        expect(text.left, greaterThan(.7));
        expect(text.top, lessThan(.5));
        expect(text.right, lessThanOrEqualTo(1));
        expect(text.bottom, lessThanOrEqualTo(1));
        expect(editor.currentBytes, before);
      } finally {
        await editor.dispose();
        await folder.delete(recursive: true);
      }
    },
  );
}
