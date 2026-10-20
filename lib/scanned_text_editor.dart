import 'dart:async';

import 'app_language.dart';

import 'package:flutter/material.dart';

import 'task_progress.dart';

import 'pdfium_object_editor.dart';
import 'sinhala_ocr.dart';
import 'text_box_dialog.dart';
import 'text_box.dart';

class ScannedTextEditor extends StatefulWidget {
  const ScannedTextEditor({
    super.key,
    required this.editor,
    required this.page,
  });
  final PdfiumObjectEditor editor;
  final int page;
  @override
  State<ScannedTextEditor> createState() => _ScannedTextEditorState();
}

class _ScannedTextEditorState extends State<ScannedTextEditor> {
  late Future<OcrPage> loading;
  OcrLine? selected;
  Rect? manual;
  Offset? start;
  bool busy = false;
  final background = TextEditingController();
  @override
  void initState() {
    super.initState();
    loading = _read();
  }

  Future<OcrPage> _read() async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) throw const TaskCancelled();
    return runPdfTask(context, 'Recognizing scanned Sinhala text', (
      progress,
    ) async {
      progress.onCancel = () {
        unawaited(OfflineSinhalaOcr.cancel().catchError((Object error) {}));
      };
      await progress.step('Preparing page ${widget.page}…');
      final bytes = await widget.editor.scanSourceBytes(widget.page);
      await progress.step('Recognizing text on this page…');
      final result = await OfflineSinhalaOcr.recognize(bytes, widget.page);
      progress.check();
      return result;
    });
  }

  @override
  void dispose() {
    background.dispose();
    super.dispose();
  }

  Future<void> _correct(OcrPage page) async {
    final area = manual ?? selected?.pixels;
    if (area == null || busy) return;
    final line = selected ?? OcrLine('', area, 0);
    final edited = await showDialog<PdfTextBox>(
      context: context,
      builder: (_) =>
          TextBoxDialog(initial: page.suggestedBox(line), editing: true),
    );
    if (!mounted || edited == null) return;
    setState(() => busy = true);
    try {
      int? color;
      final value = background.text.replaceFirst('#', '').trim();
      if (value.isNotEmpty) {
        if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value)) {
          throw ArgumentError(
            'Use a six-digit background color or leave it empty for automatic matching.',
          );
        }
        color = int.parse(value, radix: 16);
      }
      final raster = await page.correctedBackground(area, background: color);
      await widget.editor.replaceScannedPage(
        widget.page,
        raster,
        page.nativeBox(edited),
        rotation: page.rotation,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: LocalizedText('Could not correct scanned text: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const LocalizedText('Correct scanned Sinhala text')),
    body: FutureBuilder<OcrPage>(
      future: loading,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LocalizedText(
                    'Offline OCR could not read this page.\n${snapshot.error}',
                  ),
                  TextButton(
                    onPressed: () => setState(() => loading = _read()),
                    child: const LocalizedText('Retry'),
                  ),
                ],
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                LocalizedText('Reading Sinhala text offlineâ€¦'),
              ],
            ),
          );
        }
        final page = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const LocalizedText(
              'Tap a recognized line, or drag over an area to type a correction. Review OCR text before saving.',
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth,
                    h = w * page.height / page.width;
                final region = manual ?? selected?.pixels;
                return GestureDetector(
                  onPanStart: busy
                      ? null
                      : (d) {
                          start = d.localPosition;
                        },
                  onPanUpdate: busy
                      ? null
                      : (d) {
                          if (start == null) return;
                          setState(() {
                            final rect = Rect.fromPoints(
                              start!,
                              d.localPosition,
                            ).intersect(Rect.fromLTWH(0, 0, w, h));
                            manual = Rect.fromLTRB(
                              rect.left / w * page.width,
                              rect.top / h * page.height,
                              rect.right / w * page.width,
                              rect.bottom / h * page.height,
                            );
                            selected = null;
                          });
                        },
                  child: SizedBox(
                    width: w,
                    height: h,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Image.memory(page.png, fit: BoxFit.fill),
                        ),
                        for (final line in page.lines)
                          Positioned(
                            left: line.pixels.left / page.width * w,
                            top: line.pixels.top / page.height * h,
                            width: line.pixels.width / page.width * w,
                            height: line.pixels.height / page.height * h,
                            child: InkWell(
                              onTap: busy
                                  ? null
                                  : () => setState(() {
                                      selected = line;
                                      manual = null;
                                    }),
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.teal.withValues(alpha: .6),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (region != null)
                          Positioned(
                            left: region.left / page.width * w,
                            top: region.top / page.height * h,
                            width: region.width / page.width * w,
                            height: region.height / page.height * h,
                            child: IgnorePointer(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.amber.withValues(alpha: .15),
                                  border: Border.all(
                                    color: Colors.orange,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            if (page.lines.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LocalizedText(
                  'No text was recognized. Drag a region and enter the text manually, or try a clearer scan.',
                ),
              ),
            for (final line in page.lines)
              ListTile(
                selected: selected == line,
                title: Text(line.text),
                subtitle: LocalizedText(
                  'Estimated OCR confidence ${line.confidence.round()}%',
                ),
                onTap: busy
                    ? null
                    : () => setState(() {
                        selected = line;
                        manual = null;
                      }),
              ),
            TextField(
              controller: background,
              decoration: InputDecoration(
                labelText: tr('Background color (hex, optional)'),
                hintText: tr('Automatic paper-color matching'),
              ),
            ),
            const SizedBox(height: 12),
            const LocalizedText(
              'Correction re-renders this scanned page and removes the selected pixels. Other pages and existing editable text boxes are kept. The imported original stays unchanged.',
            ),
            FilledButton.icon(
              onPressed: busy || (manual == null && selected == null)
                  ? null
                  : () => _correct(page),
              icon: const Icon(Icons.edit_note),
              label: Text(busy ? 'Correctingâ€¦' : 'Correct selected area'),
            ),
          ],
        );
      },
    ),
  );
}
