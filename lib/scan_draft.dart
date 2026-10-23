import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

class ScanDraftStore {
  ScanDraftStore(this.root);
  final Directory root;
  static final _pending = <String, Future<void>>{};
  Future<T> _queue<T>(Future<T> Function() work) {
    final result = (_pending[root.path] ?? Future<void>.value()).then(
      (_) => work(),
    );
    _pending[root.path] = result.then<void>((_) {}).catchError((Object _) {});
    return result;
  }

  Future<void> save(List<Map<String, dynamic>> pages, int selected) => _queue(
    () => compute(_saveDraft, {
      'root': root.path,
      'pages': pages,
      'selected': selected,
    }),
  );
  Future<Map<String, dynamic>?> load() =>
      _queue(() => compute(_loadDraft, root.path));
  Future<void> clear() => _queue(() => compute(_clearDraft, root.path));
}

Future<void> _clearDraft(String path) async {
  final root = Directory(path);
  if (await root.exists()) await root.delete(recursive: true);
}

Future<Map<String, dynamic>?> _readDraft(String path, String name) async {
  final file = File('$path/$name');
  if (!await file.exists() || await file.length() > 100000) return null;
  final manifest =
      jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  if (manifest['version'] != 1) return null;
  final records = manifest['pages'] as List;
  if (records.length > 20) throw const FormatException('Too many draft pages');
  var total = 0;
  final pages = <Map<String, dynamic>>[];
  for (final raw in records) {
    final record = Map<String, dynamic>.from(raw as Map);
    for (final field in ['original', 'preview']) {
      final name = record[field] as String;
      if (!RegExp(r'^[a-f0-9]{64}\.jpg$').hasMatch(name)) {
        throw const FormatException('Invalid image name');
      }
      final file = File('$path/$name');
      total += await file.length();
      if (total > 70 * 1024 * 1024) {
        throw const FormatException('Draft too large');
      }
      final bytes = await file.readAsBytes();
      if ('${sha256.convert(bytes)}.jpg' != name) {
        throw const FormatException('Image checksum mismatch');
      }
      record[field] = bytes;
    }
    if (record['turns'] is! int ||
        (record['turns'] as int) < 0 ||
        (record['turns'] as int) > 3 ||
        record['scan'] is! bool ||
        (record['clean'] != null && record['clean'] is! bool)) {
      throw const FormatException('Invalid settings');
    }
    pages.add(record);
  }
  return {
    'pages': pages,
    'selected': manifest['selected'] is int ? manifest['selected'] : 0,
  };
}

Future<Map<String, dynamic>?> _loadDraft(String path) async {
  for (final name in ['draft.json', 'draft.json.bak']) {
    try {
      final value = await _readDraft(path, name);
      if (value != null) return value;
    } catch (_) {}
  }
  return null;
}

Future<void> _saveDraft(Map<String, dynamic> args) async {
  final pages = args['pages'] as List;
  final selected = args['selected'] as int;
  if (pages.length > 20 ||
      selected < 0 ||
      (pages.isNotEmpty && selected >= pages.length)) {
    throw const FormatException('Invalid draft selection or page count');
  }
  var total = 0;
  for (final raw in pages) {
    final page = raw as Map;
    if (page['turns'] is! int ||
        (page['turns'] as int) < 0 ||
        (page['turns'] as int) > 3 ||
        page['scan'] is! bool ||
        (page['clean'] != null && page['clean'] is! bool)) {
      throw const FormatException('Invalid draft settings');
    }
    for (final field in ['original', 'preview']) {
      final bytes = page[field] as Uint8List;
      total += bytes.length;
      if (bytes.isEmpty || total > 70 * 1024 * 1024) {
        throw const FormatException('Draft image data exceeds limits');
      }
    }
  }
  final path = args['root'] as String;
  final root = Directory(path);
  await root.create(recursive: true);
  final records = <Map<String, dynamic>>[];
  for (final raw in args['pages'] as List) {
    final page = Map<String, dynamic>.from(raw as Map);
    final record = <String, dynamic>{
      'turns': page['turns'],
      'scan': page['scan'],
      'clean': page['clean'] == true,
    };
    for (final field in ['original', 'preview']) {
      final bytes = page[field] as Uint8List;
      final name = '${sha256.convert(bytes)}.jpg';
      final file = File('$path/$name');
      if (!await file.exists() ||
          await file.length() != bytes.length ||
          sha256.convert(await file.readAsBytes()).toString() !=
              name.substring(0, 64)) {
        final temp = File('${file.path}.tmp');
        await temp.writeAsBytes(bytes, flush: true);
        await temp.rename(file.path);
      }
      record[field] = name;
    }
    records.add(record);
  }
  final target = File('$path/draft.json'), temp = File('$path/draft.json.tmp');
  await temp.writeAsString(
    jsonEncode({'version': 1, 'selected': args['selected'], 'pages': records}),
    flush: true,
  );
  try {
    if (await _readDraft(path, 'draft.json') != null) {
      await target.copy('$path/draft.json.bak');
    }
  } catch (_) {
    /* Preserve the previous backup if primary is invalid. */
  }
  await temp.rename(target.path);
  final keep = <String>{};
  for (final name in ['draft.json', 'draft.json.bak']) {
    try {
      final manifest =
          jsonDecode(await File('$path/$name').readAsString()) as Map;
      for (final page in manifest['pages'] as List) {
        keep.add(page['original'] as String);
        keep.add(page['preview'] as String);
      }
    } catch (_) {}
  }
  await for (final entry in root.list(followLinks: false)) {
    final name = entry.path.split(Platform.pathSeparator).last;
    if (entry is File &&
        RegExp(r'^[a-f0-9]{64}\.jpg(?:\.tmp)?$').hasMatch(name) &&
        !keep.contains(name)) {
      await entry.delete();
    }
  }
}
