import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_text_shaper/pdf_text_shaper.dart';

class PdfTextBox {
  const PdfTextBox({
    required this.id,
    required this.text,
    this.font = 'Noto Sans',
    this.size = 18,
    this.bold = false,
    this.color = 0xff111111,
    this.align = 'left',
    this.left = 48,
    this.bottom = 48,
    this.width = 280,
    this.height = 120,
    this.rotation = 0,
  });
  final String id, text, font, align;
  final double size, left, bottom, width, height;
  final bool bold;
  final int color;
  final int rotation;

  PdfTextBox copyWith({
    String? id,
    String? text,
    String? font,
    double? size,
    bool? bold,
    int? color,
    String? align,
    double? left,
    double? bottom,
    double? width,
    double? height,
    int? rotation,
  }) => PdfTextBox(
    id: id ?? this.id,
    text: text ?? this.text,
    font: font ?? this.font,
    size: size ?? this.size,
    bold: bold ?? this.bold,
    color: color ?? this.color,
    align: align ?? this.align,
    left: left ?? this.left,
    bottom: bottom ?? this.bottom,
    width: width ?? this.width,
    height: height ?? this.height,
    rotation: rotation ?? this.rotation,
  );

  void validate() {
    if (id.isEmpty ||
        id.length > 100 ||
        text.trim().isEmpty ||
        text.length > 4000) {
      throw ArgumentError('Enter 1–4000 characters of text.');
    }
    if (!['Noto Sans', 'Noto Serif'].contains(font) ||
        !['left', 'center', 'right'].contains(align) ||
        color < 0 ||
        color > 0xffffffff ||
        rotation < 0 ||
        rotation > 3) {
      throw ArgumentError('Invalid text style.');
    }
    if (![size, left, bottom, width, height].every((n) => n.isFinite) ||
        size < 6 ||
        size > 144 ||
        width < 12 ||
        height < 12 ||
        width > 10000 ||
        height > 10000 ||
        left < 0 ||
        bottom < 0) {
      throw ArgumentError(
        'Use font size 6–144, positive box dimensions and finite page positions.',
      );
    }
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'id': id,
    'text': text,
    'font': font,
    'size': size,
    'bold': bold,
    'color': color,
    'align': align,
    'left': left,
    'bottom': bottom,
    'width': width,
    'height': height,
    'rotation': rotation,
  };
  factory PdfTextBox.fromJson(Map<String, dynamic> data) {
    if (data['version'] != 1) {
      throw const FormatException('Unknown text-box version.');
    }
    final result = PdfTextBox(
      id: data['id'] as String,
      text: data['text'] as String,
      font: data['font'] as String,
      size: (data['size'] as num).toDouble(),
      bold: data['bold'] as bool,
      color: data['color'] as int,
      align: data['align'] as String,
      left: (data['left'] as num).toDouble(),
      bottom: (data['bottom'] as num).toDouble(),
      width: (data['width'] as num).toDouble(),
      height: (data['height'] as num).toDouble(),
      rotation: data['rotation'] as int? ?? 0,
    );
    result.validate();
    return result;
  }
}

/// Complex-script glyphs are shaped with HarfBuzz and saved as vector paths.
/// The embedded Unicode layer retains search/copy; no page rasterization.
class TextBoxRenderer {
  static final Map<String, Uint8List> _fontBytes = {};
  static Future<Uint8List> _font(String name) async =>
      _fontBytes[name] ??= (await rootBundle.load('assets/fonts/$name.ttf'))
          .buffer
          .asUint8List();

  static Future<Uint8List> pdf(PdfTextBox box) async {
    box.validate();
    final serif = box.font == 'Noto Serif';
    final weight = box.bold ? 'Bold' : 'Regular';
    final latin = ShapedFont.fromBytes(
      await _font('${serif ? 'NotoSerif' : 'NotoSans'}-$weight'),
      name: box.font,
    );
    ShapedFont? sinhala;
    try {
      sinhala = ShapedFont.fromBytes(
        await _font(
          '${serif ? 'NotoSerifSinhala' : 'NotoSansSinhala'}-$weight',
        ),
        name: '${box.font} Sinhala',
      );
      final shaped = ShapedText(
        box.text.replaceAll('\r\n', '\n').replaceAll('\t', '    '),
        style: ShapedTextStyle(
          font: latin,
          fallbackFonts: [sinhala],
          fontSize: box.size,
          color: PdfColor(
            ((box.color >> 16) & 255) / 255,
            ((box.color >> 8) & 255) / 255,
            (box.color & 255) / 255,
          ),
          align: box.align == 'center'
              ? ShapedTextAlign.center
              : box.align == 'right'
              ? ShapedTextAlign.end
              : ShapedTextAlign.start,
          preserveUnicodeText: true,
        ),
      );
      final document = pw.Document();
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(box.width, box.height),
          margin: pw.EdgeInsets.zero,
          build: (_) => shaped,
        ),
      );
      final bytes = await document.save();
      if (shaped.hasMoreWidgets) {
        throw StateError(
          'Text does not fit. Increase the box height/width or reduce the font size.',
        );
      }
      return bytes;
    } finally {
      sinhala?.dispose();
      latin.dispose();
    }
  }
}
