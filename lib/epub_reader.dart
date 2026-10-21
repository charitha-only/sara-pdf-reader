import 'image_viewer.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_language.dart';
import 'epub_document.dart';
import 'reading_state.dart';
import 'reader_display.dart';

class EpubReader extends StatefulWidget {
  const EpubReader({super.key, required this.path, required this.name});
  final String path, name;
  @override
  State<EpubReader> createState() => _EpubReaderState();
}

class _EpubReaderState extends State<EpubReader> {
  final scroll = ScrollController();
  late Future<EpubDocument> book;
  int chapter = 0;
  double size = 19, spacing = 1.65, savedFraction = 0;
  String palette = 'paper';
  bool ready = false;
  Timer? saveTimer;
  @override
  void initState() {
    super.initState();
    book = load();
    scroll.addListener(changed);
  }

  Future<EpubDocument> load() async {
    final saved = await ReadingStateStore.load(widget.path);
    final prefs = await AppPreferences.read();
    final value = await compute(
      EpubDocument.read,
      await File(widget.path).readAsBytes(),
    );
    if (!mounted) return value;
    chapter = ((saved['unit'] as num?)?.toInt() ?? 0).clamp(
      0,
      value.chapters.length - 1,
    );
    savedFraction = (saved['scroll'] as num?)?.toDouble() ?? 0;
    size = ((prefs['epubFont'] as num?)?.toDouble() ?? 19).clamp(12, 36);
    spacing = ((prefs['epubSpacing'] as num?)?.toDouble() ?? 1.65).clamp(
      1.1,
      2.2,
    );
    palette = ['paper', 'sepia', 'night'].contains(prefs['epubPalette'])
        ? prefs['epubPalette'] as String
        : 'paper';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (scroll.hasClients) {
        scroll.jumpTo(savedFraction * scroll.position.maxScrollExtent);
      }
      ready = true;
    });
    return value;
  }

  void changed() {
    if (!ready) return;
    saveTimer?.cancel();
    saveTimer = Timer(const Duration(milliseconds: 400), save);
  }

  void save() {
    if (!ready) return;
    unawaited(
      ReadingStateStore.save(widget.path, {
        'unit': chapter,
        'scroll': scroll.hasClients && scroll.position.maxScrollExtent > 0
            ? scroll.offset / scroll.position.maxScrollExtent
            : 0,
      }).catchError((Object _) {}),
    );
  }

  void go(int value) {
    save();
    setState(() => chapter = value);
    if (scroll.hasClients) scroll.jumpTo(0);
    save();
  }

  Future<void> chapters(EpubDocument doc) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const LocalizedText('Book contents'),
        content: SizedBox(
          width: 420,
          height: 400,
          child: ListView.builder(
            itemCount: doc.chapters.length,
            itemBuilder: (_, i) => ListTile(
              selected: i == chapter,
              title: Text(doc.chapters[i].title),
              leading: Text('${i + 1}'),
              onTap: () => Navigator.pop(c, i),
            ),
          ),
        ),
      ),
    );
    if (mounted && selected != null) go(selected);
  }

  Future<void> appearance() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, refresh) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LocalizedText('Book appearance'),
                Row(
                  children: [
                    const Text('Text size'),
                    Expanded(
                      child: Slider(
                        min: 12,
                        max: 36,
                        divisions: 24,
                        value: size,
                        label: size.round().toString(),
                        onChanged: (v) {
                          setState(() => size = v);
                          refresh(() {});
                        },
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const LocalizedText('Line spacing'),
                    Expanded(
                      child: Slider(
                        min: 1.1,
                        max: 2.2,
                        divisions: 11,
                        value: spacing,
                        onChanged: (v) {
                          setState(() => spacing = v);
                          refresh(() {});
                        },
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final p in ['paper', 'sepia', 'night'])
                      ChoiceChip(
                        label: Text(p),
                        selected: palette == p,
                        onSelected: (_) {
                          setState(() => palette = p);
                          refresh(() {});
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await AppPreferences.write({
      'epubFont': size,
      'epubSpacing': spacing,
      'epubPalette': palette,
    });
  }

  Future<void> find(EpubDocument doc) async {
    var query = '';
    final value = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const LocalizedText('Find in book'),
        content: TextField(
          autofocus: true,
          onChanged: (v) => query = v,
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, query),
            child: const Text('Find'),
          ),
        ],
      ),
    );
    if (!mounted || value == null || value.trim().isEmpty) return;
    final q = value.trim().toLowerCase();
    final hits = [
      for (var i = 0; i < doc.chapters.length; i++)
        if (doc.chapters[i].blocks.any((b) => b.text.toLowerCase().contains(q)))
          i,
    ];
    final target = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${hits.length} matching chapters'),
        content: SizedBox(
          width: 420,
          height: 320,
          child: ListView.builder(
            itemCount: hits.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(doc.chapters[hits[i]].title),
              onTap: () => Navigator.pop(c, hits[i]),
            ),
          ),
        ),
      ),
    );
    if (mounted && target != null) go(target);
  }

  @override
  void dispose() {
    saveTimer?.cancel();
    save();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<EpubDocument>(
    future: book,
    builder: (context, snapshot) {
      final doc = snapshot.data;
      final dark = palette == 'night';
      final fg = dark ? const Color(0xFFEAE6D9) : const Color(0xFF252321);
      return Scaffold(
        backgroundColor: dark
            ? const Color(0xFF15191D)
            : palette == 'sepia'
            ? const Color(0xFFF5ECD8)
            : Colors.white,
        appBar: AppBar(
          backgroundColor: dark ? const Color(0xFF15191D) : null,
          foregroundColor: dark ? fg : null,
          title: Text(
            widget.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (doc != null)
              IconButton(
                tooltip: tr('Book contents'),
                onPressed: () => chapters(doc),
                icon: const Icon(Icons.toc),
              ),
            if (doc != null)
              IconButton(
                tooltip: tr('Find in book'),
                onPressed: () => find(doc),
                icon: const Icon(Icons.search),
              ),
            IconButton(
              tooltip: tr('Book appearance'),
              onPressed: appearance,
              icon: const Icon(Icons.text_fields),
            ),
            const ReaderOptionsButton(),
          ],
        ),
        body: snapshot.hasError
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Could not read EPUB: ${snapshot.error}'),
                      TextButton(
                        onPressed: () => setState(() => book = load()),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              )
            : doc == null
            ? const Center(child: CircularProgressIndicator())
            : ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                itemCount: doc.chapters[chapter].blocks.length,
                itemBuilder: (context, i) {
                  final block = doc.chapters[chapter].blocks[i];
                  if (block.image != null) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Image(
                        image: BoundedMemoryImage(block.image!),
                        errorBuilder: (_, _, _) =>
                            const Text('Image unavailable'),
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: SelectableText.rich(
                      TextSpan(
                        style: TextStyle(
                          fontFamily: 'Pageflow UI',
                          color: fg,
                          fontSize: size * (block.heading > 0 ? 1.35 : 1),
                          height: spacing,
                        ),
                        children: [
                          for (final run in block.runs)
                            TextSpan(
                              text: run.text,
                              style: TextStyle(
                                fontWeight: run.bold
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                fontStyle: run.italic
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
        bottomNavigationBar: doc == null
            ? null
            : SafeArea(
                child: Row(
                  children: [
                    IconButton(
                      tooltip: tr('Previous chapter'),
                      color: fg,
                      onPressed: chapter > 0 ? () => go(chapter - 1) : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: TextButton(
                        style: TextButton.styleFrom(foregroundColor: fg),
                        onPressed: () => chapters(doc),
                        child: Text(
                          '${chapter + 1}/${doc.chapters.length} · ${doc.chapters[chapter].title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: tr('Next chapter'),
                      color: fg,
                      onPressed: chapter + 1 < doc.chapters.length
                          ? () => go(chapter + 1)
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
      );
    },
  );
}
