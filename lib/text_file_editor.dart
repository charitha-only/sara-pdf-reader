import 'dart:async';

import 'reading_state.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

class TextFileEditor extends StatefulWidget {
  const TextFileEditor({
    super.key,
    required this.directory,
    this.path,
    this.displayName,
    this.readOnly = false,
  });
  final bool readOnly;
  final Directory directory;
  final String? path;
  final String? displayName;
  @override
  State<TextFileEditor> createState() => _TextFileEditorState();
}

class _TextFileEditorState extends State<TextFileEditor> {
  final name = TextEditingController(text: 'Untitled.txt'),
      content = TextEditingController();
  final scroll = ScrollController();
  final textFocus = FocusNode();
  Timer? saveTimer;
  final matches = <int>[];
  String query = '';
  int matchIndex = -1;
  bool loading = false, busy = false;
  String? readError;
  String savedName = '';
  @override
  void initState() {
    super.initState();
    scroll.addListener(() {
      saveTimer?.cancel();
      saveTimer = Timer(const Duration(milliseconds: 400), savePosition);
    });
    if (widget.path != null) {
      loading = true;
      name.text =
          widget.displayName ?? File(widget.path!).uri.pathSegments.last;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final file = File(widget.path!);
      if (await file.length() > 8 * 1024 * 1024) {
        throw const FormatException('Read text files up to 8 MB.');
      }
      final text = await file.readAsString();
      final saved = await ReadingStateStore.load(file.path);
      if (!mounted) return;
      content.text = text;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.jumpTo(
            ((saved['scroll'] as num?)?.toDouble() ?? 0).clamp(0, 1) *
                scroll.position.maxScrollExtent,
          );
        }
      });
    } catch (error) {
      readError = '$error';
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not read text: $error')));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void savePosition() {
    if (widget.path == null || !scroll.hasClients || loading) return;
    final maximum = scroll.position.maxScrollExtent;
    unawaited(
      ReadingStateStore.save(widget.path!, {
        'scroll': maximum > 0 ? scroll.offset / maximum : 0,
      }).catchError((Object _) {}),
    );
  }

  Future<void> searchText() async {
    final input = TextEditingController(text: query);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Find in text'),
        content: TextField(
          controller: input,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, ''),
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input.text),
            child: const Text('Find'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), input.dispose);
    if (!mounted || value == null) return;
    matches.clear();
    query = value.trim();
    matchIndex = -1;
    final lower = content.text.toLowerCase(), needle = query.toLowerCase();
    if (needle.isNotEmpty) {
      var offset = 0;
      while (matches.length < 2000) {
        final found = lower.indexOf(needle, offset);
        if (found < 0) break;
        matches.add(found);
        offset = found + needle.length;
      }
    }
    setState(() {});
    if (matches.isNotEmpty) moveMatch(1);
  }

  void moveMatch(int direction) {
    if (matches.isEmpty) return;
    setState(() => matchIndex = (matchIndex + direction) % matches.length);
    final offset = matches[matchIndex];
    content.selection = TextSelection(
      baseOffset: offset,
      extentOffset: offset + query.length,
    );
    textFocus.requestFocus();
  }

  Future<File> _write() async {
    var filename = name.text.trim();
    if (filename.isEmpty ||
        filename.length > 120 ||
        RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(filename) ||
        filename == '.' ||
        filename == '..') {
      throw const FormatException('Enter a valid file name without folders.');
    }
    if (!filename.toLowerCase().endsWith('.txt') &&
        !filename.toLowerCase().endsWith('.plain')) {
      filename = '$filename.txt';
    }
    savedName = filename;
    final bytes = utf8.encode(content.text);
    if (bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('Text files can contain up to 8 MB.');
    }
    await widget.directory.create(recursive: true);
    final file = File(
      widget.path ??
          '${widget.directory.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}-$filename',
    );
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
    return file;
  }

  Future<void> _save() async {
    if (busy || readError != null) return;
    setState(() => busy = true);
    try {
      final file = await _write();
      if (mounted) {
        Navigator.pop(context, (path: file.path, name: savedName));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save text: $error')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _export() async {
    try {
      await FilePicker.saveFile(
        fileName: name.text.toLowerCase().endsWith('.txt')
            ? name.text
            : '${name.text}.txt',
        bytes: Uint8List.fromList(utf8.encode(content.text)),
        mimeType: 'text/plain',
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export text: $error')),
        );
      }
    }
  }

  @override
  void dispose() {
    saveTimer?.cancel();
    savePosition();
    scroll.dispose();
    textFocus.dispose();
    name.dispose();
    content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.readOnly
            ? (widget.displayName ?? 'Text file')
            : widget.path == null
            ? 'New text file'
            : 'Edit text file',
      ),
      actions: [
        IconButton(
          tooltip: 'Find in text',
          onPressed: loading || readError != null ? null : searchText,
          icon: const Icon(Icons.search),
        ),
        IconButton(
          tooltip: 'Export TXT',
          onPressed: busy || loading || readError != null ? null : _export,
          icon: const Icon(Icons.ios_share),
        ),
        if (!widget.readOnly)
          TextButton(
            onPressed: busy || loading || readError != null ? null : _save,
            child: const Text('Save'),
          ),
      ],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              if (query.isNotEmpty)
                Row(
                  children: [
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '${matchIndex + 1}/${matches.length} — $query',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Previous result',
                      onPressed: matches.isEmpty ? null : () => moveMatch(-1),
                      icon: const Icon(Icons.keyboard_arrow_up),
                    ),
                    IconButton(
                      tooltip: 'Next result',
                      onPressed: matches.isEmpty ? null : () => moveMatch(1),
                      icon: const Icon(Icons.keyboard_arrow_down),
                    ),
                  ],
                ),
              if (readError != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Text('Could not read this text file: $readError'),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            loading = true;
                            readError = null;
                          });
                          _load();
                        },
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              if (!widget.readOnly)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: name,
                    enabled: widget.path == null,
                    decoration: const InputDecoration(
                      labelText: 'File name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: TextField(
                    controller: content,
                    scrollController: scroll,
                    focusNode: textFocus,
                    readOnly: widget.readOnly,
                    showCursor: !widget.readOnly,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText: '',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ),
            ],
          ),
  );
}
