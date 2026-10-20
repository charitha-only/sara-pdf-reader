import 'app_language.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:image/image.dart' as img;

import 'dart:math' as math;

import 'text_box.dart';

class TextBoxDialog extends StatefulWidget {
  const TextBoxDialog({super.key, required this.initial, this.editing = false});
  final PdfTextBox initial;
  final bool editing;
  @override
  State<TextBoxDialog> createState() => _TextBoxDialogState();
}

class _TextBoxDialogState extends State<TextBoxDialog> {
  late final Map<String, TextEditingController> fields;
  late String font, alignment;
  late bool bold;
  Uint8List? preview;
  String? error;
  bool busy = false;
  int generation = 0;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    final box = widget.initial;
    font = box.font;
    alignment = box.align;
    bold = box.bold;
    fields = {
      'Text': TextEditingController(text: box.text),
      'Font size (pt)': TextEditingController(text: '${box.size}'),
      'Left (pt)': TextEditingController(text: '${box.left}'),
      'Bottom (pt)': TextEditingController(text: '${box.bottom}'),
      'Width (pt)': TextEditingController(text: '${box.width}'),
      'Height (pt)': TextEditingController(text: '${box.height}'),
      'Color (hex)': TextEditingController(
        text: (box.color & 0xffffff).toRadixString(16).padLeft(6, '0'),
      ),
    };
    for (final field in fields.values) {
      field.addListener(_changed);
    }
    _changed();
  }

  PdfTextBox _value() {
    double number(String key) {
      final value = double.tryParse(fields[key]!.text);
      if (value == null || !value.isFinite) {
        throw ArgumentError('Enter a valid $key.');
      }
      return value;
    }

    final hex = fields['Color (hex)']!.text.replaceFirst('#', '').trim();
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
      throw ArgumentError('Use a six-digit color such as 185ABC.');
    }
    return widget.initial.copyWith(
      text: fields['Text']!.text,
      font: font,
      size: number('Font size (pt)'),
      left: number('Left (pt)'),
      bottom: number('Bottom (pt)'),
      width: number('Width (pt)'),
      height: number('Height (pt)'),
      bold: bold,
      align: alignment,
      color: 0xff000000 | int.parse(hex, radix: 16),
    );
  }

  void _changed() {
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 250), _render);
  }

  Future<void> _render() async {
    final request = ++generation;
    try {
      final bytes = await TextBoxRenderer.pdf(_value());
      await pdfrx.pdfrxFlutterInitialize();
      final document = await pdfrx.PdfDocument.openData(bytes);
      Uint8List? raster;
      try {
        final page = document.pages.first;
        final scale = math.min(
          800 / page.width,
          math.sqrt(1000000 / (page.width * page.height)),
        );
        final rendered = await page.render(
          fullWidth: (page.width * scale).roundToDouble(),
          fullHeight: (page.height * scale).roundToDouble(),
        );
        if (rendered != null) {
          try {
            raster = img.encodePng(
              img.Image.fromBytes(
                width: rendered.width,
                height: rendered.height,
                bytes: rendered.pixels.buffer,
                bytesOffset: rendered.pixels.offsetInBytes,
                numChannels: 4,
                order: img.ChannelOrder.bgra,
              ),
            );
          } finally {
            rendered.dispose();
          }
        }
      } finally {
        await document.dispose();
      }
      if (mounted && request == generation) {
        setState(() {
          preview = raster;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && request == generation) {
        setState(() {
          error = '$e';
          preview = null;
        });
      }
    }
  }

  Future<void> _submit() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final box = _value();
      await TextBoxRenderer.pdf(box);
      if (mounted) Navigator.pop(context, box);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Widget _field(String key, {bool text = false}) => TextField(
    controller: fields[key],
    maxLines: text ? 4 : 1,
    keyboardType: text || key == 'Color (hex)'
        ? TextInputType.text
        : const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: tr(key)),
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.editing ? 'Edit text and style' : 'Add selectable text'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field('Text', text: true),
            DropdownButtonFormField<String>(
              initialValue: font,
              decoration: InputDecoration(labelText: tr('Font family')),
              items: const [
                DropdownMenuItem(
                  value: 'Noto Sans',
                  child: LocalizedText('Noto Sans · Sinhala / English'),
                ),
                DropdownMenuItem(
                  value: 'Noto Serif',
                  child: LocalizedText('Noto Serif · Sinhala / English'),
                ),
              ],
              onChanged: (v) {
                setState(() => font = v ?? font);
                _changed();
              },
            ),
            CheckboxListTile(
              title: const LocalizedText('Bold'),
              value: bold,
              contentPadding: EdgeInsets.zero,
              onChanged: (v) {
                setState(() => bold = v ?? false);
                _changed();
              },
            ),
            _field('Font size (pt)'),
            _field('Color (hex)'),
            DropdownButtonFormField<String>(
              initialValue: alignment,
              decoration: InputDecoration(labelText: tr('Alignment')),
              items: const [
                DropdownMenuItem(value: 'left', child: LocalizedText('Left')),
                DropdownMenuItem(
                  value: 'center',
                  child: LocalizedText('Center'),
                ),
                DropdownMenuItem(value: 'right', child: LocalizedText('Right')),
              ],
              onChanged: (v) {
                setState(() => alignment = v ?? alignment);
                _changed();
              },
            ),
            Row(
              children: [
                Expanded(child: _field('Left (pt)')),
                const SizedBox(width: 8),
                Expanded(child: _field('Bottom (pt)')),
              ],
            ),
            Row(
              children: [
                Expanded(child: _field('Width (pt)')),
                const SizedBox(width: 8),
                Expanded(child: _field('Height (pt)')),
              ],
            ),
            const SizedBox(height: 12),
            if (error != null)
              Text(
                error!,
                key: const ValueKey('text-box-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (preview != null)
              SizedBox(
                height: 180,
                child: Image.memory(
                  preview!,
                  key: ValueKey(generation),
                  fit: BoxFit.contain,
                ),
              ),
            const LocalizedText(
              'Text wraps to the box width. Increase the box height if it does not fit. Positions are measured from the bottom-left of the page.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const LocalizedText('Cancel'),
      ),
      FilledButton(
        onPressed: busy ? null : _submit,
        child: Text(
          busy
              ? 'Preparing…'
              : widget.editing
              ? 'Apply changes'
              : 'Add text',
        ),
      ),
    ],
  );
}
