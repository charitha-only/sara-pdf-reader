import 'dart:typed_data';

import 'compound_file.dart';

/// Extracts readable text from the pre-2007 binary Office formats.
///
/// There is no open-source, on-device layout engine for `.doc` and `.ppt`, and
/// a half-working fidelity attempt is worse than an honest text view. So these
/// formats are presented as text, clearly labelled — which is also what most
/// document viewers do.
///
/// Everything here is defensive: these are decades-old binary formats produced
/// by many different writers, and the only acceptable failure mode is "less
/// text than hoped", never an exception.
abstract final class LegacyTextExtractor {
  /// Extracts paragraphs from a `.doc` (Word 6–2003) file.
  ///
  /// Word stores text either as one contiguous run or, once a document has
  /// been edited, as a *piece table* pointing at fragments scattered through
  /// the stream. Both layouts are handled; the piece table also decides per
  /// piece whether the text is 8-bit or UTF-16.
  static List<String> extractDoc(Uint8List bytes) {
    final CompoundFile? cfb = CompoundFile.parse(bytes);
    final Uint8List? doc = cfb?.read('WordDocument');
    if (cfb == null || doc == null || doc.length < 0x200) {
      return const <String>[];
    }

    final ByteData view = ByteData.sublistView(doc);
    final int flags = view.getUint16(0x0A, Endian.little);
    // Bit 9 selects which table stream carries the piece table.
    final String tableName = (flags & 0x0200) != 0 ? '1Table' : '0Table';

    // The piece table is preferred whenever one exists, regardless of the
    // fComplex flag. Word 97 and later write a piece table even for documents
    // that were never edited, and only the table records whether each run is
    // 8-bit or UTF-16 — guessing that from the FIB gets Turkish, Greek and
    // Cyrillic text wrong in a way that looks like mojibake ("kalın" arriving
    // as "kal1n").
    final Uint8List? table = cfb.read(tableName);
    if (table != null) {
      final int fcClx = view.getUint32(0x01A2, Endian.little);
      final int lcbClx = view.getUint32(0x01A6, Endian.little);
      if (lcbClx > 0 && fcClx + lcbClx <= table.length) {
        final Uint8List? pieceTable =
            _findPieceTable(table.sublist(fcClx, fcClx + lcbClx));
        if (pieceTable != null) {
          final String text = _readPieces(pieceTable, doc);
          if (text.trim().isNotEmpty) {
            return _split(text);
          }
        }
      }
    }

    // No usable piece table: fall back to the contiguous range, sniffing the
    // encoding rather than assuming it.
    final int fcMin = view.getUint32(0x18, Endian.little);
    final int fcMac = view.getUint32(0x1C, Endian.little);
    if (fcMin < fcMac && fcMac <= doc.length) {
      final Uint8List slice = doc.sublist(fcMin, fcMac);
      return _split(
        _looksUtf16(slice) ? _decodeUtf16(slice) : _decodeAnsi(slice),
      );
    }
    return const <String>[];
  }

  /// Heuristic for text that is UTF-16 without saying so.
  ///
  /// Latin and Turkish characters sit in the low range, so their UTF-16
  /// encoding leaves every second byte zero. A run of those is conclusive
  /// enough, and being wrong only costs a fallback that was already a guess.
  static bool _looksUtf16(Uint8List bytes) {
    final int sample = bytes.length < 64 ? bytes.length : 64;
    if (sample < 4) {
      return false;
    }
    int zeros = 0;
    for (int i = 1; i < sample; i += 2) {
      if (bytes[i] == 0) {
        zeros++;
      }
    }
    return zeros > sample ~/ 4;
  }

  /// Walks the CLX, skipping formatting runs, to find the piece table.
  ///
  /// The CLX is a sequence of entries: `0x01` introduces a run of properties
  /// with a 16-bit length, `0x02` introduces the piece table with a 32-bit
  /// length. Only the latter is of interest.
  static Uint8List? _findPieceTable(Uint8List clx) {
    final ByteData view = ByteData.sublistView(clx);
    int offset = 0;
    while (offset < clx.length) {
      final int marker = clx[offset];
      if (marker == 0x01) {
        if (offset + 3 > clx.length) {
          return null;
        }
        final int length = view.getUint16(offset + 1, Endian.little);
        offset += 3 + length;
      } else if (marker == 0x02) {
        if (offset + 5 > clx.length) {
          return null;
        }
        final int length = view.getUint32(offset + 1, Endian.little);
        final int start = offset + 5;
        if (start + length > clx.length) {
          return null;
        }
        return clx.sublist(start, start + length);
      } else {
        return null;
      }
    }
    return null;
  }

  /// Reassembles the document text from the piece descriptors.
  static String _readPieces(Uint8List pieceTable, Uint8List doc) {
    // Layout: (n + 1) character positions, then n eight-byte descriptors.
    final int count = (pieceTable.length - 4) ~/ 12;
    if (count <= 0) {
      return '';
    }

    final ByteData view = ByteData.sublistView(pieceTable);
    final int descriptorBase = (count + 1) * 4;
    final StringBuffer text = StringBuffer();

    for (int i = 0; i < count; i++) {
      final int cpStart = view.getUint32(i * 4, Endian.little);
      final int cpEnd = view.getUint32((i + 1) * 4, Endian.little);
      final int descriptor = descriptorBase + i * 8;
      if (descriptor + 8 > pieceTable.length) {
        break;
      }

      int fc = view.getUint32(descriptor + 2, Endian.little);
      // Bit 30 set means the piece is 8-bit; the real offset is halved.
      final bool compressed = (fc & 0x40000000) != 0;
      fc &= 0x3FFFFFFF;

      final int characters = cpEnd - cpStart;
      if (characters <= 0) {
        continue;
      }

      if (compressed) {
        final int start = fc ~/ 2;
        final int end = start + characters;
        if (start < doc.length) {
          text.write(_decodeAnsi(doc.sublist(start, end.clamp(0, doc.length))));
        }
      } else {
        final int end = fc + characters * 2;
        if (fc < doc.length) {
          text.write(
            _decodeUtf16(doc.sublist(fc, end.clamp(0, doc.length))),
          );
        }
      }
    }
    return text.toString();
  }

  /// Extracts text from a `.ppt` (PowerPoint 97–2003) file.
  ///
  /// The presentation stream is a tree of records. Containers are recursed
  /// into; the two atoms that carry visible text are collected in the order
  /// they appear, which approximates slide order well enough to read.
  static List<String> extractPpt(Uint8List bytes) {
    final CompoundFile? cfb = CompoundFile.parse(bytes);
    final Uint8List? stream = cfb?.read('PowerPoint Document');
    if (stream == null) {
      return const <String>[];
    }

    final List<String> chunks = <String>[];
    _walkRecords(stream, 0, stream.length, chunks, 0);
    return chunks
        .expand(_split)
        .where((String line) => line.isNotEmpty && !_isInternalMarker(line))
        .toList();
  }

  static const int _textCharsAtom = 0x0FA0; // UTF-16
  static const int _textBytesAtom = 0x0FA8; // 8-bit

  /// Containers whose text is never slide content.
  ///
  /// A master carries the "Click to edit Master title style" placeholders and
  /// notes carry speaker notes; collecting either buries the real slides.
  static const Set<int> _skippedContainers = <int>{
    0x03F8, // MainMaster
    0x03F0, // Notes
  };

  // `CString` (0x0FBA) is deliberately not collected. It looks like a source
  // of slide titles but PowerPoint also uses it for hyperlink targets and
  // internal names, so reading it fills the output with URLs and markers like
  // `___PPT12`. Body text always lives in the two atoms above.

  static void _walkRecords(
    Uint8List data,
    int start,
    int end,
    List<String> out,
    int depth,
  ) {
    // Nesting this deep means the file is malformed; stop rather than recurse.
    if (depth > 16) {
      return;
    }
    final ByteData view = ByteData.sublistView(data);
    int offset = start;

    while (offset + 8 <= end) {
      final int versionInstance = view.getUint16(offset, Endian.little);
      final int type = view.getUint16(offset + 2, Endian.little);
      final int length = view.getUint32(offset + 4, Endian.little);
      final int body = offset + 8;
      final int bodyEnd = body + length;
      if (length < 0 || bodyEnd > end) {
        return;
      }

      // A version nibble of 0xF marks a container record.
      if ((versionInstance & 0x000F) == 0x000F) {
        if (!_skippedContainers.contains(type)) {
          _walkRecords(data, body, bodyEnd, out, depth + 1);
        }
      } else if (type == _textCharsAtom) {
        out.add(_decodeUtf16(data.sublist(body, bodyEnd)));
      } else if (type == _textBytesAtom) {
        out.add(_decodeAnsi(data.sublist(body, bodyEnd)));
      }

      offset = bodyEnd;
    }
  }

  /// PowerPoint writes version stamps such as `___PPT12` into the text
  /// stream; they are not content.
  static bool _isInternalMarker(String line) =>
      RegExp(r'^_{2,}PPT\d+$').hasMatch(line);

  /// Splits on the paragraph marks these formats use and drops control noise.
  static List<String> _split(String raw) {
    return raw
        .split(RegExp(r'[\r\n\x0B\x0C]+'))
        .map(_clean)
        .where((String line) => line.isNotEmpty)
        .toList();
  }

  /// Removes the field, footnote and object placeholders that would otherwise
  /// show up as stray glyphs.
  static String _clean(String line) {
    final StringBuffer buffer = StringBuffer();
    for (final int unit in line.codeUnits) {
      if (unit == 0x09) {
        buffer.write('\t');
      } else if (unit >= 0x20 && unit != 0x7F) {
        buffer.writeCharCode(unit);
      }
    }
    return buffer.toString().trim();
  }

  /// Windows-1252, which is what "ANSI" means in these formats.
  static String _decodeAnsi(Uint8List bytes) {
    const Map<int, int> high = <int, int>{
      0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
      0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
      0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
      0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
      0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
      0x9E: 0x017E, 0x9F: 0x0178,
    };
    final StringBuffer buffer = StringBuffer();
    for (final int byte in bytes) {
      buffer.writeCharCode(high[byte] ?? byte);
    }
    return buffer.toString();
  }

  static String _decodeUtf16(Uint8List bytes) {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i + 1 < bytes.length; i += 2) {
      buffer.writeCharCode(bytes[i] | (bytes[i + 1] << 8));
    }
    return buffer.toString();
  }
}
