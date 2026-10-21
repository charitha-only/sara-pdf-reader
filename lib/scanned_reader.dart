import 'app_language.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'sinhala_ocr.dart';
import 'task_progress.dart';

class ScannedReader extends StatefulWidget {
  const ScannedReader({
    super.key,
    required this.path,
    required this.page,
    required this.onPage,
  });
  final String path;
  final int page;
  final ValueChanged<int> onPage;
  @override
  State<ScannedReader> createState() => _ScannedReaderState();
}

class _ScannedReaderState extends State<ScannedReader> {
  final Map<int, String> pages = {};
  String language = 'sin+eng', query = '';
  File? cache;
  bool loading = true;
  bool recognizing = false;
  String? failure;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final stat = await File(widget.path).stat();
      final root = await getTemporaryDirectory();
      final key = sha256
          .convert(
            utf8.encode(
              '${widget.path}:${stat.size}:${stat.modified.microsecondsSinceEpoch}',
            ),
          )
          .toString();
      cache = File('${root.path}/sara-ocr-reader/$key.json');
      if (await cache!.exists() && await cache!.length() < 10 * 1024 * 1024) {
        final raw = jsonDecode(await cache!.readAsString());
        if (raw is Map) {
          final stored = raw['pages'] is Map ? raw['pages'] as Map : raw;
          if (['sin', 'eng', 'sin+eng'].contains(raw['language'])) {
            language = raw['language'] as String;
          }
          for (final entry in stored.entries) {
            final page = int.tryParse(entry.key.toString());
            if (page != null && page > 0 && entry.value is String) {
              pages[page] = entry.value as String;
            }
          }
        }
      }
    } catch (_) {
      /* OCR can proceed without a cache. */
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> recognize(bool all) async {
    if (recognizing) return;
    recognizing = true;
    try {
      await runPdfTask<void>(context, 'Read scanned PDF', (progress) async {
        progress.onCancel = () =>
            unawaited(OfflineSinhalaOcr.cancel().catchError((Object _) {}));
        await pdfrx.pdfrxFlutterInitialize();
        final pdf = await pdfrx.PdfDocument.openFile(widget.path);
        try {
          final selected = all
              ? List.generate(pdf.pages.length, (i) => i + 1)
              : [widget.page];
          Uint8List? source;
          for (var i = 0; i < selected.length; i++) {
            if (!mounted) throw const TaskCancelled();
            final number = selected[i];
            await progress.step(
              'Reading page $number of ${pdf.pages.length}',
              done: i,
              total: selected.length,
            );
            if (number < 1 || number > pdf.pages.length) continue;
            if (all && pages.containsKey(number)) continue;
            var text =
                (await pdf.pages[number - 1].loadText())?.fullText.trim() ?? '';
            if (text.isEmpty) {
              source ??= await File(widget.path).readAsBytes();
              text = (await OfflineSinhalaOcr.recognize(
                source,
                number,
                language: language,
              )).text.trim();
            }
            progress.check();
            if (!mounted) throw const TaskCancelled();
            if (pages.values.fold<int>(text.length, (n, t) => n + t.length) >
                8 * 1024 * 1024) {
              throw const FormatException(
                'Recognized text limit reached. Read smaller sections.',
              );
            }
            pages[number] = text;
            if (mounted) setState(() {});
            if (cache != null) {
              await cache!.parent.create(recursive: true);
              final tmp = File('${cache!.path}.tmp');
              await tmp.writeAsString(
                jsonEncode({
                  'language': language,
                  'pages': pages.map((k, v) => MapEntry('$k', v)),
                }),
                flush: true,
              );
              await tmp.rename(cache!.path);
            }
          }
        } finally {
          await pdf.dispose();
        }
      });
      if (mounted) setState(() => failure = null);
    } on TaskCancelled {
      if (mounted) {
        setState(
          () => failure =
              'Stopped. Completed pages are kept; scan again to continue.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => failure = 'Could not recognize text: $error');
    } finally {
      recognizing = false;
    }
  }

  @override
  void dispose() {
    if (recognizing) {
      unawaited(OfflineSinhalaOcr.cancel().catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keys =
        pages.keys
            .where(
              (k) =>
                  query.isEmpty ||
                  pages[k]!.toLowerCase().contains(query.toLowerCase()),
            )
            .toList()
          ..sort();
    return Scaffold(
      appBar: AppBar(
        title: const LocalizedText('Scanned PDF text'),
        actions: [
          IconButton(
            tooltip: tr('Copy recognized text'),
            onPressed: pages.isEmpty
                ? null
                : () async {
                    final text = (pages.keys.toList()..sort())
                        .map((p) => 'Page $p\n${pages[p]}')
                        .join('\n\n');
                    try {
                      if (text.length > 200000) {
                        throw const FormatException(
                          'Select and copy one page at a time for large documents.',
                        );
                      }
                      await Clipboard.setData(ClipboardData(text: text));
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Could not copy: $error')),
                        );
                      }
                    }
                  },
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      const Text(
                        'Offline recognition. Review uncertain words against the original page. The PDF stays unchanged.',
                      ),
                      DropdownButton<String>(
                        value: language,
                        items: const [
                          DropdownMenuItem(
                            value: 'sin+eng',
                            child: Text('Sinhala + English'),
                          ),
                          DropdownMenuItem(
                            value: 'sin',
                            child: Text('Sinhala'),
                          ),
                          DropdownMenuItem(
                            value: 'eng',
                            child: Text('English'),
                          ),
                        ],
                        onChanged: (v) async {
                          if (v == null || v == language) return;
                          setState(() {
                            language = v;
                            pages.clear();
                          });
                          try {
                            if (await cache?.exists() == true) {
                              await cache!.delete();
                            }
                          } on FileSystemException {
                            /* Cache is optional. */
                          }
                        },
                      ),
                      Wrap(
                        spacing: 12,
                        children: [
                          FilledButton(
                            onPressed: () => recognize(false),
                            child: Text('Read page ${widget.page}'),
                          ),
                          OutlinedButton(
                            onPressed: () => recognize(true),
                            child: const LocalizedText('Read all pages'),
                          ),
                        ],
                      ),
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'Find in recognized text',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (v) => setState(() => query = v),
                      ),
                      if (failure != null) Text(failure!),
                    ],
                  ),
                ),
                Expanded(
                  child: keys.isEmpty
                      ? const Center(
                          child: Text(
                            'No recognized text yet. Choose a page or scan the document.',
                          ),
                        )
                      : ListView.builder(
                          itemCount: keys.length,
                          itemBuilder: (context, i) {
                            final p = keys[i];
                            return Card(
                              margin: const EdgeInsets.all(12),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextButton(
                                      onPressed: () {
                                        Navigator.pop(context);
                                        widget.onPage(p);
                                      },
                                      child: Text('Open original page $p'),
                                    ),
                                    SelectableText.rich(
                                      _highlight(
                                        pages[p]!.isEmpty
                                            ? 'No text recognized on this page.'
                                            : pages[p]!,
                                        query,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }

  TextSpan _highlight(String text, String needle) {
    if (needle.isEmpty) return TextSpan(text: text);
    final lower = text.toLowerCase(),
        q = needle.toLowerCase(),
        spans = <TextSpan>[];
    var start = 0, hit = lower.indexOf(q);
    while (hit >= 0) {
      spans.add(TextSpan(text: text.substring(start, hit)));
      spans.add(
        TextSpan(
          text: text.substring(hit, hit + q.length),
          style: const TextStyle(
            backgroundColor: Color(0xFFFFE082),
            color: Colors.black,
          ),
        ),
      );
      start = hit + q.length;
      hit = lower.indexOf(q, start);
    }
    spans.add(TextSpan(text: text.substring(start)));
    return TextSpan(children: spans);
  }
}
