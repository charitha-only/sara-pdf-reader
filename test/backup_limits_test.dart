import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/backup_archive.dart';
import 'package:pageflow_reader/library_backup.dart';

void main() {
  test('Backup central directory rejects excess declared expansion before inflation', () {
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', 2, [123, 125]));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    validateBackupArchive(bytes);
    final data = ByteData.sublistView(bytes);
    for (var p = 0; p < bytes.length - 46; p++) {
      if (data.getUint32(p, Endian.little) == 0x02014b50) {
        data.setUint32(p + 24, 300 * 1024 * 1024, Endian.little);
        break;
      }
    }
    expect(() => validateBackupArchive(bytes), throwsFormatException);
  });
  test(
    'Backup directory rejects symbolic links before decoder can inflate them',
    () {
      final archive = Archive()
        ..addFile(ArchiveFile('manifest.json', 2, [123, 125]));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      final data = ByteData.sublistView(bytes);
      for (var p = 0; p < bytes.length - 46; p++) {
        if (data.getUint32(p, Endian.little) == 0x02014b50) {
          data.setUint32(p + 38, 0xa1ff0000, Endian.little);
          break;
        }
      }
      expect(() => validateBackupArchive(bytes), throwsFormatException);
    },
  );
  test('Backup directory rejects inconsistent local compression headers', () {
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', 2, [123, 125]));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    ByteData.sublistView(bytes).setUint16(8, 99, Endian.little);
    expect(() => validateBackupArchive(bytes), throwsFormatException);
  });
  test(
    'Restore stops real deflate expansion beyond dishonest declared size',
    () async {
      final archive = Archive()
        ..addFile(
          ArchiveFile('manifest.json', 200000, List.filled(200000, 65)),
        );
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      final data = ByteData.sublistView(bytes);
      for (var p = 0; p < bytes.length - 46; p++) {
        if (data.getUint32(p, Endian.little) == 0x02014b50) {
          data.setUint32(p + 24, 4, Endian.little);
          break;
        }
      }
      validateBackupArchive(bytes);
      final root = await Directory.systemTemp.createTemp('sara-deflate');
      try {
        await expectLater(
          LibraryBackup.restore(bytes, Directory('${root.path}/restore')),
          throwsFormatException,
        );
        expect(await Directory('${root.path}/restore').exists(), false);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'Inflation output rejects actual writes beyond a dishonest declared size',
    () async {
      final root = await Directory.systemTemp.createTemp('sara-bound');
      final output = BoundedBackupOutput('${root.path}/entry', 4);
      try {
        output.writeBytes([1, 2, 3, 4]);
        expect(() => output.writeByte(5), throwsFormatException);
        expect(output.written, 4);
      } finally {
        output.closeSync();
        await root.delete(recursive: true);
      }
    },
  );
  test('Empty text files survive manual backup and restore', () async {
    final root = await Directory.systemTemp.createTemp('sara-empty-backup');
    try {
      final file = File('${root.path}/empty.txt');
      await file.writeAsString('');
      final bytes = await LibraryBackup.create([
        {
          'name': 'empty.txt',
          'kind': 'TXT',
          'size': '0 B',
          'date': '',
          'path': file.path,
        },
      ]);
      final restored = await LibraryBackup.restore(
        bytes,
        Directory('${root.path}/restored'),
      );
      expect(await File(restored.single['path'] as String).length(), 0);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
