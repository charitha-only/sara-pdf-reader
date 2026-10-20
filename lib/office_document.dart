import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

class OfficeRun {
  const OfficeRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.color = 0xff111111,
    this.size = 16,
  });
  final String text;
  final bool bold, italic;
  final int color;
  final double size;
}

class OfficeBlock {
  const OfficeBlock({
    this.runs = const [],
    this.rows = const [],
    this.image,
    this.left = 0,
    this.top = 0,
    this.width = 1,
    this.height = .2,
  });
  final List<OfficeRun> runs;
  final List<List<String>> rows;
  final Uint8List? image;
  final double left, top, width, height;
  String get text => runs.map((r) => r.text).join();
}

class OfficeSection {
  const OfficeSection(this.name, this.blocks);
  final String name;
  final List<OfficeBlock> blocks;
}

class OfficeDocument {
  const OfficeDocument(this.kind, this.sections, {this.aspectRatio = 4 / 3});
  final double aspectRatio;
  final String kind;
  final List<OfficeSection> sections;
  static OfficeDocument read(Uint8List bytes, String extension) {
    if (bytes.length > 64 * 1024 * 1024) {
      throw const FormatException('Office files up to 64 MB are supported.');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.length > 10000 ||
        archive.files.fold<int>(0, (sum, f) => sum + f.size) >
            128 * 1024 * 1024) {
      throw const FormatException('The Office archive is too large.');
    }
    final files = <String, Uint8List>{};
    for (final file in archive.files) {
      if (file.isFile) {
        files[file.name] = Uint8List.fromList(file.content as List<int>);
      }
    }
    XmlDocument xml(String name) {
      final data = files[name];
      if (data == null) throw FormatException('Missing Office part: $name');
      return XmlDocument.parse(utf8.decode(data));
    }

    Iterable<XmlElement> nodes(XmlNode node, String name) => node.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == name);
    String? attr(XmlElement e, String name) {
      if (name == 'id') {
        final relationship = e.attributes
            .where((a) => a.name.local == 'id' && a.name.prefix == 'r')
            .firstOrNull;
        if (relationship != null) return relationship.value;
      }
      for (final a in e.attributes) {
        if (a.name.local == name) return a.value;
      }
      return null;
    }

    Map<String, String> rels(String name) {
      if (!files.containsKey(name)) return {};
      return {
        for (final rel in nodes(xml(name), 'Relationship'))
          if (attr(rel, 'TargetMode') != 'External')
            attr(rel, 'Id') ?? '': attr(rel, 'Target') ?? '',
      };
    }

    String resolve(String base, String target) =>
        Uri(path: base).resolve(target).path.replaceFirst(RegExp(r'^/'), '');
    List<OfficeRun> runs(XmlNode root, {bool word = false}) {
      final output = <OfficeRun>[];
      for (final run in nodes(root, 'r')) {
        final texts = nodes(run, 't').map((t) => t.innerText).join();
        if (texts.isEmpty) continue;
        final properties = nodes(run, word ? 'rPr' : 'rPr').firstOrNull;
        final size = properties == null
            ? null
            : word
            ? nodes(properties, 'sz').firstOrNull
            : properties;
        final rawSize = word
            ? size == null
                  ? null
                  : attr(size, 'val')
            : properties == null
            ? null
            : attr(properties, 'sz');
        var color = 0xff111111;
        final colorNode = properties == null
            ? null
            : nodes(properties, word ? 'color' : 'srgbClr').firstOrNull;
        final hex = colorNode == null ? null : attr(colorNode, 'val');
        if (hex != null && RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
          color = 0xff000000 | int.parse(hex, radix: 16);
        }
        output.add(
          OfficeRun(
            texts,
            bold:
                properties != null &&
                (word
                    ? nodes(properties, 'b').isNotEmpty
                    : attr(properties, 'b') == '1'),
            italic:
                properties != null &&
                (word
                    ? nodes(properties, 'i').isNotEmpty
                    : attr(properties, 'i') == '1'),
            color: color,
            size: rawSize == null
                ? 16
                : (double.tryParse(rawSize) ?? (word ? 32 : 1600)) /
                      (word ? 2 : 100),
          ),
        );
      }
      return output;
    }

    if (extension.toLowerCase() == 'docx') {
      final doc = xml('word/document.xml'),
          relations = rels('word/_rels/document.xml.rels');
      final body = nodes(doc, 'body').first;
      final blocks = <OfficeBlock>[];
      for (final child in body.children.whereType<XmlElement>()) {
        if (child.name.local == 'p') {
          final textRuns = runs(child, word: true);
          if (textRuns.isNotEmpty) blocks.add(OfficeBlock(runs: textRuns));
          for (final blip in nodes(child, 'blip')) {
            final target = relations[attr(blip, 'embed')];
            if (target != null) {
              final image = files[resolve('word/document.xml', target)];
              if (image != null) blocks.add(OfficeBlock(image: image));
            }
          }
        } else if (child.name.local == 'tbl') {
          blocks.add(
            OfficeBlock(
              rows: [
                for (final row in child.children.whereType<XmlElement>().where(
                  (e) => e.name.local == 'tr',
                ))
                  [
                    for (final cell
                        in row.children.whereType<XmlElement>().where(
                          (e) => e.name.local == 'tc',
                        ))
                      nodes(cell, 't').map((t) => t.innerText).join(),
                  ],
              ],
            ),
          );
        }
      }
      return OfficeDocument('Word', [OfficeSection('Document', blocks)]);
    }
    if (extension.toLowerCase() == 'xlsx') {
      final workbook = xml('xl/workbook.xml'),
          relations = rels('xl/_rels/workbook.xml.rels');
      final strings = files.containsKey('xl/sharedStrings.xml')
          ? nodes(xml('xl/sharedStrings.xml'), 'si')
                .map((si) => nodes(si, 't').map((t) => t.innerText).join())
                .toList()
          : <String>[];
      final sections = <OfficeSection>[];
      int column(String address) {
        var value = 0;
        for (final rune
            in RegExp(r'^[A-Z]+').stringMatch(address)?.runes ?? <int>[]) {
          value = value * 26 + rune - 64;
        }
        return value - 1;
      }

      for (final sheet in nodes(workbook, 'sheet')) {
        final target = relations[attr(sheet, 'id')];
        if (target == null) continue;
        final name = resolve('xl/workbook.xml', target), document = xml(name);
        final cells = <int, Map<int, String>>{};
        int maximum = 0;
        for (final row in nodes(document, 'row')) {
          final index = (int.tryParse(attr(row, 'r') ?? '1') ?? 1) - 1;
          if (index < 0 || index >= 10000) {
            throw const FormatException(
              'Sheets up to 10,000 rows are supported.',
            );
          }
          final values = <int, String>{};
          for (final cell in row.children.whereType<XmlElement>().where(
            (e) => e.name.local == 'c',
          )) {
            final col = column(attr(cell, 'r') ?? 'A1');
            if (col < 0 || col >= 256) continue;
            maximum = col > maximum ? col : maximum;
            final type = attr(cell, 't'),
                value = nodes(cell, 'v').firstOrNull?.innerText ?? '';
            values[col] = type == 's'
                ? strings.elementAtOrNull(
                        (int.tryParse(value) ?? strings.length).clamp(
                          0,
                          strings.length,
                        ),
                      ) ??
                      ''
                : type == 'inlineStr'
                ? nodes(cell, 't').map((t) => t.innerText).join()
                : type == 'b'
                ? (value == '1' ? 'TRUE' : 'FALSE')
                : value.isNotEmpty
                ? value
                : nodes(cell, 'f').firstOrNull?.innerText ?? '';
          }
          cells[index] = values;
        }
        final lastRow = cells.keys.isEmpty
            ? -1
            : cells.keys.reduce((a, b) => a > b ? a : b);
        if ((lastRow + 1) * (maximum + 1) > 50000) {
          throw const FormatException(
            'This sheet is too large for the mobile preview. Export a smaller sheet to view it.',
          );
        }
        final rows = [
          for (
            var i = 0;
            i <=
                (cells.keys.isEmpty
                    ? -1
                    : cells.keys.reduce((a, b) => a > b ? a : b));
            i++
          )
            [for (var col = 0; col <= maximum; col++) cells[i]?[col] ?? ''],
        ];
        final blocks = <OfficeBlock>[OfficeBlock(rows: rows)];
        final sheetRelations = rels(
          '${name.substring(0, name.lastIndexOf('/') + 1)}_rels/${name.split('/').last}.rels',
        );
        for (final drawing in nodes(document, 'drawing')) {
          final path = sheetRelations[attr(drawing, 'id')];
          if (path == null) continue;
          final drawingName = resolve(name, path);
          final drawingRelations = rels(
            '${drawingName.substring(0, drawingName.lastIndexOf('/') + 1)}_rels/${drawingName.split('/').last}.rels',
          );
          for (final blip in nodes(xml(drawingName), 'blip')) {
            final media = drawingRelations[attr(blip, 'embed')];
            if (media != null) {
              final image = files[resolve(drawingName, media)];
              if (image != null) blocks.add(OfficeBlock(image: image));
            }
          }
        }
        sections.add(OfficeSection(attr(sheet, 'name') ?? 'Sheet', blocks));
      }
      return OfficeDocument('Excel', sections);
    }
    if (extension.toLowerCase() == 'pptx') {
      final presentation = xml('ppt/presentation.xml'),
          relations = rels('ppt/_rels/presentation.xml.rels');
      final size = nodes(presentation, 'sldSz').firstOrNull;
      final width =
              double.tryParse(size == null ? '' : attr(size, 'cx') ?? '') ??
              9144000,
          height =
              double.tryParse(size == null ? '' : attr(size, 'cy') ?? '') ??
              6858000;
      final sections = <OfficeSection>[];
      for (final slide in nodes(presentation, 'sldId')) {
        final target = relations[attr(slide, 'id')];
        if (target == null) continue;
        final path = resolve('ppt/presentation.xml', target), doc = xml(path);
        final slideRels = rels(
          '${path.substring(0, path.lastIndexOf('/') + 1)}_rels/${path.split('/').last}.rels',
        );
        final blocks = <OfficeBlock>[];
        for (final shape in doc.descendants.whereType<XmlElement>().where(
          (e) => e.name.local == 'sp' || e.name.local == 'pic',
        )) {
          final transform = nodes(shape, 'xfrm').firstOrNull,
              off = transform == null
                  ? null
                  : nodes(transform, 'off').firstOrNull,
              ext = transform == null
                  ? null
                  : nodes(transform, 'ext').firstOrNull;
          final left =
                  (double.tryParse(off == null ? '' : attr(off, 'x') ?? '') ??
                      0) /
                  width,
              top =
                  (double.tryParse(off == null ? '' : attr(off, 'y') ?? '') ??
                      0) /
                  height;
          final w =
                  (double.tryParse(ext == null ? '' : attr(ext, 'cx') ?? '') ??
                      width) /
                  width,
              h =
                  (double.tryParse(ext == null ? '' : attr(ext, 'cy') ?? '') ??
                      height * .2) /
                  height;
          Uint8List? image;
          final blip = nodes(shape, 'blip').firstOrNull;
          final media = blip == null ? null : slideRels[attr(blip, 'embed')];
          if (media != null) image = files[resolve(path, media)];
          final textRuns = runs(shape);
          if (image != null || textRuns.isNotEmpty) {
            blocks.add(
              OfficeBlock(
                runs: textRuns,
                image: image,
                left: left,
                top: top,
                width: w,
                height: h,
              ),
            );
          }
        }
        sections.add(OfficeSection('Slide ${sections.length + 1}', blocks));
      }
      return OfficeDocument(
        'PowerPoint',
        sections,
        aspectRatio: width / height,
      );
    }
    throw const FormatException(
      'Import DOCX, XLSX or PPTX files. Convert legacy DOC/XLS/PPT files first.',
    );
  }
}
