import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:pageflow_reader/epub_reader.dart';
import 'package:pageflow_reader/app_language.dart';
import 'package:pageflow_reader/reading_state.dart';
import 'package:pageflow_reader/reader_display.dart';
import 'package:pageflow_reader/sinhala_ocr.dart';
import 'package:pageflow_reader/main.dart' as app;

import '../test/support/epub_fixture.dart';

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}

Future<Uint8List> outlinedPdf() async {
  final pdf = pw.Document();
  pdf.addPage(
    pw.Page(
      build: (_) => pw.Column(
        children: [
          pw.Outline(
            name: 'first',
            title: 'First chapter',
            child: pw.Text('First page'),
          ),
          pw.Link(
            destination: 'second',
            child: pw.Text('Go to second chapter'),
          ),
        ],
      ),
    ),
  );
  pdf.addPage(
    pw.Page(
      build: (_) => pw.Outline(
        name: 'second',
        title: 'Second chapter',
        child: pw.Text('Second page'),
      ),
    ),
  );
  return pdf.save();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'EPUB chapter resume and reader display controls preserve the source',
    (tester) async {
      final dir = await getTemporaryDirectory();
      final original = fixtureEpub();
      await AppPreferences.write({
        'readerAwake': false,
        'readerFullscreen': false,
        'readerRotation': 'auto',
      });
      final file = await File('${dir.path}/reader-v103.epub')
          .writeAsBytes(original);
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderFrame(
            child: EpubReader(path: file.path, name: 'Reader.epub'),
          ),
        ),
      );
      await until(
        tester,
        () => find.textContaining('Chapter One').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('Next chapter'));
      await tester.pump();
      await until(
        tester,
        () => find.textContaining('Chapter Two').evaluate().isNotEmpty,
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      expect((await ReadingStateStore.load(file.path))['unit'], 1);
      final frame = tester.state<ReaderFrameState>(find.byType(ReaderFrame));
      await frame.choose('awake');
      await frame.choose('fullscreen');
      expect(frame.awake, isTrue);
      expect(frame.fullscreen, isTrue);
      await frame.choose('awake');
      await frame.choose('fullscreen');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderFrame(
            child: EpubReader(path: file.path, name: 'Reader.epub'),
          ),
        ),
      );
      await until(
        tester,
        () => find.textContaining('2/2').evaluate().isNotEmpty,
      );
      expect(await file.readAsBytes(), original);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'PDF outline and embedded internal links navigate to their destination',
    (tester) async {
      final root = await getApplicationDocumentsDirectory();
      final dir = Directory('${root.path}/pdfs');
      await dir.create(recursive: true);
      final file = await File('${dir.path}/reader-outline.pdf')
          .writeAsBytes(await outlinedPdf());
      await File('${dir.path}/documents.json').writeAsString(
        jsonEncode([
          {
            'name': 'reader-outline.pdf',
            'kind': 'PDF',
            'size': '2 KB',
            'date': '21/10/2026',
            'path': file.path,
            'lastPage': 1,
            'bookmarks': [1],
            'isFavorite': true,
          },
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(home: app.HomePage(onDarkModeChanged: (_) {})),
      );
      await until(
        tester,
        () => find.text('reader-outline.pdf').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('reader-outline.pdf').first);
      await tester.pump();
      await until(
        tester,
        () => find.byType(pdfrx.PdfViewer).evaluate().isNotEmpty,
      );
      final viewer = tester.widget<pdfrx.PdfViewer>(
        find.byType(pdfrx.PdfViewer),
      );
      await until(tester, () => viewer.controller!.isReady);
      await tester.tap(find.byTooltip('Reading options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Document contents'));
      await tester.pump();
      await until(
        tester,
        () => find.text('Second chapter').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Second chapter'));
      await tester.pumpAndSettle();
      expect(viewer.controller!.pageNumber, 2);
      final document = await pdfrx.PdfDocument.openFile(file.path);
      final links = await document.pages.first.loadLinks();
      expect(links, isNotEmpty);
      await viewer.controller!.goToPage(pageNumber: 1, duration: Duration.zero);
      viewer.params.linkHandlerParams!.onLinkTap(links.first);
      await tester.pumpAndSettle();
      expect(viewer.controller!.pageNumber, 2);
      await document.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'Library folders and tags persist across reopen and filter searches',
    (tester) async {
      final root = await getApplicationDocumentsDirectory(),
          dir = Directory('${root.path}/pdfs');
      await dir.create(recursive: true);
      final file = await File('${dir.path}/organize-v103.txt')
          .writeAsString('Reader organization test.');
      await File('${dir.path}/library-preferences.json')
          .writeAsString(jsonEncode({'sortOrder': 'newest', 'filter': 'All'}));
      await File('${dir.path}/documents.json').writeAsString(
        jsonEncode([
          {
            'name': 'Organize.txt',
            'kind': 'TXT',
            'size': '1 KB',
            'date': '21/10/2026',
            'path': file.path,
            'isFavorite': true,
          },
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(home: app.HomePage(onDarkModeChanged: (_) {})),
      );
      await until(
        tester,
        () => find.text('Organize.txt').evaluate().isNotEmpty,
      );
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Folder and tags'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'Work');
      await tester.enterText(
        find.byType(TextFormField).last,
        'Invoice, Sinhala',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate((w) => w is DropdownButton<String>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'invoice');
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Organize.txt'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(
        MaterialApp(home: app.HomePage(onDarkModeChanged: (_) {})),
      );
      await until(
        tester,
        () => find.text('Organize.txt').evaluate().isNotEmpty,
      );
      final rows = jsonDecode(
        await File('${dir.path}/documents.json').readAsString(),
      ) as List;
      expect(rows.single['folder'], 'Work');
      expect(rows.single['tags'], ['Invoice', 'Sinhala']);
      expect(rows.single['isFavorite'], isTrue);
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byWidgetPredicate((w) => w is DropdownButton<String>),
            )
            .value,
        'folder:Work',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'Bundled English and Sinhala OCR recognize actual raster PDF pages offline',
    (tester) async {
      await (FontLoader('Sara OCR Sinhala')..addFont(
            rootBundle.load('assets/fonts/NotoSansSinhala-Regular.ttf'),
          ))
          .load();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.white, BlendMode.src);
      void line(String text, double top, String? font) {
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              color: Colors.black,
              fontSize: 64,
              fontFamily: font,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 1700);
        painter.paint(canvas, Offset(60, top));
        painter.dispose();
      }

      line('SARA READER OFFLINE TEST', 60, null);
      line('Invoice 12345', 190, null);
      line('සිංහල භාෂාව', 320, 'Sara OCR Sinhala');
      final picture = recorder.endRecording(),
          image = await picture.toImage(1800, 500);
      picture.dispose();
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      final pdf = pw.Document();
      pdf.addPage(
        pw.Page(
          pageFormat: const PdfPageFormat(900, 250),
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(pw.MemoryImage(data), fit: pw.BoxFit.fill),
        ),
      );
      final bytes = await pdf.save();
      final english = await tester.runAsync(
        () => OfflineSinhalaOcr.recognize(bytes, 1, language: 'eng'),
      );
      expect(english!.text.toUpperCase(), contains('READER'));
      final combined = await tester.runAsync(
        () => OfflineSinhalaOcr.recognize(bytes, 1, language: 'sin+eng'),
      );
      expect(combined!.text, isNotEmpty);
      expect(RegExp(r'[\u0D80-\u0DFF]').hasMatch(combined.text), isTrue);
    },
  );
}
