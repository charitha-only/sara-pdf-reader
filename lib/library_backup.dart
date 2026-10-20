import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'task_progress.dart';

class LibraryBackup {
  static const maximumBytes = 512 * 1024 * 1024;
  static Future<Uint8List> create(
    List<Map<String, dynamic>> documents, {
    TaskProgress? progress,
  }) async {
    final archive = Archive(), entries = <Map<String, dynamic>>[];
    var size = 0;
    if (documents.length > 2000) {
      throw const FormatException('Back up at most 2,000 documents at once.');
    }
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
      final file = File(path), length = await file.length();
      size += length;
      if (size > maximumBytes) {
        throw const FormatException(
          'A backup can contain up to 512 MB of documents.',
        );
      }
      final bytes = await file.readAsBytes();
      progress?.check();
      final extension = path.split('.').last.toLowerCase();
      if (![
        'pdf',
        'docx',
        'xlsx',
        'pptx',
        'txt',
        'plain',
        'doc',
        'xls',
        'ppt',
        'rtf',
        'csv',
        'tsv',
        'docm',
        'xlsm',
        'pptm',
        'png',
        'jpg',
        'jpeg',
        'webp',
        'gif',
        'bmp',
      ].contains(extension)) {
        throw const FormatException('Unsupported library file.');
      }
      final payload = 'files/$i.$extension';
      archive.addFile(ArchiveFile(payload, bytes.length, bytes));
      entries.add({
        ...item,
        'path': null,
        'payload': payload,
        'sha256': sha256.convert(bytes).toString(),
      });
    }
    final manifest = utf8.encode(
      jsonEncode({'version': 1, 'documents': entries}),
    );
    archive.addFile(ArchiveFile('manifest.json', manifest.length, manifest));
    await progress?.step('Packing backup…');
    final output = Uint8List.fromList(ZipEncoder().encode(archive));
    progress?.check();
    return output;
  }

  /// Writes app-owned copies only after every payload and checksum validates.
  static Future<List<Map<String, dynamic>>> restore(
    Uint8List bytes,
    Directory destination, {
    TaskProgress? progress,
  }) async {
    if (bytes.length > maximumBytes + 1024 * 1024) {
      throw const FormatException('This backup is too large.');
    }
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
    final data = jsonDecode(utf8.decode(manifest.content));
    if (data is! Map || data['version'] != 1 || data['documents'] is! List) {
      throw const FormatException('Unsupported backup version.');
    }
    final entries = (data['documents'] as List);
    if (entries.length > 2000) {
      throw const FormatException('Too many backup documents.');
    }
    final prepared =
        <({Map<String, dynamic> item, Uint8List bytes, String name})>[];
    final seen = <String>{};
    for (var i = 0; i < entries.length; i++) {
      await progress?.step(
        'Checking backup ${i + 1} of ${entries.length}',
        done: i,
        total: entries.length,
      );
      final raw = entries[i];
      if (raw is! Map) throw const FormatException('Invalid backup document.');
      final item = Map<String, dynamic>.from(raw), payload = item['payload'];
      if (payload is! String ||
          !RegExp(
            r'^files/\d+\.(pdf|docx|xlsx|pptx|txt|plain|doc|xls|ppt|rtf|csv|tsv|docm|xlsm|pptm|png|jpg|jpeg|webp|gif|bmp)$',
          ).hasMatch(payload) ||
          !seen.add(payload)) {
        throw const FormatException('Invalid backup file path.');
      }
      final file = archive.findFile(payload);
      if (file == null) {
        throw const FormatException('A backup document is missing.');
      }
      final content = Uint8List.fromList(file.content);
      if (sha256.convert(content).toString() != item['sha256']) {
        throw const FormatException(
          'A backup document checksum does not match.',
        );
      }
      if (item['name'] is! String ||
          item['kind'] is! String ||
          content.isEmpty) {
        throw const FormatException('Invalid backup document details.');
      }
      if (item['size'] is! String ||
          item['date'] is! String ||
          (item['lastPage'] != null && item['lastPage'] is! num) ||
          (item['lastOpenedAt'] != null && item['lastOpenedAt'] is! num) ||
          (item['bookmarks'] != null && item['bookmarks'] is! List) ||
          (item['isFavorite'] != null && item['isFavorite'] is! bool)) {
        throw const FormatException('Invalid reading data in backup.');
      }
      final extension = payload.split('.').last;
      prepared.add((
        item: item,
        bytes: content,
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
        await file.writeAsBytes(entry.bytes, flush: true);
        final item = {...entry.item, 'path': file.path}
          ..remove('payload')
          ..remove('sha256');
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
  }
}
