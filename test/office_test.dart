import 'dart:io';

import 'package:file/local.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_xml/open_xml.dart' as office;
import 'package:pdf/widgets.dart' as pw;
import 'package:pageflow_reader/office_document.dart';
import 'package:pageflow_reader/office_layout_export.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:pdf/pdf.dart';

import 'dart:convert';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  pdfrx.Pdfrx.cacheDirectoryPath ??= Directory.systemTemp.path;
  test(
    'mixed PDF page sizes preserve Word sections and fit inside slide canvas',
    () async {
      final pdf = pw.Document();
      pdf.addPage(
        pw.Page(
          pageFormat: const PdfPageFormat(400, 500),
          build: (_) => pw.Text('Portrait'),
        ),
      );
      pdf.addPage(
        pw.Page(
          pageFormat: const PdfPageFormat(800, 300),
          build: (_) => pw.Text('Landscape'),
        ),
      );
      final source = await pdf.save();
      final word = await OfficeLayoutExport.create(source, 'word');
      final archive = ZipDecoder().decodeBytes(word);
      final xml = XmlDocument.parse(
        utf8.decode(archive.findFile('word/document.xml')!.content),
      );
      final sizes = xml.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'pgSz')
          .toList();
      expect(sizes.length, 2);
      expect(
        sizes.first.attributes.firstWhere((a) => a.name.local == 'w').value,
        '8000',
      );
      expect(
        sizes.last.attributes.firstWhere((a) => a.name.local == 'w').value,
        '16000',
      );
      final ppt = OfficeDocument.read(
        await OfficeLayoutExport.create(source, 'ppt'),
        'pptx',
      );
      final landscape = ppt.sections.last.blocks.single;
      expect(landscape.left, greaterThanOrEqualTo(0));
      expect(landscape.top, greaterThanOrEqualTo(0));
      expect(landscape.left + landscape.width, lessThanOrEqualTo(1.001));
      expect(landscape.top + landscape.height, lessThanOrEqualTo(1.001));
    },
  );
  test('DOCX XLSX PPTX editable text imports round trip', () async {
    final folder = await Directory.systemTemp.createTemp('office-roundtrip-');
    const fs = LocalFileSystem();
    try {
      final word = await office.WordDocument.create(fs);
      word.addParagraph(
        office.Paragraph()
          ..addRun(office.Run(text: 'Reviewed Sinhala සිංහල', bold: true)),
      );
      final workbook = await office.Workbook.create(fs);
      workbook.addSheet('Accounts').addRow()
        ..addCell('Account')
        ..addCell(123);
      final slides = await office.Presentation.create(fs);
      slides.addSlide().addText('Reviewed slide');
      await word.save(fs.file('${folder.path}/test.docx'));
      await workbook.save(fs.file('${folder.path}/test.xlsx'));
      await slides.save(fs.file('${folder.path}/test.pptx'));
      final doc = OfficeDocument.read(
        await File('${folder.path}/test.docx').readAsBytes(),
        'docx',
      );
      expect(doc.sections.first.blocks.first.text, 'Reviewed Sinhala සිංහල');
      expect(doc.sections.first.blocks.first.runs.first.bold, isTrue);
      final sheet = OfficeDocument.read(
        await File('${folder.path}/test.xlsx').readAsBytes(),
        'xlsx',
      );
      expect(sheet.sections.first.name, 'Accounts');
      expect(sheet.sections.first.blocks.first.rows.first, ['Account', '123']);
      final ppt = OfficeDocument.read(
        await File('${folder.path}/test.pptx').readAsBytes(),
        'pptx',
      );
      expect(
        ppt.sections.first.blocks.map((b) => b.text).join(),
        contains('Reviewed slide'),
      );
    } finally {
      await folder.delete(recursive: true);
    }
  });
  for (final format in ['word', 'excel', 'ppt']) {
    test('$format appearance export embeds actual page images', () async {
      final pdf = pw.Document();
      pdf.addPage(pw.Page(build: (_) => pw.Text('Page appearance')));
      final bytes = await OfficeLayoutExport.create(await pdf.save(), format);
      if (!Platform.isAndroid) {
        await Directory('work').create(recursive: true);
        await File(
          'work/layout.$format.${format == 'word'
              ? 'docx'
              : format == 'excel'
              ? 'xlsx'
              : 'pptx'}',
        ).writeAsBytes(bytes);
      }
      final doc = OfficeDocument.read(
        bytes,
        format == 'word'
            ? 'docx'
            : format == 'excel'
            ? 'xlsx'
            : 'pptx',
      );
      expect(doc.sections.length, 1);
      expect(
        doc.sections.first.blocks.where((b) => b.image != null),
        hasLength(1),
      );
    });
  }
}
