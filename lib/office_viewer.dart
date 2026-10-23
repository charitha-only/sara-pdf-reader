import 'reader_display.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:offline_document_viewer/offline_document_viewer.dart';

import 'app_language.dart';
import 'file_mime.dart';
import 'reading_state.dart';

class OfficeViewer extends StatefulWidget {
  const OfficeViewer({super.key, required this.path, required this.name});
  final String path, name;
  @override
  State<OfficeViewer> createState() => _OfficeViewerState();
}

class _OfficeViewerState extends State<OfficeViewer> {
  final controller = DocumentViewController();
  late Future<Map<String, dynamic>> savedState;
  late final DocumentSource source;
  Timer? saveTimer;
  int generation = 0;
  bool cancelled = false, restored = false;
  String mode = 'actual', query = '';
  @override
  void initState() {
    super.initState();
    source = DocumentSource.file(widget.path);
    savedState = ReadingStateStore.load(widget.path);
    controller.addListener(positionChanged);
  }

  Map<String, dynamic> snapshot() => {
    'unit': controller.position,
    'scroll': controller.scrollFraction,
    'horizontal': controller.horizontalOffset,
    'mode': mode,
  };
  void save() {
    if (restored) {
      unawaited(
        ReadingStateStore.save(
          widget.path,
          snapshot(),
        ).catchError((Object _) {}),
      );
    }
  }

  void positionChanged() {
    if (!restored || controller.status != DocumentViewStatus.ready) return;
    saveTimer?.cancel();
    saveTimer = Timer(const Duration(milliseconds: 400), save);
  }

  Future<void> restore(DocumentInfo info) async {
    final saved = await savedState;
    if (!mounted || restored) return;
    const modes = {'width', 'actual', '0.5', '0.75', '1.25', '1.5', '2', '3'};
    mode = modes.contains(saved['mode']) ? saved['mode'] as String : 'actual';
    await controller.setViewMode(mode);
    final unit = ((saved['unit'] as num?)?.toInt() ?? 0).clamp(
      0,
      info.unitCount > 0 ? info.unitCount - 1 : 0,
    );
    if (unit > 0) await controller.goTo(unit);
    await controller.restoreScroll(
      (saved['scroll'] as num?)?.toDouble() ?? 0,
      (saved['horizontal'] as num?)?.toDouble() ?? 0,
    );
    if (mounted) setState(() => restored = true);
  }

  Future<void> printOffice() async {
    try {
      if (controller.status != DocumentViewStatus.ready) return;
      await controller.printDocument();
    } catch (error) {
      message('Could not print: $error');
    }
  }

  Future<void> share() async {
    try {
      await const MethodChannel('pageflow_reader/share')
          .invokeMethod<void>('sharePdf', {
            'path': widget.path,
            'name': widget.name,
            'mimeType': fileMime(widget.path),
          });
    } catch (error) {
      message('Could not share this file: $error');
    }
  }

  void message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> search() async {
    final input = TextEditingController(text: query);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const LocalizedText('Find in document'),
        content: TextField(
          controller: input,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Sinhala or English text',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, ''),
            child: const LocalizedText('Clear'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input.text.trim()),
            child: const LocalizedText('Find'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), input.dispose);
    if (!mounted || value == null) return;
    setState(() => query = value);
    try {
      await controller.search(value);
    } catch (error) {
      message('Could not search: $error');
    }
  }

  void retry() {
    save();
    savedState = ReadingStateStore.load(widget.path);
    setState(() {
      cancelled = false;
      restored = false;
      generation++;
    });
  }

  @override
  void dispose() {
    saveTimer?.cancel();
    save();
    controller.removeListener(positionChanged);
    controller.dispose();
    super.dispose();
  }

  String failureText(DocumentFailure failure) => switch (failure) {
    EncryptedDocumentFailure() =>
      'This Office file is password protected. Open an unlocked copy.',
    TooLargeFailure() => 'This document exceeds the supported preview size.',
    UnsupportedFormatFailure() => 'This file format is not supported.',
    RendererFailure(timedOut: true) =>
      'Preview took too long. Retry, or try a smaller document.',
    _ => 'Could not preview this document. It may be damaged or use unsupported content.',
  };
  Widget errorPanel(String error) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(error, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          TextButton(onPressed: retry, child: const LocalizedText('Retry')),
        ],
      ),
    ),
  );
  Future<void> chooseScale(String value) async {
    setState(() => mode = value);
    try {
      await controller.setViewMode(value);
      save();
    } catch (error) {
      message('Could not change zoom: $error');
    }
  }

  void zoomStep(int step) {
    const levels = ['0.5', '0.75', 'actual', '1.25', '1.5', '2', '3'];
    final index = levels.indexOf(mode);
    chooseScale(
      levels[((index < 0 ? 2 : index) + step).clamp(0, levels.length - 1)],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: false,
    appBar: AppBar(
      title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        const ReaderOptionsButton(),
        IconButton(
          tooltip: 'Print current sheet/document',
          icon: const Icon(Icons.print),
          onPressed: () => printOffice(),
        ),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => IconButton(
            tooltip: tr('Find in document'),
            onPressed: controller.status == DocumentViewStatus.ready
                ? search
                : null,
            icon: const Icon(Icons.search),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Page fit',
          initialValue: mode,
          onSelected: (value) async {
            setState(() => mode = value);
            await controller.setViewMode(value);
            save();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'width', child: Text('Fit width')),
            PopupMenuItem(value: 'actual', child: Text('Original size (100%)')),
            PopupMenuItem(value: '0.5', child: Text('50%')),
            PopupMenuItem(value: '0.75', child: Text('75%')),
            PopupMenuItem(value: '1.25', child: Text('125%')),
            PopupMenuItem(value: '1.5', child: Text('150%')),
            PopupMenuItem(value: '2', child: Text('200%')),
            PopupMenuItem(value: '3', child: Text('300%')),
          ],
          icon: const Icon(Icons.fit_screen),
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
            final ready = controller.status == DocumentViewStatus.ready;
            return Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Zoom out',
                  onPressed: ready ? () => zoomStep(-1) : null,
                  icon: const Icon(Icons.zoom_out),
                ),
                Text(
                  mode == 'width'
                      ? 'Fit width'
                      : mode == 'actual'
                      ? '100%'
                      : '${((double.tryParse(mode) ?? 1) * 100).round()}%',
                ),
                IconButton(
                  tooltip: 'Zoom in',
                  onPressed: ready ? () => zoomStep(1) : null,
                  icon: const Icon(Icons.zoom_in),
                ),
                TextButton(
                  onPressed: ready ? () => chooseScale('width') : null,
                  child: const Text('Fit width'),
                ),
                TextButton(
                  onPressed: ready ? () => chooseScale('actual') : null,
                  child: const Text('100%'),
                ),
              ],
            );
          },
        ),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final info = controller.info;
            if (info == null) return const SizedBox.shrink();
            final warnings = <String>[
              if (info.format.fidelity == FidelityLevel.textOnly)
                info.format == DocumentFormat.doc
                    ? 'Legacy Word: text and tables are shown; floating objects and page breaks may differ.'
                    : 'Legacy text preview: original layout is unavailable.',
              if (info.format.fidelity == FidelityLevel.partial)
                'Some original formatting may differ.',
              if (info.truncated)
                'Preview limit reached: some rows or columns are not shown.',
            ];
            return Column(
              children: [
                for (final warning in warnings)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(warning),
                  ),
                if (query.isNotEmpty)
                  Row(
                    children: [
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${controller.searchIndex < 0 ? 0 : controller.searchIndex + 1}/${controller.searchHits} — $query',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Previous result',
                        onPressed: controller.searchHits > 0
                            ? () => controller.moveSearch(-1)
                            : null,
                        icon: const Icon(Icons.keyboard_arrow_up),
                      ),
                      IconButton(
                        tooltip: 'Next result',
                        onPressed: controller.searchHits > 0
                            ? () => controller.moveSearch(1)
                            : null,
                        icon: const Icon(Icons.keyboard_arrow_down),
                      ),
                      IconButton(
                        tooltip: 'Clear search',
                        onPressed: () {
                          setState(() => query = '');
                          controller.search('');
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                if (info.outline.isNotEmpty &&
                    info.format.family != FormatFamily.excel)
                  SizedBox(
                    height: 44,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: info.outline.length,
                      itemBuilder: (context, index) => TextButton(
                        onPressed: () => controller.goTo(index),
                        child: Text(info.outline[index]),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        Expanded(
          child: cancelled
              ? errorPanel('Preview cancelled.')
              : DocumentView(
                  key: ValueKey('${widget.path}:$generation'),
                  source: source,
                  controller: controller,
                  renderTimeout: const Duration(seconds: 60),
                  onReady: (info) => unawaited(restore(info)),
                  placeholderBuilder: (_) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        ListenableBuilder(
                          listenable: controller,
                          builder: (_, _) => Text(
                            controller.status == DocumentViewStatus.preparing
                                ? 'Checking and preparing document…'
                                : 'Rendering document…',
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() => cancelled = true),
                          child: const LocalizedText('Cancel'),
                        ),
                      ],
                    ),
                  ),
                  errorBuilder: (_, failure) =>
                      errorPanel(failureText(failure)),
                ),
        ),
      ],
    ),
  );
}
