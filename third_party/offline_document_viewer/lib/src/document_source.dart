import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Where a document's bytes come from.
///
/// The package always works on an in-memory copy: bytes are read once, vetted,
/// and written into a private workspace. Nothing keeps a handle on the user's
/// original file, so a stale iOS security-scoped bookmark or a revoked Android
/// URI permission cannot break an already-opened document.
@immutable
sealed class DocumentSource {
  /// Creates a source that reports [name] as the document's file name.
  const DocumentSource({required this.name});

  /// Reads from a file on disk.
  ///
  /// [name] defaults to the file name, which is what format detection falls
  /// back to when the content is ambiguous.
  factory DocumentSource.file(String path, {String? name}) =
      _FileDocumentSource;

  /// Uses bytes you already have.
  ///
  /// [name] should carry the extension; detection prefers content but uses the
  /// name for formats without a signature, such as CSV.
  const factory DocumentSource.bytes(
    Uint8List bytes, {
    required String name,
  }) = _BytesDocumentSource;

  /// Reads from a Flutter asset.
  factory DocumentSource.asset(String assetPath, {String? name}) =
      _AssetDocumentSource;

  /// File name, used for display and as a detection fallback.
  final String name;

  /// Loads the bytes. Called once per open.
  Future<Uint8List> load();
}

final class _FileDocumentSource extends DocumentSource {
  _FileDocumentSource(this.path, {String? name})
      : super(name: name ?? path.split(Platform.pathSeparator).last);

  final String path;

  @override
  Future<Uint8List> load() => File(path).readAsBytes();
}

final class _BytesDocumentSource extends DocumentSource {
  const _BytesDocumentSource(this.bytes, {required super.name});

  final Uint8List bytes;

  @override
  Future<Uint8List> load() async => bytes;
}

final class _AssetDocumentSource extends DocumentSource {
  _AssetDocumentSource(this.assetPath, {String? name})
      : super(name: name ?? assetPath.split('/').last);

  final String assetPath;

  @override
  Future<Uint8List> load() async {
    final ByteData data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
