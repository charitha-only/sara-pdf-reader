import 'app_language.dart';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'pdfium_object_editor.dart';
import 'pdf_redaction.dart';

class PdfRedactionPage extends StatefulWidget {
  const PdfRedactionPage({super.key, required this.editor});
  final PdfiumObjectEditor editor;
  @override
  State<PdfRedactionPage> createState() => _PdfRedactionPageState();
}

class _PdfRedactionPageState extends State<PdfRedactionPage> {
  late Future<pdfrx.PdfDocument> loading;
  pdfrx.PdfDocument? document;
  final areas = <int, List<Rect>>{};
  int page = 1;
  Rect? current;
  Offset? start;
  bool busy = false;
  String status = '';
  @override
  void initState() {
    super.initState();
    loading = pdfrx.PdfDocument.openData(widget.editor.currentBytes)
        .then((doc) {
          document = doc;
          return doc;
        });
  }

  @override
  void dispose() {
    document?.dispose();
    super.dispose();
  }

  Future<void> apply() async {
    if (current != null) {
      areas.putIfAbsent(page, () => []).add(current!);
      current = null;
    }
    if (areas.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const LocalizedText('Permanently redact selected content?'),
        content: const LocalizedText(
          'The output is rebuilt from page images with the selected areas removed. Original text layers, annotations, attachments and metadata are omitted. The output’s text will not be selectable. Save a copy to keep the original.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const LocalizedText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const LocalizedText('Redact'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => busy = true);
    try {
      final bytes = await PermanentPdfRedaction.create(
        widget.editor.currentBytes,
        areas,
        progress: (done, total) {
          if (mounted) {
            setState(() => status = 'Redacting page $done of $total…');
          }
        },
      );
      await widget.editor.replaceWithSanitizedPdf(bytes);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: LocalizedText('Redaction failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const LocalizedText('Permanent redaction')),
    body: FutureBuilder<pdfrx.PdfDocument>(
      future: loading,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: LocalizedText('${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final doc = snapshot.data!;
        return Column(
          children: [
            Wrap(
              spacing: 8,
              children: [
                DropdownButton<int>(
                  value: page,
                  items: [
                    for (var i = 1; i <= doc.pages.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: LocalizedText('Page $i'),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (v) => setState(() {
                          page = v ?? 1;
                          current = null;
                        }),
                ),
                TextButton(
                  onPressed: busy || current == null
                      ? null
                      : () => setState(() {
                          areas.putIfAbsent(page, () => []).add(current!);
                          current = null;
                        }),
                  child: const LocalizedText('Add area'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          areas.remove(page);
                          current = null;
                        }),
                  child: const LocalizedText('Clear page areas'),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: LocalizedText(
                'Drag over sensitive content. Add areas on other pages, then apply redaction.',
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final aspect =
                      doc.pages[page - 1].width / doc.pages[page - 1].height;
                  final w = (constraints.maxHeight * aspect)
                          .clamp(0, constraints.maxWidth)
                          .toDouble(),
                      h = w / aspect;
                  return Center(
                    child: SizedBox(
                      width: w,
                      height: h,
                      child: GestureDetector(
                        onPanStart: busy
                            ? null
                            : (d) => start = d.localPosition,
                        onPanUpdate: busy
                            ? null
                            : (d) {
                                if (start == null) return;
                                setState(() {
                                  final rect = Rect.fromPoints(
                                    start!,
                                    d.localPosition,
                                  ).intersect(Rect.fromLTWH(0, 0, w, h));
                                  current = Rect.fromLTRB(
                                    rect.left / w,
                                    rect.top / h,
                                    rect.right / w,
                                    rect.bottom / h,
                                  );
                                });
                              },
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: pdfrx.PdfPageView(
                                document: doc,
                                pageNumber: page,
                                maximumDpi: 150,
                              ),
                            ),
                            for (final rect in [...areas[page] ?? [], ?current])
                              Positioned(
                                left: rect.left * w,
                                top: rect.top * h,
                                width: rect.width * w,
                                height: rect.height * h,
                                child: IgnorePointer(
                                  child: Container(
                                    color: Colors.black.withValues(alpha: .65),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (busy)
              Padding(padding: const EdgeInsets.all(8), child: Text(status)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton(
                onPressed: busy ? null : apply,
                child: Text(busy ? 'Redacting…' : 'Apply permanent redaction'),
              ),
            ),
          ],
        );
      },
    ),
  );
}
