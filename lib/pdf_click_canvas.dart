import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'pdfium_object_editor.dart';

class PdfClickCanvas extends StatefulWidget {
  const PdfClickCanvas({
    super.key,
    required this.image,
    required this.aspectRatio,
    required this.targets,
    required this.onTap,
    required this.onScan,
    this.selected,
    this.enabled = true,
    this.zoomable = false,
  });
  final Uint8List image;
  final double aspectRatio;
  final List<PdfTapTarget> targets;
  final void Function(PdfObjectInfo) onTap;
  final VoidCallback onScan;
  final int? selected;
  final bool enabled;
  final bool zoomable;
  @override
  State<PdfClickCanvas> createState() => _PdfClickCanvasState();
}

class _PdfClickCanvasState extends State<PdfClickCanvas> {
  final controller = TransformationController();
  bool zoomed = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: LayoutBuilder(
        builder: (context, size) => Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: widget.enabled ? widget.onScan : null,
                child: Image.memory(
                  widget.image,
                  fit: BoxFit.fill,
                  semanticLabel: 'PDF page preview',
                ),
              ),
            ),
            for (final target in widget.targets.where(
              (t) => t.object.canEditText,
            ))
              Positioned(
                left: target.left * size.maxWidth,
                top: target.top * size.maxHeight,
                width: (target.right - target.left) * size.maxWidth,
                height: (target.bottom - target.top) * size.maxHeight,
                child: Semantics(
                  button: true,
                  label:
                      'Edit ${target.object.textBox?.text ?? target.object.text}',
                  child: GestureDetector(
                    key: ValueKey('pdf-text-hit-${target.object.index}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.enabled
                        ? () => widget.onTap(target.object)
                        : null,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.teal.withValues(alpha: .035),
                        border: Border.all(
                          color: Colors.teal.withValues(alpha: .55),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (!widget.zoomable) return content;
    return InteractiveViewer(
      transformationController: controller,
      panEnabled: zoomed,
      onInteractionUpdate: (_) {
        final next = controller.value.getMaxScaleOnAxis() > 1.02;
        if (next != zoomed) setState(() => zoomed = next);
      },
      minScale: 1,
      maxScale: 5,
      constrained: true,
      child: content,
    );
  }
}
