import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_document_viewer/src/engine/compound_file.dart';
import 'package:offline_document_viewer/src/engine/legacy_text.dart';
import 'package:offline_document_viewer/src/engine/rtf_converter.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

Uint8List _rtf(String source) => Uint8List.fromList(source.codeUnits);

void main() {
  group('RTF', () {
    test('keeps paragraphs, emphasis and alignment', () {
      final String html = RtfConverter.toHtml(
        _rtf(r'{\rtf1\ansi \pard\qc\b Title\b0\par \pard Body \i word\i0 .\par}'),
      );
      expect(html, contains('text-align:center'));
      expect(html, contains('<strong>Title</strong>'));
      expect(html, contains('<em>word</em>'));
    });

    test('coalesces a run instead of wrapping every character', () {
      final String html =
          RtfConverter.toHtml(_rtf(r'{\rtf1\ansi \b bold text\b0\par}'));
      expect(html, contains('<strong>bold text</strong>'));
      // The naive implementation produced one wrapper per letter.
      expect(html.split('<strong>').length - 1, 1);
    });

    test('resolves colour indices against the auto entry', () {
      // The leading `;` is RTF's "auto" colour and occupies index 0, so the
      // first real colour is index 1.
      final String html = RtfConverter.toHtml(
        _rtf(
          r'{\rtf1\ansi{\colortbl ;\red192\green57\blue43;}'
          r'\cf1 red\cf0 plain\par}',
        ),
      );
      expect(html, contains('color:#c0392b'));
    });

    test('decodes unicode escapes and skips their fallback character', () {
      final String html =
          RtfConverter.toHtml(_rtf(r'{\rtf1\ansi \u351?rnek\par}'));
      expect(html, contains('şrnek'));
      expect(html, isNot(contains('?')));
    });

    test('drops metadata destinations', () {
      final String html = RtfConverter.toHtml(
        _rtf(r'{\rtf1\ansi{\fonttbl{\f0 Calibri;}}{\info{\author Someone}}Body\par}'),
      );
      expect(html, contains('Body'));
      expect(html, isNot(contains('Calibri')));
      expect(html, isNot(contains('Someone')));
    });

    test('survives malformed input without throwing', () {
      expect(
        () => RtfConverter.toHtml(_rtf(r'{\rtf1\ansi \b unclosed group')),
        returnsNormally,
      );
      expect(
        () => RtfConverter.toHtml(Uint8List.fromList(<int>[0xFF, 0x00, 0x7B])),
        returnsNormally,
      );
    });

    test('treats a backslash-newline as a paragraph mark', () {
      // Cocoa and TextEdit write breaks this way instead of `\par`.
      final String html =
          RtfConverter.toHtml(_rtf('{\\rtf1\\ansi First\\\nSecond\\\n}'));
      expect(html.split('<p').length - 1, 2);
    });

    test('reads a real file produced by another writer', () {
      final String html = RtfConverter.toHtml(_fixture('sample.rtf'));
      expect(html, contains('Madde bir'));
      expect(html, contains('ğüşiöç'));
      // The fixture has a heading, body text, two bullets and a centred line;
      // collapsing them into one block was a real regression.
      expect(html.split('<p').length - 1, greaterThan(3));
    });
  });

  group('compound file', () {
    test('enumerates the streams of a real .xls', () {
      final CompoundFile? cfb = CompoundFile.parse(_fixture('sample.xls'));
      expect(cfb, isNotNull);
      expect(cfb!.streamNames, contains('Workbook'));
    });

    test('returns null for anything that is not a compound file', () {
      expect(CompoundFile.parse(_fixture('sample.xlsx')), isNull);
      expect(CompoundFile.parse(Uint8List(16)), isNull);
    });

    test('reads a stream back', () {
      final CompoundFile cfb = CompoundFile.parse(_fixture('sample.xls'))!;
      final Uint8List? workbook = cfb.read('Workbook');
      expect(workbook, isNotNull);
      expect(workbook!.length, greaterThan(0));
      expect(cfb.read('NoSuchStream'), isNull);
    });
  });

  group('legacy text extraction', () {
    test('pulls paragraphs out of a real .doc', () {
      final List<String> paragraphs =
          LegacyTextExtractor.extractDoc(_fixture('sample.doc'));
      expect(paragraphs, isNotEmpty);
      final String text = paragraphs.join(' ');
      expect(text, contains('Madde bir'));
      // Turkish characters arriving as digits and punctuation is the
      // signature of UTF-16 text being read one byte at a time.
      expect(text, contains('ğüşiöç'));
      expect(text, isNot(contains('kal1n')));
    });

    test('reads slide text from a .ppt, skipping master and notes', () {
      final List<String> lines =
          LegacyTextExtractor.extractPpt(_fixture('sample.ppt'));
      expect(lines, isNotEmpty);
      // Master placeholders and PowerPoint's internal version stamps are not
      // content and must not leak into the output.
      expect(
        lines.any((String l) => l.contains('Click to edit Master')),
        isFalse,
      );
      expect(lines.any((String l) => l.startsWith('___PPT')), isFalse);
      expect(lines, contains('ğüşiöçİĞÜŞÖÇ'));
    });

    test('returns nothing rather than throwing on a non-doc', () {
      expect(
        LegacyTextExtractor.extractDoc(_fixture('sample.xlsx')),
        isEmpty,
      );
      expect(LegacyTextExtractor.extractPpt(Uint8List(600)), isEmpty);
    });
  });
}
