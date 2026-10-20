import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/pdfium_object_editor.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'support/form_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('AcroForm text and checkbox fill, save, reopen and undo', () async {
    final folder = await Directory.systemTemp.createTemp('forms-');
    pdfrx.Pdfrx.cacheDirectoryPath ??= folder.path;
    final file = File('${folder.path}/form.pdf');
    await file.writeAsBytes(formFixture());
    final editor = await PdfiumObjectEditor.open(file.path);
    try {
      final fields = await editor.formFields();
      expect(fields.length, 2);
      final text = fields.firstWhere((f) => f.name == 'name'),
          check = fields.firstWhere((f) => f.name == 'approved');
      expect(text.value, 'Initial');
      expect(check.checked, isFalse);
      await editor.fillFormField(text.page, text.index, text: 'Filled locally');
      await editor.fillFormField(check.page, check.index, checked: true);
      expect(
        (await editor.formFields())
            .firstWhere((f) => f.name == 'approved')
            .checked,
        isTrue,
      );
      await editor.saveTo('${folder.path}/filled.pdf');
      final reopened = await PdfiumObjectEditor.open(
        '${folder.path}/filled.pdf',
      );
      try {
        final saved = await reopened.formFields();
        expect(
          saved.firstWhere((f) => f.name == 'name').value,
          'Filled locally',
        );
        expect(saved.firstWhere((f) => f.name == 'approved').checked, isTrue);
      } finally {
        await reopened.dispose();
      }
      await editor.undo();
      expect(
        (await editor.formFields())
            .firstWhere((f) => f.name == 'approved')
            .checked,
        isFalse,
      );
      await editor.undo();
      expect(
        (await editor.formFields()).firstWhere((f) => f.name == 'name').value,
        'Initial',
      );
    } finally {
      await editor.dispose();
      await folder.delete(recursive: true);
    }
  });
}
