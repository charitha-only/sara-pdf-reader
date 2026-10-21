import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

Uint8List fixtureEpub({
  bool encrypted = false,
  bool traversal = false,
  bool obfuscatedFont = false,
}) {
  final zip = Archive();
  void add(String path, String text) {
    final bytes = utf8.encode(text);
    zip.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
  );
  add(
    'OPS/book.opf',
    '''<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Sara test book</dc:title></metadata><manifest><item id="two" href="two.xhtml"/><item id="one" href="one.xhtml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>''',
  );
  add(
    'OPS/one.xhtml',
    '<html><head><title>First chapter</title></head><body><h1>Chapter One</h1><p>Sinhala සිංහල <strong>bold text</strong> and <em>italic text</em>.</p><script>DO NOT EXECUTE</script></body></html>',
  );
  add(
    'OPS/two.xhtml',
    '<html><body><h1>Chapter Two</h1>${List.generate(100, (i) => '<p>Reading line $i. This is the second chapter.</p>').join()}</body></html>',
  );
  if (encrypted) {
    add(
      'META-INF/encryption.xml',
      '<encryption><EncryptedData><EncryptionMethod Algorithm="DRM"/></EncryptedData></encryption>',
    );
  }
  if (obfuscatedFont) {
    add(
      'META-INF/encryption.xml',
      '<encryption><EncryptedData><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><CipherReference URI="OPS/font.ttf"/></EncryptedData></encryption>',
    );
    add('OPS/font.ttf', 'unused font');
  }
  if (traversal) {
    add('../outside.txt', 'must never be extracted');
  }
  return Uint8List.fromList(ZipEncoder().encode(zip));
}
