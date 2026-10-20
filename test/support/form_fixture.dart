import 'dart:convert';
import 'dart:typed_data';

Uint8List formFixture() {
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R /AcroForm 6 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << /Font << /Helv 4 0 R >> >> /Contents 5 0 R /Annots [7 0 R 8 0 R] >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length 0 >>\nstream\n\nendstream',
    '<< /Fields [7 0 R 8 0 R] /DA (/Helv 14 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >>',
    '<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [40 400 300 440] /V (Initial) /DA (/Helv 14 Tf 0 g) /F 4 /P 3 0 R >>',
    '<< /Type /Annot /Subtype /Widget /FT /Btn /T (approved) /Rect [40 340 60 360] /V /Off /AS /Off /F 4 /P 3 0 R /AP << /N << /Yes 9 0 R /Off 10 0 R >> >> >>',
    '<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Length 28 >>\nstream\n0 0 20 20 re S 2 2 16 16 re f\nendstream',
    '<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Length 14 >>\nstream\n0 0 20 20 re S\nendstream',
  ];
  final out = BytesBuilder();
  final offsets = [0];
  void text(String value) => out.add(latin1.encode(value));
  text('%PDF-1.7\n');
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    text('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  text('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    text('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  text(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return out.takeBytes();
}
