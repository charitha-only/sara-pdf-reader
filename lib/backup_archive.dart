import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

void validateBackupArchive(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  int u16(int p) => data.getUint16(p, Endian.little);
  int u32(int p) => data.getUint32(p, Endian.little);
  if (bytes.length < 22) {
    throw const FormatException('Truncated backup archive.');
  }
  var end = -1;
  for (var p = bytes.length - 22; p >= 0 && p >= bytes.length - 65557; p--) {
    if (u32(p) == 0x06054b50 && p + 22 + u16(p + 20) == bytes.length) {
      end = p;
      break;
    }
  }
  if (end < 0 || u16(end + 4) != 0 || u16(end + 6) != 0) {
    throw const FormatException('Unsupported backup archive.');
  }
  final count = u16(end + 10), offset = u32(end + 16), size = u32(end + 12);
  if (count < 1 ||
      count > 2001 ||
      u16(end + 8) != count ||
      offset + size != end) {
    throw const FormatException('Invalid backup directory.');
  }
  var p = offset, total = 0;
  final names = <String>{};
  for (var i = 0; i < count; i++) {
    if (p + 46 > end || u32(p) != 0x02014b50) {
      throw const FormatException('Invalid backup entry.');
    }
    final flags = u16(p + 8),
        method = u16(p + 10),
        compressed = u32(p + 20),
        expanded = u32(p + 24),
        nameLength = u16(p + 28),
        extra = u16(p + 30),
        comment = u16(p + 32),
        local = u32(p + 42);
    if ((flags & 1) != 0 ||
        !const [0, 8].contains(method) ||
        expanded > 256 * 1024 * 1024 ||
        p + 46 + nameLength + extra + comment > end ||
        local + 30 > offset ||
        u32(local) != 0x04034b50) {
      throw const FormatException('Unsupported backup entry.');
    }
    final name = utf8.decode(bytes.sublist(p + 46, p + 46 + nameLength));
    if (!names.add(name) ||
        !(name == 'manifest.json' ||
            RegExp(
              r'^files/\d+\.(pdf|epub|docx|xlsx|pptx|txt|plain|doc|xls|ppt|rtf|csv|tsv|docm|xlsm|pptm|png|jpg|jpeg|webp|gif|bmp)$',
            ).hasMatch(name))) {
      throw const FormatException('Invalid backup path.');
    }
    if (name == 'manifest.json' && expanded > 1024 * 1024) {
      throw const FormatException('Backup manifest too large.');
    }
    total += expanded;
    if (total > 512 * 1024 * 1024 + 1024 * 1024) {
      throw const FormatException('Backup contents exceed the limit.');
    }
    if (((u32(p + 38) >> 16) & 0xf000) == 0xa000) {
      throw const FormatException('Backup symbolic links are unsupported.');
    }
    final localNameLength = u16(local + 26), localExtra = u16(local + 28);
    final payload = local + 30 + localNameLength + localExtra;
    if (payload > offset ||
        u16(local + 6) != flags ||
        u16(local + 8) != method ||
        utf8.decode(bytes.sublist(local + 30, local + 30 + localNameLength)) !=
            name) {
      throw const FormatException('Backup entry headers disagree.');
    }
    void checkExtra(int start, int length) {
      var cursor = start;
      final end = start + length;
      while (cursor < end) {
        if (cursor + 4 > end) {
          throw const FormatException('Invalid backup extra field.');
        }
        final id = u16(cursor), n = u16(cursor + 2);
        cursor += 4;
        if (id == 1 || id == 0x9901 || cursor + n > end) {
          throw const FormatException('Unsupported backup extra field.');
        }
        cursor += n;
      }
    }

    checkExtra(local + 30 + localNameLength, localExtra);
    checkExtra(p + 46 + nameLength, extra);
    if (payload + compressed > offset) {
      throw const FormatException('Truncated backup payload.');
    }
    p += 46 + nameLength + extra + comment;
  }
  if (p != end) throw const FormatException('Backup directory size mismatch.');
}

/// Enforce the declared limit during inflation, including dishonest ZIP headers.
class BoundedBackupOutput extends OutputFileStream {
  BoundedBackupOutput(String path, this.limit)
    : super.withFileHandle(FileHandle(path, mode: FileAccess.write));
  final int limit;
  int written = 0;
  void reserve(int count) {
    if (count < 0 || written + count > limit) {
      throw const FormatException(
        'Expanded backup entry exceeds its declared size.',
      );
    }
    written += count;
  }

  @override
  void writeByte(int value) {
    reserve(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    reserve(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }
}
