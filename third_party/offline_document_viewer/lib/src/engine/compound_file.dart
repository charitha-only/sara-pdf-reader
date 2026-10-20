import 'dart:typed_data';

/// Minimal reader for OLE Compound File Binary containers.
///
/// This is the envelope every pre-2007 Office document lives in: `.doc`,
/// `.xls` and `.ppt` are all a small file system holding named streams.
///
/// Only what text extraction needs is implemented — the directory tree and
/// stream reading, including the mini-FAT used for streams under 4 KB. There
/// is no support for writing, transactions or storages beyond enumeration.
class CompoundFile {
  CompoundFile._(this._bytes, this._view, this._sectorSize, this._miniCutoff,
      this._fat, this._miniFat, this._directory, this._miniStream);

  final Uint8List _bytes;
  final ByteData _view;
  final int _sectorSize;
  final int _miniCutoff;
  final List<int> _fat;
  final List<int> _miniFat;
  final Map<String, _DirEntry> _directory;
  final Uint8List _miniStream;

  static const List<int> _signature = <int>[
    0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, //
  ];

  static const int _endOfChain = 0xFFFFFFFE;
  static const int _freeSector = 0xFFFFFFFF;

  /// Parses [bytes], or returns `null` when they are not a compound file or
  /// the structure is damaged beyond use.
  static CompoundFile? parse(Uint8List bytes) {
    if (bytes.length < 512) {
      return null;
    }
    for (int i = 0; i < _signature.length; i++) {
      if (bytes[i] != _signature[i]) {
        return null;
      }
    }

    try {
      return _parse(bytes);
    } on Object {
      // A malformed container is a document problem, not a crash.
      return null;
    }
  }

  static CompoundFile _parse(Uint8List bytes) {
    final ByteData view = ByteData.sublistView(bytes);
    final int sectorSize = 1 << view.getUint16(0x1E, Endian.little);
    final int fatSectorCount = view.getUint32(0x2C, Endian.little);
    final int firstDirSector = view.getUint32(0x30, Endian.little);
    final int miniCutoff = view.getUint32(0x38, Endian.little);
    final int firstMiniFat = view.getUint32(0x3C, Endian.little);
    final int miniFatCount = view.getUint32(0x40, Endian.little);
    final int firstDifat = view.getUint32(0x44, Endian.little);
    final int difatCount = view.getUint32(0x48, Endian.little);

    int offsetOf(int sector) => 512 + sector * sectorSize;

    // The DIFAT lists the sectors that hold the FAT. The first 109 entries
    // live in the header; longer files chain further DIFAT sectors.
    final List<int> fatSectors = <int>[];
    for (int i = 0; i < 109 && fatSectors.length < fatSectorCount; i++) {
      final int sector = view.getUint32(0x4C + i * 4, Endian.little);
      if (sector == _freeSector) {
        break;
      }
      fatSectors.add(sector);
    }
    int difat = firstDifat;
    for (int n = 0; n < difatCount && difat != _endOfChain; n++) {
      final int base = offsetOf(difat);
      final int perSector = sectorSize ~/ 4 - 1;
      for (int i = 0; i < perSector; i++) {
        final int sector = view.getUint32(base + i * 4, Endian.little);
        if (sector != _freeSector) {
          fatSectors.add(sector);
        }
      }
      difat = view.getUint32(base + perSector * 4, Endian.little);
    }

    final List<int> fat = <int>[];
    for (final int sector in fatSectors) {
      final int base = offsetOf(sector);
      for (int i = 0; i < sectorSize ~/ 4; i++) {
        fat.add(view.getUint32(base + i * 4, Endian.little));
      }
    }

    List<int> chainOf(int start) {
      final List<int> chain = <int>[];
      int current = start;
      // The bound stops a corrupt file from spinning forever.
      while (current != _endOfChain &&
          current != _freeSector &&
          current < fat.length &&
          chain.length < fat.length) {
        chain.add(current);
        current = fat[current];
      }
      return chain;
    }

    Uint8List readChain(int start, int size) {
      final BytesBuilder builder = BytesBuilder();
      for (final int sector in chainOf(start)) {
        final int from = offsetOf(sector);
        if (from >= bytes.length) {
          break;
        }
        final int to = (from + sectorSize).clamp(0, bytes.length);
        builder.add(bytes.sublist(from, to));
      }
      final Uint8List data = builder.toBytes();
      return size > 0 && size < data.length ? data.sublist(0, size) : data;
    }

    // Mini FAT, for streams smaller than the cutoff.
    final List<int> miniFat = <int>[];
    int mini = firstMiniFat;
    for (int n = 0; n < miniFatCount && mini != _endOfChain; n++) {
      final int base = offsetOf(mini);
      for (int i = 0; i < sectorSize ~/ 4; i++) {
        miniFat.add(view.getUint32(base + i * 4, Endian.little));
      }
      mini = mini < fat.length ? fat[mini] : _endOfChain;
    }

    // Directory entries are 128 bytes each.
    final Uint8List directoryBytes = readChain(firstDirSector, 0);
    final ByteData dirView = ByteData.sublistView(directoryBytes);
    final Map<String, _DirEntry> directory = <String, _DirEntry>{};
    _DirEntry? root;

    for (int i = 0; i + 128 <= directoryBytes.length; i += 128) {
      final int nameLength = dirView.getUint16(i + 0x40, Endian.little);
      if (nameLength < 2) {
        continue;
      }
      final StringBuffer name = StringBuffer();
      for (int c = 0; c < nameLength - 2; c += 2) {
        name.writeCharCode(dirView.getUint16(i + c, Endian.little));
      }
      final _DirEntry entry = _DirEntry(
        name: name.toString(),
        type: directoryBytes[i + 0x42],
        startSector: dirView.getUint32(i + 0x74, Endian.little),
        size: dirView.getUint32(i + 0x78, Endian.little),
      );
      if (entry.type == 5) {
        root = entry;
      } else if (entry.type == 2) {
        directory[entry.name] = entry;
      }
    }

    final Uint8List miniStream = root == null
        ? Uint8List(0)
        : readChain(root.startSector, root.size);

    return CompoundFile._(
      bytes,
      view,
      sectorSize,
      miniCutoff,
      fat,
      miniFat,
      directory,
      miniStream,
    );
  }

  /// Names of every stream in the container.
  Set<String> get streamNames => _directory.keys.toSet();

  /// Reads a stream by name, or returns `null` when it does not exist.
  Uint8List? read(String name) {
    final _DirEntry? entry = _directory[name];
    if (entry == null) {
      return null;
    }

    if (entry.size < _miniCutoff) {
      return _readMini(entry.startSector, entry.size);
    }

    final BytesBuilder builder = BytesBuilder();
    int current = entry.startSector;
    int guard = 0;
    while (current != _endOfChain &&
        current != _freeSector &&
        current < _fat.length &&
        guard++ < _fat.length) {
      final int from = 512 + current * _sectorSize;
      if (from >= _bytes.length) {
        break;
      }
      final int to = (from + _sectorSize).clamp(0, _bytes.length);
      builder.add(_bytes.sublist(from, to));
      current = _fat[current];
    }
    final Uint8List data = builder.toBytes();
    return entry.size < data.length ? data.sublist(0, entry.size) : data;
  }

  Uint8List _readMini(int start, int size) {
    const int miniSectorSize = 64;
    final BytesBuilder builder = BytesBuilder();
    int current = start;
    int guard = 0;
    while (current != _endOfChain &&
        current != _freeSector &&
        current < _miniFat.length &&
        guard++ < _miniFat.length) {
      final int from = current * miniSectorSize;
      if (from >= _miniStream.length) {
        break;
      }
      final int to = (from + miniSectorSize).clamp(0, _miniStream.length);
      builder.add(_miniStream.sublist(from, to));
      current = _miniFat[current];
    }
    final Uint8List data = builder.toBytes();
    return size < data.length ? data.sublist(0, size) : data;
  }

  /// Convenience for callers that only need the header check.
  ByteData get view => _view;
}

class _DirEntry {
  const _DirEntry({
    required this.name,
    required this.type,
    required this.startSector,
    required this.size,
  });

  final String name;

  /// 1 storage, 2 stream, 5 root.
  final int type;

  final int startSector;
  final int size;
}
