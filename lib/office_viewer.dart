import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:offline_document_viewer/offline_document_viewer.dart';

import 'app_language.dart';
import 'file_mime.dart';

class OfficeViewer extends StatefulWidget {
  const OfficeViewer({super.key, required this.path, required this.name});
  final String path, name;
  @override
  State<OfficeViewer> createState() => _OfficeViewerState();
}

class _OfficeViewerState extends State<OfficeViewer> {
  final controller = DocumentViewController();
  int generation = 0;
  Future<void> share() async {
    try {
      await const MethodChannel('pageflow_reader/share')
          .invokeMethod<void>('sharePdf', {
            'path': widget.path,
            'name': widget.name,
            'mimeType': fileMime(widget.path),
          });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share this file: $error')),
        );
      }
    }
  }

  Future<void> search() async {
    final input = TextEditingController();
    final query = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LocalizedText('Find in document'),
        content: TextField(
          controller: input,
          autofocus: true,
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const LocalizedText('Clear'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const LocalizedText('Find'),
          ),
        ],
      ),
    );
    input.dispose();
    if (query != null) await controller.search(query);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  String failureText(DocumentFailure failure) => switch (failure) {
    EncryptedDocumentFailure() =>
      'This Office file is password protected. Open an unlocked copy.',
    TooLargeFailure() => 'This Office file exceeds the 80 MB preview limit.',
    UnsupportedFormatFailure() => 'This file format is not supported.',
    _ => 'Could not preview this document. It may be damaged or use unsupported content.',
  };
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: tr('Find in document'),
          onPressed: search,
          icon: const Icon(Icons.search),
        ),
        IconButton(
          tooltip: tr('Share original file'),
          onPressed: share,
          icon: const Icon(Icons.ios_share),
        ),
      ],
    ),
    body: Column(
      children: [
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final info = controller.info;
            if (info == null) return const SizedBox.shrink();
            final warning = info.format.fidelity == FidelityLevel.textOnly
                ? (info.format == DocumentFormat.doc
                      ? 'Legacy Word preview preserves text and tables; page breaks and floating objects may differ.'
                      : 'Text preview only. Original layout is not available for this legacy format.')
                : info.format.fidelity == FidelityLevel.partial
                ? 'Some original formatting may not appear in this format.'
                : info.truncated
                ? 'Preview limits reached. Some rows or columns are not shown.'
                : null;
            return Column(
              children: [
                if (warning != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(warning),
                  ),
                if (info.outline.isNotEmpty &&
                    info.format.family != FormatFamily.excel)
                  SizedBox(
                    height: 44,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: info.outline.length,
                      itemBuilder: (context, index) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: TextButton(
                          onPressed: () => controller.goTo(index),
                          child: Text(info.outline[index]),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        Expanded(
          child: DocumentView(
            key: ValueKey('${widget.path}:$generation'),
            source: DocumentSource.file(widget.path),
            controller: controller,
            placeholderBuilder: (_) => const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  LocalizedText('Preparing preview…'),
                ],
              ),
            ),
            errorBuilder: (_, failure) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(failureText(failure), textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => setState(() => generation++),
                      child: const LocalizedText('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
