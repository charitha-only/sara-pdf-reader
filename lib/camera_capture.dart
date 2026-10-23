import 'dart:typed_data' show BytesBuilder;

import 'sinhala_ocr.dart';

import 'dart:async';

import 'scan_draft.dart';
import 'scan_corners.dart';
import 'scan_geometry.dart';
import 'scan_searchable.dart';
import 'task_progress.dart';
import 'scan_crop.dart';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

Future<Uint8List> convertCapture(Map<String, dynamic> args) async {
  final bytes = args['bytes'] as Uint8List;
  if (bytes.length > 40 * 1024 * 1024) throw StateError('Photo exceeds 40 MB.');
  if (bytes.length < 16) throw StateError('This photo could not be decoded.');
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width * info.height > 40000000) {
    throw StateError('Use a photo below 40 megapixels.');
  }
  var image = decoder!.decode(bytes);
  if (image == null) throw StateError('This photo could not be decoded.');
  image = img.bakeOrientation(image);
  if (image.width > 2400 || image.height > 2400) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? 2400 : null,
      height: image.height > image.width ? 2400 : null,
    );
  }
  final crop = args['crop'] as List<double>?;
  if (crop != null) {
    final left = (crop[0] * image.width).round().clamp(0, image.width - 1);
    final top = (crop[1] * image.height).round().clamp(0, image.height - 1);
    final right = (crop[2] * image.width).round().clamp(left + 1, image.width);
    final bottom = (crop[3] * image.height).round().clamp(
      top + 1,
      image.height,
    );
    image = img.copyCrop(
      image,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
  }
  if (args['turns'] != 0) {
    image = img.copyRotate(image, angle: (args['turns'] as int) * 90);
  }
  if (args['scan'] == true) {
    image = img.adjustColor(img.grayscale(image), contrast: 1.25);
  }
  final format = args['format'] as String;
  if (format == 'png') return Uint8List.fromList(img.encodePng(image));
  final jpeg = Uint8List.fromList(img.encodeJpg(image, quality: 92));
  if (format == 'jpeg') return jpeg;
  final pdf = pw.Document();
  pdf.addPage(
    pw.Page(
      pageFormat: image.width > image.height
          ? PdfPageFormat.a4.landscape
          : PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(18),
      build: (_) => pw.Center(
        child: pw.Image(pw.MemoryImage(jpeg), fit: pw.BoxFit.contain),
      ),
    ),
  );
  return pdf.save();
}

Future<Uint8List> scanPagesPdf(List<Uint8List> pages) async {
  if (pages.isEmpty || pages.length > 20) {
    throw StateError('Choose 1–20 scan pages.');
  }
  if (pages.fold<int>(0, (sum, bytes) => sum + bytes.length) >
      60 * 1024 * 1024) {
    throw StateError('Scan exceeds 60 MB.');
  }
  final document = pw.Document();
  for (final bytes in pages) {
    final info = img.JpegDecoder().startDecode(bytes);
    if (info == null) throw StateError('Invalid scan page.');
    document.addPage(
      pw.Page(
        pageFormat: info.width > info.height
            ? PdfPageFormat.a4.landscape
            : PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(18),
        build: (_) => pw.Center(
          child: pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain),
        ),
      ),
    );
  }
  return document.save();
}

class _ScanPage {
  _ScanPage(this.original, this.preview);
  Uint8List original, preview;
  int turns = 0;
  bool scan = false;
}

class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({
    super.key,
    this.autoCapture = true,
    this.galleryOnOpen = false,
    this.store,
  });
  final bool autoCapture, galleryOnOpen;
  final ScanDraftStore? store;
  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends State<CameraCapturePage> {
  static const channel = MethodChannel('pageflow_reader/incoming');
  final pages = <_ScanPage>[];
  int selected = 0;
  _ScanPage? get current => pages.isEmpty ? null : pages[selected];
  Uint8List? get original => current?.original;
  Uint8List? get preview => current?.preview;
  bool get scan => current?.scan ?? false;
  set scan(bool value) {
    current?.scan = value;
  }

  int get turns => current?.turns ?? 0;
  set turns(int value) {
    current?.turns = value;
  }

  String format = 'pdf', status = '';
  bool busy = false,
      draftFault = false,
      draftSaved = false,
      draftSaving = false,
      searchable = false,
      ocrActive = false;
  String ocrLanguage = 'sin+eng';
  ScanDraftStore? draftStore;
  int saveRevision = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => startSession());
  }

  Future<void> startSession() async {
    setState(() => busy = true);
    try {
      if (widget.store != null) {
        draftStore = widget.store;
      } else {
        final root = await getApplicationSupportDirectory();
        draftStore = ScanDraftStore(Directory('${root.path}/scan-draft-v1'));
      }
      final restored = await draftStore!.load();
      if (!mounted) return;
      if (restored != null) {
        for (final record in restored['pages'] as List) {
          final page = _ScanPage(
            record['original'] as Uint8List,
            record['preview'] as Uint8List,
          );
          page.turns = record['turns'] as int;
          page.scan = record['scan'] as bool;
          pages.add(page);
        }
        selected = (restored['selected'] as int).clamp(
          0,
          pages.isEmpty ? 0 : pages.length - 1,
        );
        draftSaved = true;
        if (pages.isNotEmpty) status = 'Restored your saved scan draft.';
      } else if (await File('${draftStore!.root.path}/draft.json').exists() ||
          await File('${draftStore!.root.path}/draft.json.bak').exists()) {
        draftFault = true;
        status = 'The saved draft could not be restored. Use New scan to start again.';
      }
    } catch (_) {
      draftStore = null;
      status = 'Automatic draft storage is unavailable. Export a copy before leaving.';
    }
    if (!mounted) return;
    setState(() => busy = false);
    if (widget.galleryOnOpen && !draftFault) {
      await importGallery();
    } else if (widget.autoCapture && pages.isEmpty && !draftFault) {
      await capture();
    }
  }

  List<Map<String, dynamic>> draftSnapshot() => [
    for (final page in pages)
      {
        'original': page.original,
        'preview': page.preview,
        'turns': page.turns,
        'scan': page.scan,
      },
  ];
  Future<void> saveDraft() async {
    if (draftStore == null || draftFault) return;
    final revision = ++saveRevision;
    if (mounted) {
      setState(() {
        draftSaving = true;
        draftSaved = false;
      });
    }
    try {
      await draftStore!.save(draftSnapshot(), selected);
      if (mounted && revision == saveRevision) {
        setState(() {
          draftSaving = false;
          draftSaved = true;
        });
      }
    } catch (_) {
      if (mounted && revision == saveRevision) {
        setState(() {
          draftSaving = false;
          draftSaved = false;
          status = 'Draft could not be saved. Export a copy before leaving.';
        });
      }
    }
  }

  void change(VoidCallback mutation) {
    setState(mutation);
    unawaited(saveDraft());
  }

  bool appendPhoto(Uint8List bytes) {
    final total = pages.fold<int>(
      0,
      (sum, p) => sum + p.original.length + p.preview.length,
    );
    if (pages.length >= 20 || total + bytes.length * 2 > 60 * 1024 * 1024) {
      status = 'Scan limit reached. Save this scan before adding more pages.';
      return false;
    }
    pages.add(_ScanPage(bytes, bytes));
    selected = pages.length - 1;
    return true;
  }

  Future<void> importGallery() async {
    if (busy || draftFault) return;
    setState(() => busy = true);
    try {
      final selection = await FilePicker.pickFiles(type: FileType.image);
      if (selection.isEmpty || !mounted) return;
      if (selection.length > 20 - pages.length) {
        throw StateError('Choose at most ${20 - pages.length} more photos.');
      }
      var imported = 0, skipped = 0;
      for (final file in selection) {
        if (!mounted) return;
        try {
          final length = await file.length();
          if (length != null && length > 40 * 1024 * 1024) {
            throw StateError('Photo too large');
          }
          final builder = BytesBuilder();
          await for (final chunk in file.readAsByteStream()) {
            if (builder.length + chunk.length > 40 * 1024 * 1024) {
              throw StateError('Photo too large');
            }
            builder.add(chunk);
          }
          final bytes = builder.takeBytes();
          final normalized = await compute(convertCapture, {
            'bytes': bytes,
            'format': 'jpeg',
            'turns': 0,
            'scan': false,
          });
          if (!mounted) return;
          var added = false;
          setState(() => added = appendPhoto(normalized));
          if (!added) break;
          imported++;
          await saveDraft();
        } catch (_) {
          skipped++;
        }
      }
      if (mounted) {
        setState(
          () => status =
              'Imported $imported photo(s).${skipped > 0 ? ' $skipped unsupported/oversize photo(s) skipped.' : ''}',
        );
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Could not import photos: $e');
    } finally {
      if (mounted) {
        setState(() => busy = false);
        unawaited(saveDraft());
      }
    }
  }

  Future<void> newScan() async {
    if (busy) return;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start a new scan?'),
        content: const Text(
          'This removes the saved scan draft. Exported files stay available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep draft'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('New scan'),
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    setState(() => busy = true);
    try {
      await draftStore?.clear();
      if (mounted) {
        setState(() {
          pages.clear();
          selected = 0;
          draftFault = false;
          draftSaved = false;
          status = 'New scan. Add camera pages or choose Gallery.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Could not clear draft: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> straighten() async {
    if (busy || original == null) return;
    setState(() => busy = true);
    try {
      final base = await compute(convertCapture, {
        'bytes': original!,
        'format': 'jpeg',
        'turns': turns,
        'scan': false,
      });
      if (!mounted) return;
      final corners = await Navigator.of(context).push<List<double>>(
        MaterialPageRoute(builder: (_) => ScanCornersPage(bytes: base)),
      );
      if (corners == null || !mounted) return;
      final bytes = await compute(rectifyScan, {
        'bytes': base,
        'corners': corners,
      });
      final display = await compute(convertCapture, {
        'bytes': bytes,
        'format': 'jpeg',
        'turns': 0,
        'scan': scan,
      });
      if (mounted) {
        setState(() {
          current!.original = bytes;
          current!.preview = display;
          turns = 0;
        });
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Could not straighten page: $e');
    } finally {
      if (mounted) {
        setState(() => busy = false);
        unawaited(saveDraft());
      }
    }
  }

  @override
  void dispose() {
    if (ocrActive) unawaited(OfflineSinhalaOcr.cancel());
    super.dispose();
  }

  Future<void> capture() async {
    if (busy || draftFault) return;
    if (pages.length >= 20) {
      setState(() => status = 'Maximum 20 pages per scan.');
      return;
    }
    setState(() {
      busy = true;
      status = '';
    });
    String? path;
    try {
      final access = await channel.invokeMapMethod<String, dynamic>(
        'requestReaderPermissions',
        {'kind': 'camera'},
      );
      if (access?['camera'] != true) {
        if (mounted) {
          setState(
            () => status = 'Camera permission denied. Open Settings & privacy > Permissions to allow it.',
          );
        }
        return;
      }
      path = await channel.invokeMethod<String>('capturePhoto');
      if (path == null) return;
      final file = File(path);
      if (await file.length() > 40 * 1024 * 1024) {
        throw StateError('Photo exceeds 40 MB.');
      }
      final bytes = await file.readAsBytes();
      final display = await compute(convertCapture, {
        'bytes': bytes,
        'format': 'jpeg',
        'turns': 0,
        'scan': false,
      });
      if (mounted) {
        setState(() {
          appendPhoto(display);
        });
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Could not take photo: $e');
    } finally {
      if (path != null) {
        try {
          await channel.invokeMethod<void>('removeCameraCopy', {'path': path});
        } on PlatformException {
          /* Temporary cache can be cleared later. */
        }
      }
      if (mounted) {
        setState(() => busy = false);
        unawaited(saveDraft());
      }
    }
  }

  Future<void> refresh() async {
    if (busy || original == null) return;
    setState(() => busy = true);
    try {
      final bytes = await compute(convertCapture, {
        'bytes': original!,
        'format': 'jpeg',
        'turns': turns,
        'scan': scan,
      });
      if (mounted) setState(() => current!.preview = bytes);
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    } finally {
      if (mounted) {
        setState(() => busy = false);
        unawaited(saveDraft());
      }
    }
  }

  Future<void> cropPage() async {
    if (busy || original == null) return;
    setState(() => busy = true);
    try {
      final base = await compute(convertCapture, {
        'bytes': original!,
        'format': 'jpeg',
        'turns': turns,
        'scan': false,
      });
      if (!mounted) return;
      final crop = await Navigator.of(context).push<List<double>>(
        MaterialPageRoute(builder: (_) => ScanCropPage(bytes: base)),
      );
      if (crop == null || !mounted) return;
      final bytes = await compute(convertCapture, {
        'bytes': base,
        'format': 'jpeg',
        'turns': 0,
        'scan': false,
        'crop': crop,
      });
      final display = await compute(convertCapture, {
        'bytes': bytes,
        'format': 'jpeg',
        'turns': 0,
        'scan': scan,
      });
      if (mounted) {
        setState(() {
          current!.original = bytes;
          current!.preview = display;
          turns = 0;
        });
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Could not crop: $e');
    } finally {
      if (mounted) {
        setState(() => busy = false);
        unawaited(saveDraft());
      }
    }
  }

  Future<void> output(String action) async {
    if (busy || original == null) return;
    setState(() {
      busy = true;
      status = '';
    });
    try {
      var bytes = format == 'pdf'
          ? await compute(scanPagesPdf, pages.map((p) => p.preview).toList())
          : await compute(convertCapture, {
              'bytes': preview!,
              'format': format,
              'turns': 0,
              'scan': false,
            });
      if (!mounted) return;
      if (format == 'pdf' && searchable) {
        ocrActive = true;
        try {
          bytes = await runPdfTask(
            context,
            'Creating searchable PDF',
            (progress) => searchableScanPdf(
              pages.map((p) => p.preview).toList(),
              bytes,
              progress,
              language: ocrLanguage,
            ),
          );
        } finally {
          ocrActive = false;
        }
      }
      if (!mounted) return;
      final name = 'Sara-${DateTime.now().millisecondsSinceEpoch}.$format';
      final mime = format == 'pdf' ? 'application/pdf' : 'image/$format';
      if (action == 'save') {
        final result = await FilePicker.saveFile(
          fileName: name,
          bytes: bytes,
          mimeType: mime,
          dialogTitle: 'Save photo or scan',
        );
        if (mounted) {
          setState(
            () => status = result == null
                ? 'Save cancelled.'
                : 'Saved successfully.',
          );
        }
      } else {
        final root = await getTemporaryDirectory();
        final file = File('${root.path}/$name');
        await file.writeAsBytes(bytes, flush: true);
        if (action == 'library') {
          if (mounted) Navigator.pop(context, file.path);
        } else {
          try {
            await const MethodChannel('pageflow_reader/share')
                .invokeMethod<void>('sharePdf', {
                  'path': file.path,
                  'name': name,
                  'mimeType': mime,
                });
          } finally {
            if (await file.exists()) await file.delete();
          }
        }
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Could not export: $e');
    } finally {
      if (mounted) {
        setState(() => busy = false);
        unawaited(saveDraft());
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Camera / scan'),
      actions: [
        IconButton(
          tooltip: 'Gallery photos',
          onPressed: busy ? null : importGallery,
          icon: const Icon(Icons.photo_library),
        ),
        IconButton(
          tooltip: 'Save scan',
          onPressed: busy || original == null ? null : () => output('save'),
          icon: const Icon(Icons.save_alt),
        ),
        IconButton(
          tooltip: 'New scan',
          onPressed: busy ? null : newScan,
          icon: const Icon(Icons.note_add),
        ),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          if (pages.isNotEmpty)
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (var index = 0; index < pages.length; index++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text('Page ${index + 1}'),
                        selected: selected == index,
                        onSelected: busy
                            ? null
                            : (_) => change(() => selected = index),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: preview == null
                ? const Center(child: Text('Take a photo to get started.'))
                : LayoutBuilder(
                    builder: (_, size) => InteractiveViewer(
                      key: ValueKey(preview),
                      minScale: .5,
                      maxScale: 6,
                      child: SizedBox(
                        width: size.maxWidth,
                        height: size.maxHeight,
                        child: Image.memory(preview!, fit: BoxFit.contain),
                      ),
                    ),
                  ),
          ),
          if (status.isNotEmpty)
            Padding(padding: const EdgeInsets.all(8), child: Text(status)),
          SafeArea(
            top: false,
            child: SizedBox(
              height: (constraints.maxHeight * 0.45).clamp(0.0, 156.0),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: busy ? null : capture,
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('Add page'),
                        ),
                        TextButton.icon(
                          onPressed: busy || original == null
                              ? null
                              : () {
                                  turns = (turns + 1) % 4;
                                  refresh();
                                },
                          icon: const Icon(Icons.rotate_right),
                          label: const Text('Rotate'),
                        ),
                        TextButton.icon(
                          onPressed: busy || current == null ? null : cropPage,
                          icon: const Icon(Icons.crop),
                          label: const Text('Crop'),
                        ),
                        IconButton(
                          tooltip: 'Move page earlier',
                          onPressed: busy || selected == 0 || current == null
                              ? null
                              : () => change(() {
                                  final page = pages.removeAt(selected);
                                  selected--;
                                  pages.insert(selected, page);
                                }),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        IconButton(
                          tooltip: 'Move page later',
                          onPressed:
                              busy ||
                                  selected >= pages.length - 1 ||
                                  current == null
                              ? null
                              : () => change(() {
                                  final page = pages.removeAt(selected);
                                  selected++;
                                  pages.insert(selected, page);
                                }),
                          icon: const Icon(Icons.arrow_forward),
                        ),
                        IconButton(
                          tooltip: 'Delete selected page',
                          onPressed: busy || current == null
                              ? null
                              : () => change(() {
                                  pages.removeAt(selected);
                                  selected = selected.clamp(
                                    0,
                                    pages.isEmpty ? 0 : pages.length - 1,
                                  );
                                }),
                          icon: const Icon(Icons.delete_outline),
                        ),
                        TextButton.icon(
                          onPressed: busy || original == null
                              ? null
                              : straighten,
                          icon: const Icon(Icons.document_scanner),
                          label: const Text('Auto crop / straighten'),
                        ),
                        FilterChip(
                          label: const Text('Scan contrast'),
                          selected: scan,
                          onSelected: busy || original == null
                              ? null
                              : (value) {
                                  scan = value;
                                  refresh();
                                },
                        ),
                        DropdownButton<String>(
                          value: format,
                          items: ['png', 'jpeg', 'pdf']
                              .map(
                                (f) => DropdownMenuItem(
                                  value: f,
                                  child: Text(f.toUpperCase()),
                                ),
                              )
                              .toList(),
                          onChanged: busy
                              ? null
                              : (f) => setState(() => format = f!),
                        ),
                      ],
                    ),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: busy || original == null
                              ? null
                              : () => output('save'),
                          child: const Text('Save as…'),
                        ),
                        OutlinedButton(
                          onPressed: busy || original == null
                              ? null
                              : () => output('share'),
                          child: const Text('Share'),
                        ),
                        TextButton(
                          onPressed: busy || original == null
                              ? null
                              : () => output('library'),
                          child: const Text('Add to library'),
                        ),
                      ],
                    ),
                    Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                        FilterChip(
                          label: const Text('Searchable PDF (OCR)'),
                          selected: searchable,
                          onSelected: busy || format != 'pdf'
                              ? null
                              : (value) => setState(() => searchable = value),
                        ),
                        DropdownButton<String>(
                          value: ocrLanguage,
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
                          onChanged: busy
                              ? null
                              : (value) => setState(() => ocrLanguage = value!),
                        ),
                      ],
                    ),
                    Text(
                      draftSaving
                          ? 'Saving draft…'
                          : draftSaved
                          ? 'Draft saved on this device'
                          : 'Draft not saved yet',
                    ),
                    const Text(
                      'PDF includes all pages in order. PNG/JPEG exports the selected page. Review detected corners and OCR text.',
                      style: TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
