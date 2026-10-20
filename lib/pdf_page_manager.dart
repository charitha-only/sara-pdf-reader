import 'app_language.dart';

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'pdfium_object_editor.dart';

List<int> parsePdfPages(String expression, int pageCount) {
  final pages = <int>[];
  for (final part in expression.split(',')) {
    final match = RegExp(r'^\s*(\d+)(?:\s*-\s*(\d+))?\s*$').firstMatch(part);
    if (match == null) throw ArgumentError('Use pages such as 1, 3-5.');
    final start = int.parse(match.group(1)!),
        end = int.parse(match.group(2) ?? match.group(1)!);
    if (start < 1 || end < start || end > pageCount) {
      throw ArgumentError('Choose pages between 1 and $pageCount.');
    }
    for (var p = start; p <= end; p++) {
      if (!pages.contains(p)) pages.add(p);
    }
  }
  return pages;
}

class PdfPageManager extends StatefulWidget {
  const PdfPageManager({super.key, required this.editor});
  final PdfiumObjectEditor editor;
  @override
  State<PdfPageManager> createState() => _PdfPageManagerState();
}

class _PdfPageManagerState extends State<PdfPageManager> {
  late Future<pdfrx.PdfDocument> loading;
  pdfrx.PdfDocument? document;
  final selected = <int>{};
  bool busy = false, changed = false;
  final outputs = <String>[];
  @override
  void initState() {
    super.initState();
    loading = _load();
  }

  Future<pdfrx.PdfDocument> _load() async {
    final doc = await pdfrx.PdfDocument.openData(widget.editor.currentBytes);
    if (!mounted) {
      await doc.dispose();
      return doc;
    }
    final old = document;
    document = doc;
    await old?.dispose();
    return doc;
  }

  @override
  void dispose() {
    document?.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      changed = true;
      if (mounted) {
        setState(() {
          selected.clear();
          loading = _load();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: LocalizedText('$e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> input(String title, String hint, {String value = ''}) async {
    final controller = TextEditingController(text: value);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const LocalizedText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const LocalizedText('Continue'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), controller.dispose);
    return result;
  }

  Future<void> split() async {
    final selectedPages = selected.toList()..sort();
    final expression = await input(
      'Split PDF',
      'Separate groups with ; e.g. 1-2;3-4;5',
      value: selectedPages.join(';'),
    );
    if (!mounted || expression == null) return;
    await run(() async {
      final groups = expression
          .split(';')
          .map((g) => parsePdfPages(g, widget.editor.pageCount))
          .toList();
      final parts = await widget.editor.splitPages(groups);
      if (Platform.isAndroid) {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final saved = await const MethodChannel('pageflow_reader/files')
            .invokeMethod<List<dynamic>>('savePdfBatch', {
              'names': [
                for (var i = 0; i < parts.length; i++)
                  'pageflow-part-${i + 1}-$stamp.pdf',
              ],
              'bytes': parts,
            });
        if (saved != null) outputs.addAll(saved.cast<String>());
        if (mounted && saved != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: LocalizedText('${saved.length} PDFs saved.')),
          );
        }
        return;
      }
      final result = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a folder for split PDFs',
      );
      if (result == null) return;
      for (var i = 0; i < parts.length; i++) {
        final path =
            '$result${Platform.pathSeparator}pageflow-part-${i + 1}-${DateTime.now().microsecondsSinceEpoch}.pdf';
        await File(path).writeAsBytes(parts[i], flush: true);
        outputs.add(path);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: LocalizedText('${parts.length} PDFs saved.')),
        );
      }
    });
  }

  Future<void> insert() async {
    final position = await input(
      'Insert before page',
      '1 to ${widget.editor.pageCount + 1}',
      value: '${selected.isEmpty ? 1 : selected.first}',
    );
    if (!mounted || position == null) return;
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (!mounted || picked == null) return;
    await run(
      () async => widget.editor.insertPdf(
        int.parse(position),
        await picked.readAsBytes(),
      ),
    );
  }

  Future<void> crop() async {
    if (selected.length != 1) return;
    final page = selected.single,
        size = await widget.editor.pageSize(selected.single);
    if (!mounted) return;
    final values = await input(
      'Crop page $page',
      'Left, bottom, right, top (PDF points)',
      value: '0,0,${size.width},${size.height}',
    );
    if (!mounted || values == null) return;
    await run(() async {
      final parts = values.split(',').map(double.parse).toList();
      if (parts.length != 4) {
        throw ArgumentError('Enter four crop coordinates.');
      }
      await widget.editor.cropPage(
        page,
        left: parts[0],
        bottom: parts[1],
        right: parts[2],
        top: parts[3],
      );
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && !busy) Navigator.pop(context, changed);
    },
    child: Scaffold(
      appBar: AppBar(
        title: const LocalizedText('Pages and split PDF'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: busy ? null : () => Navigator.pop(context, changed),
        ),
      ),
      body: Column(
        children: [
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy ? null : insert,
                child: const LocalizedText('Insert PDF'),
              ),
              TextButton(
                onPressed: busy || selected.isEmpty
                    ? null
                    : () => run(
                        () async =>
                            widget.editor.deletePages(selected.toList()),
                      ),
                child: const LocalizedText('Delete selected'),
              ),
              TextButton(
                onPressed: busy || selected.length != 1 ? null : crop,
                child: const LocalizedText('Crop page'),
              ),
              TextButton(
                onPressed: busy ? null : split,
                child: const LocalizedText('Split PDF'),
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: FutureBuilder<pdfrx.PdfDocument>(
              future: loading,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: LocalizedText('${snapshot.error}'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final doc = snapshot.data!;
                return GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: .65,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: doc.pages.length,
                  itemBuilder: (context, i) => InkWell(
                    onTap: busy
                        ? null
                        : () => setState(
                            () => selected.contains(i + 1)
                                ? selected.remove(i + 1)
                                : selected.add(i + 1),
                          ),
                    child: Card(
                      color: selected.contains(i + 1)
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null,
                      child: Column(
                        children: [
                          Expanded(
                            child: pdfrx.PdfPageView(
                              document: doc,
                              pageNumber: i + 1,
                              maximumDpi: 100,
                            ),
                          ),
                          CheckboxListTile(
                            value: selected.contains(i + 1),
                            title: LocalizedText('Page ${i + 1}'),
                            onChanged: busy
                                ? null
                                : (v) => setState(
                                    () => v == true
                                        ? selected.add(i + 1)
                                        : selected.remove(i + 1),
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
        ],
      ),
    ),
  );
}
