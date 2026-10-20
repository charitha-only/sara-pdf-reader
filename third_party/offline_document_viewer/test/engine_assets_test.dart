import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Structural checks on the bundled assets.
///
/// The JavaScript here is shipped as an asset, so nothing in the Dart
/// toolchain ever parses it: a syntax error surfaces only as a blank document
/// on a device. Real parsing needs a JavaScript engine and lives in
/// `tool/check_js.sh`, which CI runs; what can be checked from Dart are the
/// structural rules that have actually bitten:
///
/// * every shell keeps its `__CSP__` placeholder, and
/// * no shell uses an inline `<script>`, which the strict policy blocks
///   silently — the page loads, nothing runs, and no error is reported.
void main() {
  final List<File> scripts = Directory('assets')
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.js'))
      .toList();

  test('every bundled script is present', () {
    expect(scripts, isNotEmpty);
  });

  group('every fixed-width format scales to the viewport', () {
    // Word pages, slides and spreadsheets are all authored at a fixed width
    // that is far wider than a phone. Without an explicit fit the document
    // reads as broken — content pushed off-screen, columns apparently
    // misaligned — and it looks like a rendering failure rather than a
    // zoom problem. This was missed for spreadsheets once already.
    for (final String shell in <String>['docx', 'pptx', 'xlsx']) {
      test(shell, () {
        final String source =
            File('assets/viewers/$shell.js').readAsStringSync();
        expect(
          source,
          contains('fitToWidth'),
          reason: '$shell.js must scale its content to the viewport',
        );
      });
    }
  });

  group('shells declare the CSP placeholder and load their logic externally',
      () {
    final List<File> shells = Directory('assets/viewers')
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.html'))
        .toList();

    for (final File file in shells) {
      test(file.path.split('/').last, () {
        final String html = file.readAsStringSync();
        expect(html, contains('__CSP__'));
        // Inline scripts are silently blocked by the strict CSP, so shell
        // logic always lives in a separate file.
        expect(
          RegExp(r'<script(?![^>]*\ssrc=)[^>]*>').hasMatch(html),
          isFalse,
          reason: 'inline <script> is blocked by the content security policy',
        );
      });
    }
  });
}
