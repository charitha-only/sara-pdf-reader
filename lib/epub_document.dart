import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

class EpubRun {
  const EpubRun(this.text, {this.bold = false, this.italic = false});
  final String text;
  final bool bold, italic;
}

class EpubBlock {
  const EpubBlock(this.runs, {this.heading = 0, this.image});
  final List<EpubRun> runs;
  final int heading;
  final Uint8List? image;
  String get text => runs.map((r) => r.text).join();
}

class EpubChapter {
  const EpubChapter(this.title, this.blocks);
  final String title;
  final List<EpubBlock> blocks;
}

class EpubDocument {
  const EpubDocument(this.title, this.chapters);
  final String title;
  final List<EpubChapter> chapters;

  /// Reflowable, unencrypted EPUB 2/3. No publication scripts or remote
  /// resources are executed; all content becomes native reader widgets.
  static EpubDocument read(Uint8List bytes) {
    if (bytes.length > 40 * 1024 * 1024) {
      throw const FormatException('EPUB files up to 40 MB are supported.');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.length > 4000 ||
        archive.files.fold<int>(0, (n, f) => n + f.size) > 120 * 1024 * 1024 ||
        archive.files.any((f) => f.size > 16 * 1024 * 1024)) {
      throw const FormatException('This EPUB exceeds safe archive limits.');
    }
    final entries = <String, ArchiveFile>{};
    for (final f in archive.files.where((f) => f.isFile)) {
      final name = f.name;
      if (name.startsWith('/') ||
          name.contains('\\') ||
          name.split('/').contains('..') ||
          entries.containsKey(name)) {
        throw const FormatException('Invalid EPUB archive paths.');
      }
      entries[name] = f;
    }
    Uint8List data(String path) {
      final f = entries[path];
      if (f == null) throw FormatException('Missing EPUB resource: $path');
      return Uint8List.fromList(f.content as List<int>);
    }

    XmlDocument xml(String path) {
      final text = utf8.decode(data(path));
      if (RegExp(r'<!ENTITY', caseSensitive: false).hasMatch(text)) {
        throw const FormatException(
          'EPUB entity declarations are unsupported.',
        );
      }
      return XmlDocument.parse(text);
    }

    Iterable<XmlElement> nodes(XmlNode n, String name) => n.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == name);
    if (utf8.decode(data('mimetype')).trim() != 'application/epub+zip') {
      throw const FormatException('This file is not a valid EPUB.');
    }
    if (entries.containsKey('META-INF/encryption.xml')) {
      for (final encrypted in nodes(
        xml('META-INF/encryption.xml'),
        'EncryptedData',
      )) {
        final algorithm = nodes(
          encrypted,
          'EncryptionMethod',
        ).firstOrNull?.getAttribute('Algorithm');
        final resource =
            nodes(
              encrypted,
              'CipherReference',
            ).firstOrNull?.getAttribute('URI') ??
            '';
        final fontOnly =
            [
              'http://www.idpf.org/2008/embedding',
              'http://ns.adobe.com/pdf/enc#RC',
            ].contains(algorithm) &&
            RegExp(
              r'\.(ttf|otf|woff|woff2)$',
              caseSensitive: false,
            ).hasMatch(resource);
        if (!fontOnly) {
          throw const FormatException(
            'Encrypted EPUB resources are unsupported. Use an unencrypted copy.',
          );
        }
        // Native reflow uses bundled fonts; an obfuscated publication font is
        // unnecessary and must not prevent reading the unencrypted chapters.
      }
    }
    final package = nodes(
      xml('META-INF/container.xml'),
      'rootfile',
    ).firstOrNull?.getAttribute('full-path');
    if (package == null) throw const FormatException('Missing EPUB package.');
    final opf = xml(package);
    String resolve(String base, String href) {
      final uri = Uri(path: '/$base').resolve(href);
      if (uri.hasScheme || uri.hasAuthority || uri.path.contains('..')) {
        throw const FormatException('External EPUB resources are unsupported.');
      }
      return Uri.decodeComponent(uri.path.substring(1));
    }

    final manifest = <String, String>{};
    for (final item in nodes(opf, 'item')) {
      final id = item.getAttribute('id'), href = item.getAttribute('href');
      if (id != null && href != null) manifest[id] = resolve(package, href);
    }
    final refs = nodes(
      opf,
      'itemref',
    ).where((e) => e.getAttribute('linear') != 'no').toList();
    if (refs.isEmpty || refs.length > 1500) {
      throw const FormatException(
        'This EPUB has no supported reading order or too many chapters.',
      );
    }
    final imageCache = <String, Uint8List>{};
    var imageBytes = 0;
    var characters = 0;
    final chapters = <EpubChapter>[];
    for (final ref in refs) {
      final path = manifest[ref.getAttribute('idref')];
      if (path == null) {
        throw const FormatException('Broken EPUB spine reference.');
      }
      final doc = xml(path), blocks = <EpubBlock>[];
      final body = nodes(doc, 'body').firstOrNull;
      if (body == null) {
        throw const FormatException('EPUB chapter has no body.');
      }
      final pending = <EpubRun>[];
      void flush([int heading = 0]) {
        if (pending.any((r) => r.text.trim().isNotEmpty)) {
          blocks.add(EpubBlock(List.of(pending), heading: heading));
        }
        pending.clear();
      }

      void walk(XmlNode node, {bool bold = false, bool italic = false}) {
        if (node is XmlText) {
          final text = node.value.replaceAll(RegExp(r'\s+'), ' ');
          characters += text.length;
          if (characters > 8 * 1024 * 1024) {
            throw const FormatException('This EPUB contains too much text.');
          }
          pending.add(EpubRun(text, bold: bold, italic: italic));
          return;
        }
        if (node is! XmlElement) return;
        final tag = node.name.local.toLowerCase();
        if ([
          'script',
          'style',
          'iframe',
          'object',
          'audio',
          'video',
        ].contains(tag)) {
          return;
        }
        if (tag == 'br') {
          pending.add(const EpubRun('\n'));
          return;
        }
        if (tag == 'img' || tag == 'image') {
          flush();
          final src =
              node.getAttribute('src') ??
              node.attributes
                  .where((a) => a.name.local == 'href')
                  .firstOrNull
                  ?.value;
          if (src != null && !src.contains(':')) {
            final resource = entries[resolve(path, src)];
            if (resource != null &&
                resource.size <= 8 * 1024 * 1024 &&
                RegExp(
                  r'\.(png|jpg|jpeg|gif|webp)$',
                  caseSensitive: false,
                ).hasMatch(resource.name)) {
              final image = imageCache.putIfAbsent(resource.name, () {
                imageBytes += resource.size;
                if (imageBytes > 32 * 1024 * 1024) {
                  throw const FormatException(
                    'This EPUB contains too many images for an offline preview.',
                  );
                }
                return Uint8List.fromList(resource.content as List<int>);
              });
              blocks.add(EpubBlock(const [], image: image));
            }
          }
          return;
        }
        final heading = RegExp(r'^h[1-6]$').hasMatch(tag)
            ? int.parse(tag[1])
            : 0;
        final block =
            heading > 0 ||
            [
              'p',
              'div',
              'li',
              'blockquote',
              'pre',
              'tr',
              'section',
            ].contains(tag);
        if (block) flush();
        if (tag == 'li') pending.add(const EpubRun('• '));
        for (final child in node.children) {
          walk(
            child,
            bold: bold || heading > 0 || ['b', 'strong'].contains(tag),
            italic: italic || ['i', 'em'].contains(tag),
          );
        }
        if (tag == 'td' || tag == 'th') pending.add(const EpubRun('    '));
        if (block) flush(heading);
      }

      walk(body);
      flush();
      final heading = blocks.where((b) => b.heading > 0).firstOrNull?.text;
      final label = heading ?? nodes(doc, 'title').firstOrNull?.innerText;
      chapters.add(
        EpubChapter(
          label?.trim().isNotEmpty == true
              ? label!.trim()
              : 'Chapter ${chapters.length + 1}',
          blocks,
        ),
      );
    }
    return EpubDocument(
      nodes(opf, 'title').firstOrNull?.innerText.trim() ?? 'EPUB book',
      chapters,
    );
  }
}
