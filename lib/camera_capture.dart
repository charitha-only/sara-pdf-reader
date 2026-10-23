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
  const CameraCapturePage({super.key});
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
  bool busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => capture());
  }

  Future<void> capture() async {
    if (busy) return;
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
          final total = pages.fold<int>(
            0,
            (sum, p) => sum + p.original.length + p.preview.length,
          );
          if (total + display.length * 2 > 60 * 1024 * 1024) {
            status = 'Scan memory limit reached. Save this scan first.';
            return;
          }
          pages.add(_ScanPage(display, display));
          selected = pages.length - 1;
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
      if (mounted) setState(() => busy = false);
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
      if (mounted) setState(() => busy = false);
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
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> output(String action) async {
    if (busy || original == null) return;
    setState(() {
      busy = true;
      status = '';
    });
    try {
      final bytes = format == 'pdf'
          ? await compute(scanPagesPdf, pages.map((p) => p.preview).toList())
          : await compute(convertCapture, {
              'bytes': preview!,
              'format': format,
              'turns': 0,
              'scan': false,
            });
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
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Camera / scan')),
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
                            : (_) => setState(() => selected = index),
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
                              : () => setState(() {
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
                              : () => setState(() {
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
                              : () => setState(() {
                                  pages.removeAt(selected);
                                  selected = selected.clamp(
                                    0,
                                    pages.isEmpty ? 0 : pages.length - 1,
                                  );
                                }),
                          icon: const Icon(Icons.delete_outline),
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
                    const Text(
                      'PDF includes all pages in order. PNG/JPEG exports the selected page. Crop is manual.',
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
