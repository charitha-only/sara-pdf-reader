import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pageflow_reader/text_file_editor.dart';
import 'package:pageflow_reader/image_viewer.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/rendering.dart';
import 'package:pageflow_reader/main.dart' as app;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../test/support/pdf_fixture.dart';


void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Tall images preserve their shape with a bounded decode', (
    tester,
  ) async {
    final directory = await getTemporaryDirectory();
    final image = img.Image(width: 1, height: 10000);
    final file = await File('${directory.path}/tall.png')
        .writeAsBytes(img.encodePng(image));
    await tester.pumpWidget(
      MaterialApp(
        home: ImageFileViewer(path: file.path, name: 'tall.png'),
      ),
    );
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final render = find.byType(RawImage);
      if (render.evaluate().isNotEmpty &&
          tester.renderObject<RenderImage>(render).image != null) {
        break;
      }
    }
    final decoded = tester
        .renderObject<RenderImage>(find.byType(RawImage))
        .image!;
    expect(decoded.width, lessThanOrEqualTo(2560));
    expect(decoded.height, lessThanOrEqualTo(2560));
    expect(decoded.height, greaterThan(decoded.width));
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });
  testWidgets(
    'Reader launch imports PDF and exposes reading controls without editing',
    (tester) async {
      final directory = await getTemporaryDirectory();
      final bytes = fixturePdf();
      final source = await File('${directory.path}/reader-check.pdf')
          .writeAsBytes(bytes);
      final library = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/pdfs',
      );
      await library.create(recursive: true);
      final index = File('${library.path}/documents.json');
      final backup = await index.exists() ? await index.readAsBytes() : null;
      await index.writeAsString('[]');
      const picker = MethodChannel('miguelruivo.flutter.plugins.filepicker');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        picker,
        (call) async => call.method == 'custom'
            ? [
                {
                  'name': 'reader-check.pdf',
                  'path': source.path,
                  'size': bytes.length,
                },
              ]
            : null,
      );
      try {
        await tester.pumpWidget(const app.PageflowApp());
        await tester.pumpAndSettle();
        await tester.tap(find.text('Get Started'));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.note_add_outlined), findsNothing);
        await tester.tap(find.byIcon(Icons.add).first);
        for (
          var i = 0;
          i < 150 && find.byTooltip('Bookmark this page').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(find.text('Edit'), findsNothing);
        expect(find.text('Edit Tools'), findsNothing);
        expect(find.byType(pdfrx.PdfViewer), findsOneWidget);
        await tester.tap(find.byTooltip('Bookmark this page'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Remove bookmark'), findsOneWidget);
        await tester.tap(find.byTooltip('Reading options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fit page'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Document options'));
        await tester.pumpAndSettle();
        expect(find.text('Edit PDF objects and text'), findsNothing);
        expect(find.text('Share original file'), findsOneWidget);
        await tester.tapAt(const Offset(10, 300));
        await tester.pumpAndSettle();
      } finally {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, null);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        if (backup != null) {
          await index.writeAsBytes(backup);
        } else if (await index.exists()) {
          await index.delete();
        }
      }
    },
  );
  testWidgets('Reader text is selectable and cannot be changed', (
    tester,
  ) async {
    final directory = await getTemporaryDirectory();
    final file = await File('${directory.path}/reader.txt')
        .writeAsString('Sinhala සිංහල\nReader preview');
    await tester.pumpWidget(
      MaterialApp(
        home: TextFileEditor(
          directory: directory,
          path: file.path,
          displayName: 'reader.txt',
          readOnly: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    expect(await file.readAsString(), contains('සිංහල'));
  });
}
