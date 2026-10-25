import 'package:pageflow_reader/task_progress.dart';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/library_tools.dart';

void main() {
  test(
    'Library query supports phrases, tags, kinds and exclusion together',
    () {
      bool match(String q) => LibraryQuery(q).matches(
        name: 'Tax Report 2026.pdf',
        kind: 'PDF',
        folder: 'Work',
        tags: ['tax', 'paid'],
      );
      expect(match('report type:pdf tag:paid -draft'), true);
      expect(match('tag:unpaid'), false);
      expect(match('folder:work "tax report"'), true);
      expect(match('-type:pdf'), false);
    },
  );
  test('Duplicate finder compares contents rather than names and skips missing files', () async {
    final root = await Directory.systemTemp.createTemp('sara-dupes');
    try {
      final a = File('${root.path}/a.pdf'),
          b = File('${root.path}/b.pdf'),
          c = File('${root.path}/c.pdf');
      await a.writeAsString('same');
      await b.writeAsString('same');
      await c.writeAsString('diff');
      final groups = await findLibraryDuplicates([
        a.path,
        b.path,
        c.path,
        a.path,
        '${root.path}/missing',
      ]);
      expect(groups.length, 1);
      expect(groups.single.toSet(), {a.path, b.path});
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('Duplicate comparison honours cancellation before scanning', () async {
    final progress = TaskProgress()..cancel();
    await expectLater(
      findLibraryDuplicates(['not-read'], progress: progress),
      throwsA(isA<TaskCancelled>()),
    );
    progress.dispose();
  });
}
