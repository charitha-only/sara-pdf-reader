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
  bool loading = false, busy = false;
  String? readError;
  String savedName = '';
  @override
  void initState() {
    super.initState();
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
        throw const FormatException('Edit text files up to 8 MB.');
      }
      content.text = await file.readAsString();
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
