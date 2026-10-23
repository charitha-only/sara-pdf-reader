import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show ByteData, rootBundle, MethodChannel;
import 'package:path_provider/path_provider.dart';

import '../document_format.dart';
import '../engine/legacy_text.dart';
import '../engine/rtf_converter.dart';

/// A self-contained directory in which one document is rendered.
///
/// This single root is what both platform bridges need: Android serves it
/// through `WebViewAssetLoader`, iOS grants read access to it via
/// `loadFileURL`. Naming it after the content hash makes it a render cache as
/// well — reopening the same document skips setup entirely.
class Workspace {
  /// Creates a handle to an already-materialised workspace.
  const Workspace({
    required this.root,
    required this.format,
    required this.contentHash,
    required this.documentBytes,
  });

  /// Root directory that holds the shell, engine and document.
  final Directory root;

  /// Format the workspace was built for.
  final DocumentFormat format;

  /// First 16 hex characters of the SHA-256 of the document bytes.
  final String contentHash;

  /// Kept in memory because iOS receives the bytes over the bridge rather than
  /// fetching them from disk.
  final Uint8List documentBytes;

  /// The shell the bridge loads.
  File get entryPoint => File('${root.path}/viewer.html');
}

/// Materialises workspaces and prunes the cache.
class WorkspaceBuilder {
  /// Creates a builder. Stateless; construct it wherever it is needed.
  const WorkspaceBuilder();

  static const String _package = 'packages/offline_document_viewer';

  /// Bumped whenever anything that shapes the rendered output changes: a
  /// shell, the bridge, the CSP, a bundled engine — or a Dart-side converter,
  /// whose HTML is baked into the workspace just like the rest.
  ///
  /// It is part of the cache key. Without it a user who updates the package
  /// keeps seeing documents produced by the previous version, which is silent
  /// and very hard to diagnose: the code is fixed, the tests pass, and the
  /// screen still shows the old output.
  static const int _layoutRevision = 23;

  /// SheetJS reads `.xls` and `.csv` as well as `.xlsx`, so all three share
  /// one bundle. The style layer simply finds nothing to read in the legacy
  /// formats and falls back to values only.
  static const _EngineBundle _spreadsheetBundle = _EngineBundle(
      shell: '$_package/assets/viewers/xlsx.html',
      support: <String>[
        '$_package/assets/viewers/sheet.css',
        '$_package/assets/viewers/xlsx.js',
      ],
      engine: <String, String>{
        'engine/jszip3.min.js': '$_package/assets/engines/xlsx/jszip3.min.js',
        'engine/xlsx.full.min.js':
            '$_package/assets/engines/xlsx/xlsx.full.min.js',
        'engine/xlsx-render.js': '$_package/assets/engines/xlsx/xlsx-render.js',
        'engine/reader-extras.js': '$_package/assets/engines/xlsx/reader-extras.js',
      },
  );

  /// Assets each format needs. `viewer.html` is a fixed name so the bridge has
  /// a single entry point regardless of format.
  static const Map<DocumentFormat, _EngineBundle> _bundles =
      <DocumentFormat, _EngineBundle>{
    DocumentFormat.xlsx: _spreadsheetBundle,
    DocumentFormat.xls: _spreadsheetBundle,
    DocumentFormat.csv: _spreadsheetBundle,
    DocumentFormat.docx: _EngineBundle(
      shell: '$_package/assets/viewers/docx.html',
      support: <String>[
        '$_package/assets/viewers/page.css',
        '$_package/assets/viewers/docx.js',
      ],
      engine: <String, String>{
        'engine/jszip3.min.js': '$_package/assets/engines/docx/jszip3.min.js',
        'engine/docx-preview.js':
            '$_package/assets/engines/docx/docx-preview.js',
      },
    ),
    DocumentFormat.pptx: _EngineBundle(
      shell: '$_package/assets/viewers/pptx.html',
      support: <String>[
        '$_package/assets/viewers/slides.css',
        '$_package/assets/viewers/pptx.js',
      ],
      engine: <String, String>{
        'engine/jquery.min.js': '$_package/assets/engines/pptx/jquery.min.js',
        'engine/jszip2.min.js': '$_package/assets/engines/pptx/jszip2.min.js',
        'engine/filereader.js': '$_package/assets/engines/pptx/filereader.js',
        'engine/d3.min.js': '$_package/assets/engines/pptx/d3.min.js',
        'engine/nv.d3.min.js': '$_package/assets/engines/pptx/nv.d3.min.js',
        'engine/dingbat.js': '$_package/assets/engines/pptx/dingbat.js',
        'engine/pptxjs.js': '$_package/assets/engines/pptx/pptxjs.js',
        'engine/divs2slides.js':
            '$_package/assets/engines/pptx/divs2slides.js',
        'engine/pptxjs.css': '$_package/assets/engines/pptx/pptxjs.css',
        'engine/nv.d3.min.css': '$_package/assets/engines/pptx/nv.d3.min.css',
      },
    ),
  };

  /// Metric-compatible and symbol fonts, needed by every Office format.
  ///
  /// Office documents size their text boxes using the metrics of Calibri,
  /// Cambria and Arial. Those fonts exist on neither Android nor iOS; without
  /// substitutes the text does not fit its box and fixed-position layouts
  /// drift.
  static const List<String> _fonts = <String>[
    'office-fonts.css',
    'NotoSansSinhala-Regular.ttf',
    'NotoSansSinhala-Bold.ttf',
    'Carlito-Regular.ttf',
    'Carlito-Bold.ttf',
    'Carlito-Italic.ttf',
    'Carlito-BoldItalic.ttf',
    'Caladea-Regular.ttf',
    'Caladea-Bold.ttf',
    'Caladea-Italic.ttf',
    'Caladea-BoldItalic.ttf',
    'LiberationSans-Regular.ttf',
    'LiberationSans-Bold.ttf',
    'LiberationSans-Italic.ttf',
    'LiberationSans-BoldItalic.ttf',
    'LiberationSerif-Regular.ttf',
    'LiberationSerif-Bold.ttf',
    'LiberationSerif-Italic.ttf',
    'LiberationSerif-BoldItalic.ttf',
    'LiberationMono-Regular.ttf',
    'LiberationMono-Bold.ttf',
    'DejaVuSans.ttf',
    'DejaVuSans-Bold.ttf',
    'NotoSansMath-Regular.ttf',
    'NotoSansSymbols2-Regular.ttf',
  ];

  /// Formats converted to HTML on the Dart side rather than by a JavaScript
  /// engine: RTF, and the legacy binary formats shown as text.
  static const Set<DocumentFormat> _dartRendered = <DocumentFormat>{
    DocumentFormat.rtf,
    DocumentFormat.doc,
    DocumentFormat.ppt,
  };

  /// Whether this format can be rendered at all.
  static bool supports(DocumentFormat format) =>
      _bundles.containsKey(format) || _dartRendered.contains(format);

  /// Prepares (or reuses) the workspace for [bytes].
  static final Map<String, Future<Workspace>> _pending = {};
  Future<Workspace> build({required Uint8List bytes, required DocumentFormat format}) {
    final key = '${format.name}:${sha256.convert(bytes)}';
    return _pending.putIfAbsent(key, () => _build(bytes: bytes, format: format).whenComplete(() { _pending.remove(key); }));
  }

  Future<Workspace> _build({
    required Uint8List bytes,
    required DocumentFormat format,
  }) async {
    final _EngineBundle? bundle = _bundles[format];
    if (bundle == null && !_dartRendered.contains(format)) {
      throw StateError('No engine for $format');
    }

    final String hash = sha256.convert(bytes).toString().substring(0, 16);
    await prune(maxTotalBytes: 200 * 1024 * 1024);
    final Directory cache = await getApplicationCacheDirectory();
    final Directory root = Directory(
      '${cache.path}/odv_workspaces/r${_layoutRevision}_${format.name}_$hash',
    );

    if (!File('${root.path}/complete').existsSync()) {
      await root.create(recursive: true);
      if (bundle != null) {
        await _install(root, bundle);
        await File('${root.path}/doc.bin').writeAsBytes(bytes, flush: true);
      } else {
        await _installConverted(root, format, bytes);
      }
      await File('${root.path}/complete').writeAsString('$_layoutRevision', flush: true);
    }

    return Workspace(
      root: root,
      format: format,
      contentHash: hash,
      documentBytes: bytes,
    );
  }

  /// Content Security Policy embedded into the shell.
  ///
  /// Has to differ per platform. On Android the workspace is served from a
  /// real `https://appassets.androidplatform.net` origin, so `'self'` behaves
  /// as expected. On iOS the page loads over `file://`, WebKit gives such
  /// documents an opaque origin, and `'self'` then matches nothing at all —
  /// every engine script is silently blocked.
  ///
  /// iOS therefore allows the `file:` scheme, but `connect-src 'none'` stays
  /// on both: the page still cannot make a single network request.
  static String _cspFor() {
    if (Platform.isAndroid) {
      return "default-src 'none'; script-src 'self'; "
          "style-src 'self' 'unsafe-inline'; font-src 'self' data: blob:; "
          "img-src 'self' data: blob:; connect-src 'self'";
    }
    return "default-src 'none'; script-src 'self' file:; "
        "style-src 'self' 'unsafe-inline' file:; font-src 'self' file:; "
        "img-src 'self' file: data: blob:; connect-src 'none'";
  }

  /// Converts the document to HTML here and writes it straight into the
  /// shell. No JavaScript engine is involved, so nothing has to be copied
  /// beyond the shell, the bridge and the fonts.
  Future<void> _installConverted(
    Directory root,
    DocumentFormat format,
    Uint8List bytes,
  ) async {
    final String body = switch (format) {
      DocumentFormat.rtf => RtfConverter.toHtml(bytes),
      DocumentFormat.doc => Platform.isAndroid
          ? await _renderLegacyWord(bytes)
          : _paragraphsToHtml(LegacyTextExtractor.extractDoc(bytes)),
      DocumentFormat.ppt =>
        _paragraphsToHtml(LegacyTextExtractor.extractPpt(bytes)),
      _ => '',
    };

    final String shell = await rootBundle
        .loadString('$_package/assets/viewers/text.html');
    await File('${root.path}/viewer.html').writeAsString(
      shell
          .replaceFirst('__CSP__', _cspFor())
          .replaceFirst('__BODY__', body.isEmpty ? _emptyBody : body)
          .replaceFirst('stage reflow', format == DocumentFormat.doc && Platform.isAndroid ? 'stage legacy-word' : 'stage reflow'),
      flush: true,
    );

    await _copyAsset(
      '$_package/assets/viewers/bridge.js',
      '${root.path}/bridge.js',
    );
    await _copyAsset(
      '$_package/assets/viewers/text.js',
      '${root.path}/text.js',
    );
    await _copyAsset(
      '$_package/assets/viewers/page.css',
      '${root.path}/page.css',
    );
    for (final String font in _fonts) {
      await _copyAsset(
        '$_package/assets/fonts/$font',
        '${root.path}/fonts/$font',
      );
    }
  }

  /// Shown when a legacy file yields no readable text — an empty page beats a
  /// blank screen with no explanation.
  static const String _emptyBody =
      '<p class="empty">No readable text could be extracted '
      'from this document.</p>';

  static Future<String> _renderLegacyWord(Uint8List bytes) async {
    final String? html = await const MethodChannel('pageflow_reader/office')
        .invokeMethod<String>('renderLegacyWord', <String, Object>{'bytes': bytes});
    if (html == null) throw StateError('Legacy Word preview failed.');
    final String styles = RegExp(r'<style[^>]*>([\s\S]*?)</style>', caseSensitive: false)
        .allMatches(html).map((Match m) => m.group(1)!).join('\n');
    final Match? match = RegExp(r'<body([^>]*)>([\s\S]*?)</body>', caseSensitive: false).firstMatch(html);
    final String attributes = match?.group(1) ?? '';
    final String body = match?.group(2) ?? '';
    return '<style>$styles</style><div class="word-paper"><div $attributes data-word-content>$body</div></div>';
  }

  static String _paragraphsToHtml(List<String> paragraphs) => paragraphs
      .map(
        (String line) => '<p>${line.replaceAll('&', '&amp;')
            .replaceAll('<', '&lt;')
            .replaceAll('>', '&gt;')}</p>',
      )
      .join();

  Future<void> _install(Directory root, _EngineBundle bundle) async {
    await _copyShell(bundle.shell, '${root.path}/viewer.html');
    await _copyAsset(
      '$_package/assets/viewers/bridge.js',
      '${root.path}/bridge.js',
    );

    for (final String path in bundle.support) {
      await _copyAsset(path, '${root.path}/${path.split('/').last}');
    }

    for (final MapEntry<String, String> entry in bundle.engine.entries) {
      await _copyAsset(entry.value, '${root.path}/${entry.key}');
    }

    for (final String font in _fonts) {
      await _copyAsset(
        '$_package/assets/fonts/$font',
        '${root.path}/fonts/$font',
      );
    }
  }

  /// The shell is text, so the CSP placeholder is filled while copying.
  Future<void> _copyShell(String assetPath, String targetPath) async {
    final String html = await rootBundle.loadString(assetPath);
    await File(targetPath).writeAsString(
      html.replaceFirst('__CSP__', _cspFor()),
      flush: true,
    );
  }

  Future<void> _copyAsset(String assetPath, String targetPath) async {
    final ByteData data = await rootBundle.load(assetPath);
    final File target = File(targetPath);
    await target.parent.create(recursive: true);
    await target.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  }

  /// Removes cached workspaces by age and total size.
  ///
  /// Document content lives in the cache directory rather than persistent
  /// storage so the operating system — and the user — can reclaim it.
  Future<void> prune({
    int maxTotalBytes = 400 * 1024 * 1024,
    Duration maxAge = const Duration(days: 30),
  }) async {
    final Directory cache = await getApplicationCacheDirectory();
    final Directory base = Directory('${cache.path}/odv_workspaces');
    if (!base.existsSync()) {
      return;
    }

    final DateTime cutoff = DateTime.now().subtract(maxAge);
    final List<_Aged> kept = <_Aged>[];

    for (final Directory dir in base.listSync().whereType<Directory>()) {
      final FileStat stat = dir.statSync();
      if (stat.modified.isBefore(cutoff)) {
        await dir.delete(recursive: true);
        continue;
      }
      kept.add(
        _Aged(dir: dir, modified: stat.modified, bytes: _sizeOf(dir)),
      );
    }

    kept.sort((_Aged a, _Aged b) => b.modified.compareTo(a.modified));
    int running = 0;
    for (final _Aged aged in kept) {
      running += aged.bytes;
      if (running > maxTotalBytes) {
        await aged.dir.delete(recursive: true);
      }
    }
  }

  int _sizeOf(Directory dir) {
    int total = 0;
    for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
      if (entity is File) {
        total += entity.lengthSync();
      }
    }
    return total;
  }
}

class _EngineBundle {
  const _EngineBundle({
    required this.shell,
    required this.engine,
    this.support = const <String>[],
  });

  final String shell;
  final Map<String, String> engine;
  final List<String> support;
}

class _Aged {
  const _Aged({
    required this.dir,
    required this.modified,
    required this.bytes,
  });

  final Directory dir;
  final DateTime modified;
  final int bytes;
}

/// One message on the Dart ↔ JavaScript channel.
class BridgeMessage {
  /// Creates a message of [type] carrying [payload].
  const BridgeMessage(this.type, [this.payload = const <String, Object?>{}]);

  /// Parses a message coming from the shell.
  factory BridgeMessage.decode(String raw) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      return const BridgeMessage('error', <String, Object?>{
        'code': 'bad_message',
      });
    }
    return BridgeMessage(
      decoded['type']! as String,
      (decoded['payload'] as Map<String, Object?>?) ?? const <String, Object?>{},
    );
  }

  /// Message kind, matching the strings used in `bridge.js`.
  final String type;

  /// Message body.
  final Map<String, Object?> payload;

  /// Serialises the message for transport.
  String encode() =>
      jsonEncode(<String, Object?>{'type': type, 'payload': payload});
}
