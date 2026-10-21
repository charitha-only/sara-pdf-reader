import 'dart:convert';
import 'dart:io';

class LibraryIndex {
  static List<Map<String, dynamic>> decode(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! List || decoded.length > 20000) {
      throw const FormatException('Invalid document library.');
    }
    return decoded
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> read(File file) async {
    for (final candidate in [file, File('${file.path}.bak')]) {
      try {
        if (await candidate.exists()) {
          return decode(await candidate.readAsString());
        }
      } on FormatException {
        /* Recover the previous valid snapshot. */
      } on FileSystemException {
        /* Continue with the backup. */
      }
    }
    throw const FormatException('No readable library index.');
  }

  static Future<void> write(File file, String snapshot) async {
    decode(snapshot);
    if (await file.exists()) {
      try {
        decode(await file.readAsString());
        await file.copy('${file.path}.bak');
      } on FormatException {
        /* Keep a valid backup instead of copying a corrupt index. */
      }
    }
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(snapshot, flush: true);
    await tmp.rename(file.path);
  }
}
