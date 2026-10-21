import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/epub_document.dart';
import 'package:pageflow_reader/library_index.dart';
import 'package:pageflow_reader/library_backup.dart';
import 'package:pageflow_reader/reading_state.dart';

import 'support/epub_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'EPUB follows spine order, retains Sinhala/styles, and discards scripts',
    () {
      final book = EpubDocument.read(fixtureEpub());
      expect(
        EpubDocument.read(fixtureEpub(obfuscatedFont: true)).chapters.length,
        2,
      );
      expect(book.title, 'Sara test book');
      expect(book.chapters.map((c) => c.title), ['Chapter One', 'Chapter Two']);
      final blocks = book.chapters.first.blocks;
      expect(
        blocks.map((b) => b.text).join(),
        'Chapter OneSinhala සිංහල bold text and italic text.',
      );
      expect(
        blocks
            .expand((b) => b.runs)
            .any((r) => r.text == 'bold text' && r.bold),
        isTrue,
      );
      expect(
        blocks
            .expand((b) => b.runs)
            .any((r) => r.text == 'italic text' && r.italic),
        isTrue,
      );
    },
  );
  test(
    'EPUB refuses encrypted resources, traversal and damaged containers',
    () {
      expect(
        () => EpubDocument.read(fixtureEpub(encrypted: true)),
        throwsFormatException,
      );
      expect(
        () => EpubDocument.read(fixtureEpub(traversal: true)),
        throwsFormatException,
      );
      expect(
        () => EpubDocument.read(fixtureEpub().sublist(0, 50)),
        throwsA(anything),
      );
    },
  );
  test('Library upgrade snapshots recover all v1.02 reading metadata from corruption', () async {
    final dir = await Directory.systemTemp.createTemp('sara-index-');
    addTearDown(() => dir.delete(recursive: true));
    final index = File('${dir.path}/documents.json');
    final old = [
      {
        'name': 'existing.pdf',
        'path': '/private/existing.pdf',
        'kind': 'PDF',
        'lastPage': 12,
        'bookmarks': [2, 12],
        'isFavorite': true,
      },
    ];
    await LibraryIndex.write(index, jsonEncode(old));
    await LibraryIndex.write(
      index,
      jsonEncode([
        {
          ...old.first,
          'folder': 'Work',
          'tags': ['invoice', 'සිංහල'],
        },
      ]),
    );
    await index.writeAsString('broken');
    expect(await LibraryIndex.read(index), old);
    await LibraryIndex.write(index, jsonEncode(old));
    await index.writeAsString('broken again');
    expect(await LibraryIndex.read(index), old);
    await index.delete();
    expect(await LibraryIndex.read(index), old);
  });
  test(
    'EPUB backup round-trip retains folder, tags and chapter/scroll progress',
    () async {
      final dir = await Directory.systemTemp.createTemp('sara-epub-backup-');
      addTearDown(() => dir.delete(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => dir.path,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            ),
      );
      final file = await File('${dir.path}/book.epub')
          .writeAsBytes(fixtureEpub());
      await ReadingStateStore.save(file.path, {'unit': 1, 'scroll': .6});
      final bytes = await LibraryBackup.create([
        {
          'name': 'book.epub',
          'kind': 'EPUB',
          'size': '2 KB',
          'date': '21/10/2026',
          'path': file.path,
          'folder': 'Books',
          'tags': ['Sinhala'],
        },
      ]);
      final restored = await LibraryBackup.restore(
        bytes,
        Directory('${dir.path}/restored'),
      );
      expect(restored.single['folder'], 'Books');
      expect(restored.single['tags'], ['Sinhala']);
      expect(
        (await ReadingStateStore.load(
          restored.single['path'] as String,
        ))['unit'],
        1,
      );
      expect(
        await File(restored.single['path'] as String).readAsBytes(),
        await file.readAsBytes(),
      );
    },
  );
}
