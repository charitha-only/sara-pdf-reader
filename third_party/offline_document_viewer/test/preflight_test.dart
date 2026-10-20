import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_document_viewer/offline_document_viewer.dart';

Uint8List _fixture(String name) =>
    File('test/fixtures/$name').readAsBytesSync();

void main() {
  group('accepts real documents and identifies them from content', () {
    const Map<String, DocumentFormat> cases = <String, DocumentFormat>{
      'sample.pdf': DocumentFormat.pdf,
      'sample.docx': DocumentFormat.docx,
      'sample.xlsx': DocumentFormat.xlsx,
      'edge-cases.pptx': DocumentFormat.pptx,
      'sample.xls': DocumentFormat.xls,
      'sample.rtf': DocumentFormat.rtf,
      'sample.doc': DocumentFormat.doc,
    };

    cases.forEach((String file, DocumentFormat expected) {
      test(file, () {
        final Object report = DocumentPreflight.inspect(
          bytes: _fixture(file),
          fileName: file,
        );
        expect(report, isA<PreflightReport>());
        expect((report as PreflightReport).format, expected);
      });
    });
  });

  test('content wins over a lying extension', () {
    // A spreadsheet named as a presentation must still be detected as one.
    final Object report = DocumentPreflight.inspect(
      bytes: _fixture('sample.xlsx'),
      fileName: 'not-really.pptx',
    );
    expect(report, isA<PreflightReport>());
    expect((report as PreflightReport).format, DocumentFormat.xlsx);
  });

  group('rejects hostile and broken input', () {
    test('empty file', () {
      final Object report = DocumentPreflight.inspect(
        bytes: Uint8List(0),
        fileName: 'empty.docx',
      );
      expect(report, isA<CorruptDocumentFailure>());
    });

    test('truncated archive', () {
      final Object report = DocumentPreflight.inspect(
        bytes: _fixture('malformed/truncated.docx'),
        fileName: 'truncated.docx',
      );
      expect(report, isA<CorruptDocumentFailure>());
    });

    test('valid zip that is not OOXML', () {
      final Object report = DocumentPreflight.inspect(
        bytes: _fixture('malformed/not-ooxml.docx'),
        fileName: 'not-ooxml.docx',
      );
      expect(report, isA<CorruptDocumentFailure>());
    });

    test('OOXML skeleton without a main part', () {
      final Object report = DocumentPreflight.inspect(
        bytes: _fixture('malformed/no-main-part.xlsx'),
        fileName: 'no-main-part.xlsx',
      );
      expect(report, isA<CorruptDocumentFailure>());
    });

    test('encrypted OOXML is an OLE container, not a zip', () {
      final Object report = DocumentPreflight.inspect(
        bytes: _fixture('malformed/encrypted.docx'),
        fileName: 'encrypted.docx',
      );
      expect(report, isA<EncryptedDocumentFailure>());
      expect(
        (report as EncryptedDocumentFailure).recovery,
        RecoveryHint.enterPassword,
      );
    });

    test('zip bomb is caught from declared sizes, without inflating', () {
      final Object report = DocumentPreflight.inspect(
        bytes: _fixture('malformed/zipbomb.xlsx'),
        fileName: 'zipbomb.xlsx',
      );
      expect(report, isA<SuspiciousArchiveFailure>());
      expect(
        (report as SuspiciousArchiveFailure).reason,
        SuspiciousReason.zipBomb,
      );
    });

    test('oversized input is refused before anything is parsed', () {
      final Object report = DocumentPreflight.inspect(
        bytes: Uint8List(DocumentPreflight.maxBytes + 1),
        fileName: 'huge.docx',
      );
      expect(report, isA<TooLargeFailure>());
    });

    test('unknown container', () {
      final Object report = DocumentPreflight.inspect(
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]),
        fileName: 'mystery.bin',
      );
      expect(report, isA<UnsupportedFormatFailure>());
    });
  });

  test('every failure carries a stable code and a recovery hint', () {
    const List<DocumentFailure> failures = <DocumentFailure>[
      UnsupportedFormatFailure(extension: 'bin'),
      CorruptDocumentFailure(),
      EncryptedDocumentFailure(),
      TooLargeFailure(sizeBytes: 1, limitBytes: 0),
      SuspiciousArchiveFailure(reason: SuspiciousReason.zipBomb),
      RendererFailure(timedOut: true),
      NotFoundFailure(),
      UnexpectedFailure(),
    ];
    for (final DocumentFailure failure in failures) {
      expect(failure.code, isNotEmpty);
      expect(RecoveryHint.values, contains(failure.recovery));
    }
  });
}
