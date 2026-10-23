List<String> bulkLibraryNames(
  List<String> originals,
  String rawPrefix, {
  Set<String> usedNames = const {},
}) {
  final prefix = rawPrefix.trim();
  if (prefix.isEmpty ||
      prefix.length > 80 ||
      RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(prefix)) {
    throw ArgumentError(
      'Use a name prefix of 1–80 characters without file-path symbols.',
    );
  }
  final used = {for (final name in usedNames) name.toLowerCase()};
  final result = <String>[];
  var number = 1;
  for (final original in originals) {
    final match = RegExp(r'\.[A-Za-z0-9]{1,12}$').firstMatch(original);
    final extension = match?.group(0) ?? '';
    String candidate;
    do {
      candidate = '$prefix ${number++}$extension';
    } while (used.contains(candidate.toLowerCase()));
    used.add(candidate.toLowerCase());
    result.add(candidate);
  }
  return result;
}
