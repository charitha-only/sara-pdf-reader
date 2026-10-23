import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// One small atomic record per library file; document contents are never saved here.
class ReadingStateStore {
  static Future<void> _writes = Future<void>.value();
  static Map<String, dynamic> sanitize(Map<String, dynamic> value) {
    double number(String key, double maximum) {
      final raw = value[key];
      if (raw is! num || !raw.isFinite) return 0;
      return raw.toDouble().clamp(0, maximum);
    }

    return {
      'unit': number('unit', 200000).toInt(),
      if (value.containsKey('viewTurns'))
        'viewTurns': number('viewTurns', 3).toInt(),
      'scroll': number('scroll', 1),
      'horizontal': number('horizontal', 10000000),
      'mode':
          const {
            'actual',
            'width',
            'page',
            '0.5',
            '0.75',
            '1.25',
            '1.5',
            '2',
            '3',
          }.contains(value['mode'])
          ? value['mode']
          : 'width',
    };
  }

  static Future<void> clear() async {
    await _writes;
    final root = await getApplicationSupportDirectory();
    final directory = Directory('${root.path}/reader-state');
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  static Future<File> _file(String path) async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory('${root.path}/reader-state');
    await directory.create(recursive: true);
    return File('${directory.path}/${sha256.convert(utf8.encode(path))}.json');
  }

  static Future<Map<String, dynamic>> load(String path) async {
    try {
      await _writes;
      final file = await _file(path);
      if (!await file.exists()) return {};
      return sanitize(
        Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map),
      );
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(String path, Map<String, dynamic> value) {
    final snapshot = jsonEncode(sanitize(value));
    final write = _writes.then((_) async {
      final file = await _file(path);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(file.path);
    });
    _writes = write.catchError((Object _) {});
    return write;
  }
}
