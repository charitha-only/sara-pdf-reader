import 'backup_archive.dart';
import 'reading_state.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import 'task_progress.dart';

class LibraryBackup {
  static const maximumBytes = 512 * 1024 * 1024;
  static Future<Uint8List> create(
    List<Map<String, dynamic>> documents, {
    TaskProgress? progress,
  }) async {
    if (documents.length > 2000) {
      throw const FormatException('Back up at most 2,000 documents at once.');
    }
    final temp = await Directory.systemTemp.createTemp('sara-backup-');
    final zipFile = File('${temp.path}/library.zip');
    final writer = ZipFileEncoder();
    var opened = false;
    final entries = <Map<String, dynamic>>[];
    var size = 0;
    try {
      writer.create(zipFile.path);
      opened = true;
      for (var i = 0; i < documents.length; i++) {
        await progress?.step(
          'Backing up document ${i + 1} of ${documents.length}',
          done: i,
          total: documents.length,
        );
        final item = documents[i], path = item['path'];
        if (path is! String) {
          throw const FormatException('A library document has no file.');
        }
        final file = File(path),
            stat = await File(path).stat(),
            length = await File(path).length();
        size += length;
        if (length > 256 * 1024 * 1024 || size > maximumBytes) {
          throw const FormatException(
            'Backup documents exceed the size limit.',
          );
        }
        final extension = path.split('.').last.toLowerCase();
        if (!RegExp(
          r'^(pdf|epub|docx|xlsx|pptx|txt|plain|doc|xls|ppt|rtf|csv|tsv|docm|xlsm|pptm|png|jpg|jpeg|webp|gif|bmp)$',
        ).hasMatch(extension)) {
          throw const FormatException('Unsupported library file.');
        }
        final hash = await sha256.bind(file.openRead()).first;
        progress?.check();
        final payload = 'files/$i.$extension';
        await writer.addFile(file, payload);
        final after = await file.stat();
        if (after.size != length || after.modified != stat.modified) {
          throw const FormatException(
            'A document changed during backup. Try again.',
          );
        }
        entries.add({
          ...item,
          'path': null,
          'payload': payload,
          'sha256': hash.toString(),
          'viewerState': await ReadingStateStore.load(path),
        });
      }
      final manifest = utf8.encode(
        jsonEncode({'version': 1, 'documents': entries}),
      );
      if (manifest.length > 1024 * 1024) {
        throw const FormatException('Backup reading data exceeds the limit.');
      }
      writer.addArchiveFile(
        ArchiveFile('manifest.json', manifest.length, manifest),
      );
      await writer.close();
      opened = false;
      progress?.check();
      if (await zipFile.length() > maximumBytes + 1024 * 1024) {
        throw const FormatException('Backup exceeds the file-size limit.');
      }
      return await zipFile.readAsBytes();
    } finally {
      if (opened) writer.closeSync();
      await temp.delete(recursive: true);
    }
  }

  /// Validate bounded private staging files before committing app-owned copies.
  static Future<List<Map<String, dynamic>>> restore(
    Uint8List bytes,
    Directory destination, {
    TaskProgress? progress,
  }) async {
    if (bytes.length > maximumBytes + 1024 * 1024) {
      throw const FormatException('This backup is too large.');
    }
    validateBackupArchive(bytes);
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.files.map((f) => f.name).toSet().length != archive.length) {
      throw const FormatException('Duplicate backup entries.');
    }
    if (archive.length > 2001 ||
        archive.files.fold<int>(0, (v, f) => v + f.size) >
            maximumBytes + 1024 * 1024) {
      throw const FormatException('Backup contents exceed the limit.');
    }
    final manifest = archive.findFile('manifest.json');
    if (manifest == null || manifest.size > 1024 * 1024) {
      throw const FormatException('Invalid backup manifest.');
    }
    final staging = await Directory.systemTemp.createTemp('sara-restore-');
    try {
      Future<File> inflate(ArchiveFile entry, String name) async {
        final file = File('${staging.path}/$name');
        final output = BoundedBackupOutput(file.path, entry.size);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        if (await file.length() != entry.size) {
          throw const FormatException('Backup entry size mismatch.');
        }
        entry.clear();
        return file;
      }

      final manifestFile = await inflate(manifest, 'manifest.json');
      final data = jsonDecode(await manifestFile.readAsString());
      if (data is! Map || data['version'] != 1 || data['documents'] is! List) {
        throw const FormatException('Unsupported backup version.');
      }
      final entries = (data['documents'] as List);
      if (entries.length > 2000) {
        throw const FormatException('Too many backup documents.');
      }
      final prepared =
          <({Map<String, dynamic> item, File file, String name})>[];
      final seen = <String>{};
      for (var i = 0; i < entries.length; i++) {
        await progress?.step(
          'Checking backup ${i + 1} of ${entries.length}',
          done: i,
          total: entries.length,
        );
        final raw = entries[i];
        if (raw is! Map) {
          throw const FormatException('Invalid backup document.');
        }
        final item = Map<String, dynamic>.from(raw), payload = item['payload'];
        if (payload is! String ||
            !RegExp(
              r'^files/\d+\.(pdf|epub|docx|xlsx|pptx|txt|plain|doc|xls|ppt|rtf|csv|tsv|docm|xlsm|pptm|png|jpg|jpeg|webp|gif|bmp)$',
            ).hasMatch(payload) ||
            !seen.add(payload)) {
          throw const FormatException('Invalid backup file path.');
        }
        final file = archive.findFile(payload);
        if (file == null) {
          throw const FormatException('A backup document is missing.');
        }
        final stagedFile = await inflate(file, 'payload-$i');
        final hash = await sha256.bind(stagedFile.openRead()).first;
        if (hash.toString() != item['sha256']) {
          throw const FormatException(
            'A backup document checksum does not match.',
          );
        }
        if (item['name'] is! String ||
            item['kind'] is! String ||
            (await stagedFile.length() == 0 && item['kind'] != 'TXT')) {
          throw const FormatException('Invalid backup document details.');
        }
        if (item['size'] is! String ||
            item['date'] is! String ||
            (item['lastPage'] != null && item['lastPage'] is! num) ||
            (item['lastOpenedAt'] != null && item['lastOpenedAt'] is! num) ||
            (item['bookmarks'] != null && item['bookmarks'] is! List) ||
            (item['folder'] != null && item['folder'] is! String) ||
            (item['tags'] != null &&
                (item['tags'] is! List ||
                    (item['tags'] as List).any((v) => v is! String))) ||
            (item['isFavorite'] != null && item['isFavorite'] is! bool)) {
          throw const FormatException('Invalid reading data in backup.');
        }
        final extension = payload.split('.').last;
        prepared.add((
          item: item,
          file: stagedFile,
          name: 'document-$i.$extension',
        ));
      }
      progress?.check();
      await destination.create(recursive: true);
      final stamp = DateTime.now().microsecondsSinceEpoch,
          written = <File>[],
          restored = <Map<String, dynamic>>[];
      try {
        for (var i = 0; i < prepared.length; i++) {
          await progress?.step(
            'Restoring ${i + 1} of ${prepared.length}',
            done: i,
            total: prepared.length,
          );
          final entry = prepared[i],
              file = File(
                '${destination.path}${Platform.pathSeparator}restored-$stamp-$i-${entry.name}',
              );
          written.add(file);
          await entry.file.copy(file.path);
          final item = {...entry.item, 'path': file.path}
            ..remove('payload')
            ..remove('sha256');
          final viewerState = item.remove('viewerState');
          if (viewerState is Map) {
            try {
              await ReadingStateStore.save(
                file.path,
                Map<String, dynamic>.from(viewerState),
              );
            } catch (_) {
              /* Reading state is optional on non-device test hosts. */
            }
          }
          restored.add(item);
        }
        progress?.check();
        return restored;
      } catch (_) {
        for (final file in written) {
          if (await file.exists()) await file.delete();
        }
        rethrow;
      }
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
