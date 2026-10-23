import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:printing/printing.dart';

import 'camera_capture.dart';

Future<void> printDocumentFile(
  BuildContext context,
  String path,
  String name, {
  bool image = false,
}) async {
  try {
    final file = File(path);
    final size = await file.length();
    if (size <= 0 || size > (image ? 40 : 256) * 1024 * 1024) {
      throw StateError('File exceeds the print limit.');
    }
    var bytes = await file.readAsBytes();
    if (image) {
      bytes = await compute(convertCapture, {
        'bytes': bytes,
        'turns': 0,
        'scan': false,
        'format': 'pdf',
      });
    }
    if (!context.mounted) return;
    await Printing.layoutPdf(
      name: name.replaceAll(RegExp(r'[\x00-\x1f/\\]'), '_'),
      onLayout: (_) async => bytes,
      dynamicLayout: false,
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not print: $error')));
    }
  }
}

Future<void> printDocumentBytes(
  BuildContext context,
  Uint8List bytes,
  String name,
) async {
  try {
    await Printing.layoutPdf(
      name: name,
      onLayout: (_) async => bytes,
      dynamicLayout: false,
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not print: $error')));
    }
  }
}
