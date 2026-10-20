import 'dart:math' as math;
import 'dart:convert';

import 'task_progress.dart';

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

/// Page images preserve appearance; text in this mode is not editable.
class OfficeLayoutExport {
  static Future<Uint8List> create(
    Uint8List pdf,
    String format, {
    TaskProgress? progress,
  }) async {
    await pdfrx.pdfrxFlutterInitialize();
    final document = await pdfrx.PdfDocument.openData(pdf);
    final archive = Archive();
    void add(String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    const relns =
        'http://schemas.openxmlformats.org/package/2006/relationships';
    const office =
        'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
    const drawing = 'http://schemas.openxmlformats.org/drawingml/2006/main';
    const sheet = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
    final overrides = <String>[];
    final names = <String>[];
    try {
      if (document.pages.length > 100) {
        throw ArgumentError('Layout export supports up to 100 pages.');
      }
      for (var i = 0; i < document.pages.length; i++) {
        await progress?.step(
          'Rendering export page ${i + 1} of ${document.pages.length}',
          done: i,
          total: document.pages.length,
        );
        final page = document.pages[i];
        final scale = (1400 / page.width).clamp(.1, 2.0);
        final rendered = await page.render(
          fullWidth: (page.width * scale).roundToDouble(),
          fullHeight: (page.height * scale).roundToDouble(),
        );
        if (rendered == null) {
          throw StateError('Could not render page ${i + 1}.');
        }
        try {
          final image = img.Image.fromBytes(
            width: rendered.width,
            height: rendered.height,
            bytes: rendered.pixels.buffer,
            bytesOffset: rendered.pixels.offsetInBytes,
            numChannels: 4,
            order: img.ChannelOrder.bgra,
          );
          final png = img.encodePng(image);
          final root = format == 'word'
              ? 'word'
              : format == 'excel'
              ? 'xl'
              : 'ppt';
          archive.addFile(
            ArchiveFile('$root/media/page${i + 1}.png', png.length, png),
          );
          names.add('page${i + 1}.png');
          final n = i + 1,
              cx = (page.width * 12700).round(),
              cy = (page.height * 12700).round();
          final fit = math.min(
            document.pages.first.width / page.width,
            document.pages.first.height / page.height,
          );
          final slideCx = (page.width * fit * 12700).round(),
              slideCy = (page.height * fit * 12700).round();
          final slideX = ((document.pages.first.width * 12700 - slideCx) / 2)
                  .round(),
              slideY = ((document.pages.first.height * 12700 - slideCy) / 2)
                  .round();

          final pic =
              '<a:graphic xmlns:a="$drawing"><a:graphicData uri="$drawing/picture"><pic:pic xmlns:pic="$drawing/picture"><pic:nvPicPr><pic:cNvPr id="$n" name="Page $n"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip xmlns:r="$office" r:embed="rId$n"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>';
          if (format == 'word') {
            names[i] =
                '<w:p><w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr><w:r><w:drawing><wp:anchor xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="0" behindDoc="1" locked="0" layoutInCell="1" allowOverlap="1"><wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="page"><wp:posOffset>0</wp:posOffset></wp:positionH><wp:positionV relativeFrom="page"><wp:posOffset>0</wp:posOffset></wp:positionV><wp:extent cx="$cx" cy="$cy"/><wp:wrapNone/><wp:docPr id="$n" name="Page $n"/><wp:cNvGraphicFramePr/>$pic</wp:anchor></w:drawing></w:r></w:p>${i + 1 < document.pages.length ? '<w:p><w:pPr><w:sectPr><w:type w:val="nextPage"/><w:pgSz w:w="${(page.width * 20).round()}" w:h="${(page.height * 20).round()}"/><w:pgMar w:top="0" w:right="0" w:bottom="0" w:left="0"/></w:sectPr></w:pPr></w:p>' : ''}';
          } else if (format == 'excel') {
            add(
              'xl/worksheets/sheet$n.xml',
              '<worksheet xmlns="$sheet" xmlns:r="$office"><sheetData/><drawing r:id="rId1"/></worksheet>',
            );
            add(
              'xl/worksheets/_rels/sheet$n.xml.rels',
              '<Relationships xmlns="$relns"><Relationship Id="rId1" Type="$office/drawing" Target="../drawings/drawing$n.xml"/></Relationships>',
            );
            add(
              'xl/drawings/drawing$n.xml',
              '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="$drawing" xmlns:r="$office"><xdr:oneCellAnchor><xdr:from><xdr:col>0</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>0</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:ext cx="$cx" cy="$cy"/><xdr:pic><xdr:nvPicPr><xdr:cNvPr id="$n" name="Page $n"/><xdr:cNvPicPr/></xdr:nvPicPr><xdr:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill><xdr:spPr><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:oneCellAnchor></xdr:wsDr>',
            );
            add(
              'xl/drawings/_rels/drawing$n.xml.rels',
              '<Relationships xmlns="$relns"><Relationship Id="rId1" Type="$office/image" Target="../media/page$n.png"/></Relationships>',
            );
            overrides.add(
              '<Override PartName="/xl/worksheets/sheet$n.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/drawings/drawing$n.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>',
            );
          } else {
            add(
              'ppt/slides/slide$n.xml',
              '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="$drawing" xmlns:r="$office"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:pic><p:nvPicPr><p:cNvPr id="2" name="Page $n"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="$slideX" y="$slideY"/><a:ext cx="$slideCx" cy="$slideCy"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>',
            );
            add(
              'ppt/slides/_rels/slide$n.xml.rels',
              '<Relationships xmlns="$relns"><Relationship Id="rId1" Type="$office/image" Target="../media/page$n.png"/></Relationships>',
            );
            overrides.add(
              '<Override PartName="/ppt/slides/slide$n.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>',
            );
          }
        } finally {
          rendered.dispose();
        }
      }
      final count = document.pages.length;
      String relations(String type, String path) =>
          '<Relationships xmlns="$relns">${List.generate(count, (i) => '<Relationship Id="rId${i + 1}" Type="$office/$type" Target="$path${i + 1}.${type == 'image' ? 'png' : 'xml'}"/>').join()}</Relationships>';
      String root, contentType;
      if (format == 'word') {
        root = 'word/document.xml';
        contentType = 'wordprocessingml.document';
        add(
          root,
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>${names.join()}<w:sectPr><w:pgSz w:w="${(document.pages.last.width * 20).round()}" w:h="${(document.pages.last.height * 20).round()}"/><w:pgMar w:top="0" w:right="0" w:bottom="0" w:left="0"/></w:sectPr></w:body></w:document>',
        );
        add('word/_rels/document.xml.rels', relations('image', 'media/page'));
      } else if (format == 'excel') {
        root = 'xl/workbook.xml';
        contentType = 'spreadsheetml.sheet';
        add(
          root,
          '<workbook xmlns="$sheet" xmlns:r="$office"><sheets>${List.generate(count, (i) => '<sheet name="Page ${i + 1}" sheetId="${i + 1}" r:id="rId${i + 1}"/>').join()}</sheets></workbook>',
        );
        add(
          'xl/_rels/workbook.xml.rels',
          relations('worksheet', 'worksheets/sheet'),
        );
      } else {
        root = 'ppt/presentation.xml';
        contentType = 'presentationml.presentation';
        add(
          root,
          '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="$office"><p:sldIdLst>${List.generate(count, (i) => '<p:sldId id="${256 + i}" r:id="rId${i + 1}"/>').join()}</p:sldIdLst><p:sldSz cx="${(document.pages.first.width * 12700).round()}" cy="${(document.pages.first.height * 12700).round()}"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>',
        );
        add(
          'ppt/_rels/presentation.xml.rels',
          relations('slide', 'slides/slide'),
        );
      }
      add(
        '_rels/.rels',
        '<Relationships xmlns="$relns"><Relationship Id="rId1" Type="$office/officeDocument" Target="$root"/></Relationships>',
      );
      add(
        '[Content_Types].xml',
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/$root" ContentType="application/vnd.openxmlformats-officedocument.$contentType.main+xml"/>${overrides.join()}</Types>',
      );
      await progress?.step('Packing Office file…');
      final result = Uint8List.fromList(ZipEncoder().encode(archive));
      progress?.check();
      return result;
    } finally {
      await document.dispose();
    }
  }
}
