import 'dart:io';

import 'package:crypto/crypto.dart';

import 'task_progress.dart';

class LibraryQuery {
  LibraryQuery(String input)
    : tokens = RegExp(r'"([^"]*)"|(\S+)')
          .allMatches(input.length > 512 ? input.substring(0, 512) : input)
          .take(32)
          .map((m) => (m[1] ?? m[2]!).toLowerCase())
          .toList();
  final List<String> tokens;
  bool matches({
    required String name,
    required String kind,
    required String folder,
    required List<String> tags,
  }) {
    final text = '$name $folder ${tags.join(' ')}'.toLowerCase();
    return tokens.every((raw) {
      final exclude = raw.startsWith('-');
      final token = exclude ? raw.substring(1) : raw;
      bool hit;
      if (token.startsWith('tag:')) {
        hit = tags.any((t) => t.toLowerCase() == token.substring(4));
      } else if (token.startsWith('folder:')) {
        hit = folder.toLowerCase().contains(token.substring(7));
      } else if (token.startsWith('type:')) {
        final type = token.substring(5);
        hit =
            kind.toLowerCase() == type || name.toLowerCase().endsWith('.$type');
      } else {
        hit = text.contains(token);
      }
      return exclude ? !hit : hit;
    });
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest digest) {
    value = digest;
  }

  @override
  void close() {}
}

Future<List<List<String>>> findLibraryDuplicates(
  List<String> paths, {
  TaskProgress? progress,
}) async {
  final sizes = <int, List<String>>{};
  final unique = paths.toSet().take(20000).toList();
  for (var i = 0; i < unique.length; i++) {
    await progress?.step(
      'Checking file ${i + 1} of ${unique.length}',
      done: i,
      total: unique.length,
    );
    try {
      final length = await File(unique[i]).length();
      if (length >= 0) sizes.putIfAbsent(length, () => []).add(unique[i]);
    } on FileSystemException {
      continue;
    }
  }
  final hashes = <String, List<String>>{};
  final candidates = sizes.values
      .where((v) => v.length > 1)
      .expand((v) => v)
      .toList();
  for (var i = 0; i < candidates.length; i++) {
    await progress?.step(
      'Comparing file ${i + 1} of ${candidates.length}',
      done: i,
      total: candidates.length,
    );
    final sink = _DigestSink();
    final hash = sha256.startChunkedConversion(sink);
    try {
      await for (final chunk in File(candidates[i]).openRead()) {
        progress?.check();
        hash.add(chunk);
      }
      hash.close();
      hashes.putIfAbsent(sink.value.toString(), () => []).add(candidates[i]);
    } on FileSystemException {
      hash.close();
      continue;
    }
  }
  return hashes.values.where((v) => v.length > 1).toList();
}
