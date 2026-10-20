import 'dart:convert';
import 'dart:typed_data';

/// Three native object types on each page: text, path and a small RGB image.
Uint8List fixturePdf({int pages = 3}) {
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  void object(String value) {
    offsets.add(latin1.encode(out.toString()).length);
    out.write('${offsets.length - 1} 0 obj\n$value\nendobj\n');
  }

  object('<< /Type /Catalog /Pages 2 0 R >>');
  object(
    '<< /Type /Pages /Count $pages /Kids [${List.generate(pages, (i) => '${5 + i * 2} 0 R').join(' ')}] >>',
  );
  object('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  object(
    '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length 25 >>\nstream\nFF000000FF000000FFFFFFFF>\nendstream',
  );
  for (var i = 0; i < pages; i++) {
    object(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << /Font << /F1 3 0 R >> /XObject << /Im1 4 0 R >> >> /Contents ${6 + i * 2} 0 R >>',
    );
    final content =
        'BT /F1 20 Tf 40 420 Td (Hello Pageflow Hello ${i + 1}) Tj ET\nq 0 0.5 0.5 rg 40 300 80 40 re f Q\nq 40 0 0 40 160 300 cm /Im1 Do Q';
    object('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }
  final xref = latin1.encode(out.toString()).length;
  out.write('xref\n0 ${offsets.length}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(latin1.encode(out.toString()));
}
