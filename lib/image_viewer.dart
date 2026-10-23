import 'document_print.dart';
import 'reader_display.dart';

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'file_mime.dart';

/// Preserve aspect ratio, animation, and a nonzero dimension for thin images.
class BoundedFileImage extends FileImage {
  const BoundedFileImage(super.file);
  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) {
    return super.loadImage(
      key,
      (buffer, {getTargetSize}) => decode(
        buffer,
        getTargetSize: (width, height) {
          final scale = math.min(1.0, math.min(2560 / width, 2560 / height));
          return ui.TargetImageSize(
            width: math.max(1, (width * scale).round()),
            height: math.max(1, (height * scale).round()),
          );
        },
      ),
    );
  }
}

class ImageFileViewer extends StatelessWidget {
  const ImageFileViewer({super.key, required this.path, required this.name});
  final String path, name;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        const ReaderOptionsButton(),
        IconButton(
          tooltip: 'Print',
          icon: const Icon(Icons.print),
          onPressed: () => printDocumentFile(context, path, name, image: true),
        ),
        IconButton(
          tooltip: 'Share original file',
          icon: const Icon(Icons.ios_share),
          onPressed: () async {
            try {
              await const MethodChannel('pageflow_reader/share')
                  .invokeMethod<void>('sharePdf', {
                    'path': path,
                    'mimeType': fileMime(path),
                    'name': name,
                  });
            } catch (error) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not share image: $error')),
                );
              }
            }
          },
        ),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, size) => InteractiveViewer(
        minScale: .5,
        maxScale: 8,
        child: SizedBox(
          width: size.maxWidth,
          height: size.maxHeight,
          child: Image(
            image: BoundedFileImage(File(path)),
            fit: BoxFit.contain,
            errorBuilder: (_, error, stack) =>
                const Center(child: Text('This image could not be displayed.')),
          ),
        ),
      ),
    ),
  );
}

class BoundedMemoryImage extends MemoryImage {
  const BoundedMemoryImage(super.bytes);
  @override
  ImageStreamCompleter loadImage(
    MemoryImage key,
    ImageDecoderCallback decode,
  ) => super.loadImage(
    key,
    (buffer, {getTargetSize}) => decode(
      buffer,
      getTargetSize: (width, height) {
        final scale = math.min(1.0, math.min(1600 / width, 1600 / height));
        return ui.TargetImageSize(
          width: math.max(1, (width * scale).round()),
          height: math.max(1, (height * scale).round()),
        );
      },
    ),
  );
}
