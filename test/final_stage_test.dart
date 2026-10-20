import 'support/encrypted_fixture.dart';

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/library_backup.dart';
import 'package:pageflow_reader/task_progress.dart';
import 'package:pageflow_reader/app_language.dart';
import 'package:pageflow_reader/pdfium_object_editor.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'support/pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('backup restores native files and reading data; checksum tampering writes nothing', () async {
    final folder = await Directory.systemTemp.createTemp('backup-test-');
    final source = File('${folder.path}/source.pdf');
    await source.writeAsBytes(fixturePdf());
    final metadata = {
      'name': 'Original.pdf',
      'kind': 'PDF',
      'size': '2 KB',
      'date': '07/10/2026',
      'path': source.path,
      'lastPage': 2,
      'lastOpenedAt': 123,
      'bookmarks': [1, 3],
      'isFavorite': true,
    };
    try {
      final bytes = await LibraryBackup.create([metadata]);
      final target = Directory('${folder.path}/restored');
      final items = await LibraryBackup.restore(bytes, target);
      expect(items.single['bookmarks'], [1, 3]);
      expect(items.single['lastPage'], 2);
      expect(items.single['isFavorite'], isTrue);
      expect(
        await File(items.single['path'] as String).readAsBytes(),
        await source.readAsBytes(),
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      final broken = Archive();
      for (final file in archive.files) {
        final content = file.name == 'manifest.json'
            ? utf8.encode(
                utf8
                    .decode(file.content)
                    .replaceAll(
                      RegExp(r'"sha256":"[a-f0-9]+"'),
                      '"sha256":"bad"',
                    ),
              )
            : file.content;
        broken.addFile(ArchiveFile(file.name, content.length, content));
      }
      final rejected = Directory('${folder.path}/rejected');
      await expectLater(
        LibraryBackup.restore(
          Uint8List.fromList(ZipEncoder().encode(broken)),
          rejected,
        ),
        throwsFormatException,
      );
      expect(await rejected.exists(), isFalse);
      final cancelled = TaskProgress()..cancel();
      await expectLater(
        LibraryBackup.restore(bytes, rejected, progress: cancelled),
        throwsA(isA<TaskCancelled>()),
      );
      expect(await rejected.exists(), isFalse);
      cancelled.dispose();
    } finally {
      await folder.delete(recursive: true);
    }
  });
  testWidgets('cancel stops a task without exposing a success result', (
    tester,
  ) async {
    var cancelled = false, completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              try {
                await runPdfTask(context, 'Long task', (progress) async {
                  for (var i = 0; i < 100; i++) {
                    await progress.step('Step $i', done: i, total: 100);
                    await Future<void>.delayed(
                      const Duration(milliseconds: 50),
                    );
                  }
                  completed = true;
                });
              } on TaskCancelled {
                cancelled = true;
              }
            },
            child: const Text('Run'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Run'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
    expect(completed, isFalse);
    expect(find.text('Long task'), findsNothing);
  });
  test('language persists and preserves other preferences', () async {
    final folder = await Directory.systemTemp.createTemp('language-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => folder.path);
    try {
      await AppPreferences.write({'darkMode': true});

      await AppLanguage.instance.choose('si');
      expect(tr('Save copy'), 'පිටපතක් සුරකින්න');
      expect((await AppPreferences.read())['darkMode'], isTrue);
      AppLanguage.instance.value = 'en';
      await AppLanguage.instance.load();
      expect(AppLanguage.instance.value, 'si');
      await AppLanguage.instance.choose('en');
      expect(tr('Save copy'), 'Save copy');
    } finally {
      AppLanguage.instance.value = 'en';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await folder.delete(recursive: true);
    }
  });
  test(
    'AES password unlock preserves selectable content and source bytes',
    () async {
      final input = encryptedFixture();
      pdfrx.Pdfrx.cacheDirectoryPath ??= Directory.systemTemp.path;
      await expectLater(
        PdfiumObjectEditor.unlock(input, 'incorrect'),
        throwsException,
      );
      final bytes = await PdfiumObjectEditor.unlock(input, 'test-password');
      final document = await pdfrx.PdfDocument.openData(bytes);
      try {
        expect(
          (await document.pages.first.loadText())!.fullText,
          contains('Protected document'),
        );
      } finally {
        await document.dispose();
      }
      expect(encryptedFixture(), input);
    },
  );
}
