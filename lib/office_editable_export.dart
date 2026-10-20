import 'dart:io';
import 'dart:typed_data';

import 'package:file/local.dart';
import 'package:open_xml/open_xml.dart' as office;
import 'package:path_provider/path_provider.dart';

import 'task_progress.dart';

class OfficeEditableExport {
  static Future<Uint8List> create(
    List<String> pages,
    String format,
    TaskProgress progress,
  ) async {
    if (!pages.any((p) => p.trim().isNotEmpty)) {
      throw const FormatException('Enter or recognize text before exporting.');
    }
    const fs = LocalFileSystem();
    final temporary = await getTemporaryDirectory();
    final folder = await Directory(
      '${temporary.path}${Platform.pathSeparator}office-export-${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    Iterable<String> chunks(String text, int maximum) sync* {
      for (var i = 0; i < text.length;) {
        var end = (i + maximum).clamp(0, text.length);
        if (end < text.length &&
            text.codeUnitAt(end - 1) >= 0xd800 &&
            text.codeUnitAt(end - 1) <= 0xdbff) {
          end--;
        }
        yield text.substring(i, end);
        i = end;
      }
    }

    try {
      final path =
          '${folder.path}/export.${format == 'word'
              ? 'docx'
              : format == 'excel'
              ? 'xlsx'
              : 'pptx'}';
      if (format == 'word') {
        final doc = await office.WordDocument.create(fs);
        for (var i = 0; i < pages.length; i++) {
          await progress.step(
            'Preparing Word page ${i + 1} of ${pages.length}',
            done: i,
            total: pages.length,
          );
          doc.addParagraph(
            office.Paragraph()
              ..addRun(office.Run(text: 'Page ${i + 1}', bold: true)),
          );
          for (final text in chunks(pages[i], 6000)) {
            doc.addParagraph(
              office.Paragraph()..addRun(office.Run(text: text)),
            );
          }
        }
        await progress.step('Saving Word document…');
        await doc.save(fs.file(path));
      } else if (format == 'excel') {
        final workbook = await office.Workbook.create(fs),
            sheet = workbook.addSheet('Reviewed PDF text');
        sheet.addRow()
          ..addCell('Page')
          ..addCell('Part')
          ..addCell('Reviewed text');
        for (var i = 0; i < pages.length; i++) {
          await progress.step(
            'Preparing Excel page ${i + 1} of ${pages.length}',
            done: i,
            total: pages.length,
          );
          var part = 0;
          for (final text in chunks(pages[i], 30000)) {
            sheet.addRow()
              ..addCell(i + 1)
              ..addCell(++part)
              ..addCell(text);
          }
        }
        await progress.step('Saving Excel workbook…');
        await workbook.save(fs.file(path));
      } else {
        final presentation = await office.Presentation.create(fs);
        for (var i = 0; i < pages.length; i++) {
          await progress.step(
            'Preparing slides for page ${i + 1} of ${pages.length}',
            done: i,
            total: pages.length,
          );
          var part = 0;
          for (final text in chunks(pages[i], 3000)) {
            final slide = presentation.addSlide();
            slide.addTitle('Page ${i + 1} · Part ${++part}');
            slide.addText(text);
          }
        }
        await progress.step('Saving presentation…');
        await presentation.save(fs.file(path));
      }
      progress.check();
      final bytes = await File(path).readAsBytes();
      progress.check();
      return bytes;
    } finally {
      await folder.delete(recursive: true);
    }
  }
}
