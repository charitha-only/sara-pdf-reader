import 'app_language.dart';

import 'package:flutter/material.dart';

import 'pdfium_object_editor.dart';
import 'pdf_forms.dart';

class PdfFormPage extends StatefulWidget {
  const PdfFormPage({super.key, required this.editor});
  final PdfiumObjectEditor editor;
  @override
  State<PdfFormPage> createState() => _PdfFormPageState();
}

class _PdfFormPageState extends State<PdfFormPage> {
  late Future<List<PdfFormField>> loading;
  bool busy = false, changed = false;
  @override
  void initState() {
    super.initState();
    loading = widget.editor.formFields();
  }

  Future<void> update(PdfFormField field, {String? text, bool? checked}) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.editor.fillFormField(
        field.page,
        field.index,
        text: text,
        checked: checked,
      );
      changed = true;
      if (mounted) setState(() => loading = widget.editor.formFields());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: LocalizedText('Could not fill this field: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> text(PdfFormField field) async {
    final controller = TextEditingController(text: field.value);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(field.name.isEmpty ? 'Text field' : field.name),
        content: TextField(
          controller: controller,
          maxLines: 4,
          maxLength: 4000,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LocalizedText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const LocalizedText('Apply'),
          ),
        ],
      ),
    );
    // The dialog owns its field until its route transition finishes.
    Future<void>.delayed(const Duration(milliseconds: 300), controller.dispose);
    if (!mounted || value == null) return;
    await update(field, text: value);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && !busy) Navigator.pop(context, changed);
    },
    child: Scaffold(
      appBar: AppBar(
        title: const LocalizedText('Fill PDF forms'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: busy ? null : () => Navigator.pop(context, changed),
        ),
      ),
      body: FutureBuilder<List<PdfFormField>>(
        future: loading,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: LocalizedText('Could not read forms: ${snapshot.error}'),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final fields = snapshot.data!;
          if (fields.isEmpty) {
            return const Center(
              child: LocalizedText('This PDF has no interactive form fields.'),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const LocalizedText(
                'Apply field changes, then save the PDF from the editor. Read-only and unsupported fields are shown without editing.',
              ),
              for (final field in fields)
                Card(
                  child: field.type == 2
                      ? CheckboxListTile(
                          value: field.checked,
                          title: Text(
                            field.name.isEmpty ? 'Checkbox' : field.name,
                          ),
                          subtitle: LocalizedText(
                            'Page ${field.page}${field.readOnly ? ' · Read-only' : ''}',
                          ),
                          onChanged: busy || field.readOnly
                              ? null
                              : (v) => update(field, checked: v),
                        )
                      : ListTile(
                          title: Text(
                            field.name.isEmpty ? 'Form field' : field.name,
                          ),
                          subtitle: LocalizedText(
                            'Page ${field.page} · ${field.value}${!field.supported ? ' · Unsupported field type' : ''}',
                          ),
                          trailing: field.supported && !field.readOnly
                              ? const Icon(Icons.edit)
                              : const Icon(Icons.lock_outline),
                          onTap: busy || field.readOnly || !field.supported
                              ? null
                              : () => text(field),
                        ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
