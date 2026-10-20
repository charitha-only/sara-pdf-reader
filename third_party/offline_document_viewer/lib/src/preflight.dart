import 'dart:convert';
import 'dart:typed_data';

import 'document_format.dart';
import 'failures.dart';

/// Safety and sanity checks that run before a document reaches a renderer.
///
/// Documents are untrusted input: whatever the user picks, this package opens.
/// Without this layer a truncated archive crashes the engine and a zip bomb
/// exhausts memory.
///
/// The zip central directory is read by hand so that the *declared* sizes can
/// be inspected **without inflating anything** — the only safe way to spot a
/// bomb.
///
/// [DocumentView] runs this automatically. Call it yourself when you want to
/// validate a file before showing any UI:
///
/// ```dart
/// final report = DocumentPreflight.inspect(bytes: bytes, fileName: name);
/// switch (report) {
///   case PreflightReport(): // safe to open
///   case DocumentFailure(): // reject with a message of your own
/// }
/// ```
abstract final class DocumentPreflight {
  /// Largest accepted compressed file.
  static const int maxBytes = 80 * 1024 * 1024;

  /// Largest accepted total uncompressed size across all zip entries.
  static const int maxUncompressed = 300 * 1024 * 1024;

  /// Largest accepted uncompressed-to-compressed ratio for a single entry.
  static const int maxRatio = 200;

  /// Largest accepted number of zip entries.
  static const int maxEntries = 5000;

  /// Inspects [bytes] and returns either a report or the reason for rejection.
  static Object inspect({
    required Uint8List bytes,
    required String fileName,
  }) {
    if (bytes.isEmpty) {
      return const CorruptDocumentFailure(detail: 'empty file');
    }
    if (bytes.length > maxBytes) {
      return TooLargeFailure(sizeBytes: bytes.length, limitBytes: maxBytes);
    }

    switch (FormatDetector.containerOf(bytes)) {
      case ContainerKind.pdf:
        return const PreflightReport(
          format: DocumentFormat.pdf,
          entryCount: 0,
        );

      case ContainerKind.rtf:
        return const PreflightReport(
          format: DocumentFormat.rtf,
          entryCount: 0,
        );

      case ContainerKind.ole:
        // Both legacy binary documents and encrypted OOXML are OLE
        // containers; only the stream names tell them apart, and that read
        // belongs to the legacy engine.
        final DocumentFormat? guess = FormatDetector.fromExtension(fileName);
        if (guess != null && guess.isLegacyBinary) {
          return PreflightReport(
            format: guess,
            entryCount: 0,
            isOleContainer: true,
          );
        }
        return const EncryptedDocumentFailure(detail: 'OLE compound file');

      case ContainerKind.zip:
        return _inspectZip(bytes, fileName);

      case ContainerKind.unknown:
        // CSV and friends are plain text with no signature; falling back to
        // the extension is legitimate here.
        if (FormatDetector.fromExtension(fileName) == DocumentFormat.csv) {
          return const PreflightReport(
            format: DocumentFormat.csv,
            entryCount: 0,
          );
        }
        return UnsupportedFormatFailure(
          extension: _extensionOf(fileName),
          detail: 'unrecognised container',
        );
    }
  }

  static Object _inspectZip(Uint8List bytes, String fileName) {
    final List<_ZipEntry>? entries = _readCentralDirectory(bytes);
    if (entries == null) {
      return const CorruptDocumentFailure(
        detail: 'central directory unreadable',
      );
    }
    if (entries.isEmpty) {
      return const CorruptDocumentFailure(detail: 'empty archive');
    }
    if (entries.length > maxEntries) {
      return const SuspiciousArchiveFailure(
        reason: SuspiciousReason.tooManyEntries,
      );
    }

    int total = 0;
    for (final _ZipEntry entry in entries) {
      if (entry.name.contains('..') || entry.name.startsWith('/')) {
        return SuspiciousArchiveFailure(
          reason: SuspiciousReason.pathTraversal,
          detail: entry.name,
        );
      }
      total += entry.uncompressed;
      if (entry.compressed > 0 &&
          entry.uncompressed / entry.compressed > maxRatio) {
        return SuspiciousArchiveFailure(
          reason: SuspiciousReason.zipBomb,
          detail: '${entry.name}: ${entry.compressed} → ${entry.uncompressed}',
        );
      }
    }
    if (total > maxUncompressed) {
      return TooLargeFailure(sizeBytes: total, limitBytes: maxUncompressed);
    }

    final DocumentFormat? format = FormatDetector.fromOoxmlParts(
      entries.map((_ZipEntry e) => e.name).toSet(),
    );
    if (format == null) {
      return CorruptDocumentFailure(
        detail: 'no OOXML main part; extension says ${_extensionOf(fileName)}',
      );
    }

    return PreflightReport(
      format: format,
      entryCount: entries.length,
      uncompressedBytes: total,
    );
  }

  /// Finds the end-of-central-directory record and walks the entry headers.
  ///
  /// Only declared sizes are read; nothing is decompressed.
  static List<_ZipEntry>? _readCentralDirectory(Uint8List bytes) {
    final ByteData view = ByteData.sublistView(bytes);
    const int eocdSignature = 0x06054b50;
    const int entrySignature = 0x02014b50;

    int eocd = -1;
    final int from = bytes.length - 65557 < 0 ? 0 : bytes.length - 65557;
    for (int i = bytes.length - 22; i >= from; i--) {
      if (view.getUint32(i, Endian.little) == eocdSignature) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) {
      return null;
    }

    final int count = view.getUint16(eocd + 10, Endian.little);
    int offset = view.getUint32(eocd + 16, Endian.little);
    if (offset >= bytes.length) {
      return null;
    }

    final List<_ZipEntry> entries = <_ZipEntry>[];
    for (int i = 0; i < count && offset + 46 <= bytes.length; i++) {
      if (view.getUint32(offset, Endian.little) != entrySignature) {
        break;
      }
      final int compressed = view.getUint32(offset + 20, Endian.little);
      final int uncompressed = view.getUint32(offset + 24, Endian.little);
      final int nameLen = view.getUint16(offset + 28, Endian.little);
      final int extraLen = view.getUint16(offset + 30, Endian.little);
      final int commentLen = view.getUint16(offset + 32, Endian.little);
      final int nameEnd = offset + 46 + nameLen;
      if (nameEnd > bytes.length) {
        return null;
      }
      entries.add(
        _ZipEntry(
          name: utf8.decode(
            bytes.sublist(offset + 46, nameEnd),
            allowMalformed: true,
          ),
          compressed: compressed,
          uncompressed: uncompressed,
        ),
      );
      offset = nameEnd + extraLen + commentLen;
    }
    return entries;
  }

  static String _extensionOf(String fileName) {
    final int dot = fileName.lastIndexOf('.');
    return dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  }
}

/// A document that passed [DocumentPreflight].
class PreflightReport {
  /// Creates a report for a document that passed inspection.
  const PreflightReport({
    required this.format,
    required this.entryCount,
    this.uncompressedBytes = 0,
    this.isOleContainer = false,
  });

  /// Format resolved from the content, not the file name.
  final DocumentFormat format;

  /// Number of zip entries, or `0` for non-zip containers.
  final int entryCount;

  /// Total declared uncompressed size, or `0` for non-zip containers.
  final int uncompressedBytes;

  /// Whether the bytes are an OLE compound file rather than a zip.
  final bool isOleContainer;
}

class _ZipEntry {
  const _ZipEntry({
    required this.name,
    required this.compressed,
    required this.uncompressed,
  });

  final String name;
  final int compressed;
  final int uncompressed;
}
