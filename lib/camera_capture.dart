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

class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({super.key});
  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends State<CameraCapturePage> {
  static const channel = MethodChannel('pageflow_reader/incoming');
  Uint8List? original, preview;
  String format = 'pdf', status = '';
  bool busy = false, scan = false;
  int turns = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => capture());
  }

  Future<void> capture() async {
    if (busy) return;
    setState(() {
      busy = true;
      status = '';
    });
    String? path;
    try {
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
          original = bytes;
          preview = display;
          turns = 0;
          scan = false;
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
      if (mounted) setState(() => preview = bytes);
    } catch (e) {
      if (mounted) setState(() => status = '$e');
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
      final bytes = await compute(convertCapture, {
        'bytes': original!,
        'format': format,
        'turns': turns,
        'scan': scan,
      });
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
    body: Column(
      children: [
        if (busy) const LinearProgressIndicator(),
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
            height: 156,
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
                        label: const Text('Take photo'),
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
                    'Scan contrast improves readability; it does not detect page edges.',
                    style: TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
