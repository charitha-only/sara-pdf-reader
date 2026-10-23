import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

Uint8List enhanceScan(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  if (bytes.length > 40 * 1024 * 1024) throw ArgumentError('Scan exceeds 40 MB');
  final info = img.JpegDecoder().startDecode(bytes);
  if (info == null ||
      info.width > 2400 ||
      info.height > 2400 ||
      bytes.length > 40 * 1024 * 1024) {
    throw ArgumentError('Invalid scan image');
  }
  final source = img.decodeJpg(args['bytes'] as Uint8List);
  if (source == null || source.width > 2400 || source.height > 2400) {
    throw ArgumentError('Invalid scan image');
  }
  final brightness = (args['brightness'] as num).toDouble();
  final contrast = (args['contrast'] as num).toDouble();
  if (!brightness.isFinite ||
      !contrast.isFinite ||
      brightness < .5 ||
      brightness > 1.5 ||
      contrast < .5 ||
      contrast > 2) {
    throw ArgumentError('Invalid image settings');
  }
  if (args['shadows'] == true) {
    // A local bright-envelope estimates paper illumination without averaging
    // dark lettering into the background. Work stays bounded on a small image.
    final scale = math.min(1.0, 240 / math.max(source.width, source.height));
    final w = math.max(1, (source.width * scale).round());
    final h = math.max(1, (source.height * scale).round());
    final small = img.copyResize(source, width: w, height: h);
    final envelope = img.Image(width: w, height: h);
    for (final p in envelope) {
      double light = 0;
      for (var y = math.max(0, p.y - 8); y <= math.min(h - 1, p.y + 8); y++) {
        for (var x = math.max(0, p.x - 8); x <= math.min(w - 1, p.x + 8); x++) {
          light = math.max(light, small.getPixel(x, y).luminance.toDouble());
        }
      }
      p
        ..r = light
        ..g = light
        ..b = light;
    }
    final background = img.gaussianBlur(envelope, radius: 6);
    for (final pixel in source) {
      final bg = background.getPixel(
        (pixel.x * background.width / source.width).floor().clamp(
          0,
          background.width - 1,
        ),
        (pixel.y * background.height / source.height).floor().clamp(
          0,
          background.height - 1,
        ),
      );
      final paperGain = (245 / math.max(50, bg.luminance)).clamp(1.0, 4.0);
      // Protect near-black ink even inside thick strokes or solid dark regions.
      final gain = pixel.luminance < 30 ? math.min(paperGain, 1.6) : paperGain;
      pixel
        ..r = (pixel.r * gain).clamp(0, 255)
        ..g = (pixel.g * gain).clamp(0, 255)
        ..b = (pixel.b * gain).clamp(0, 255);
    }
  }
  final output = img.adjustColor(
    source,
    brightness: brightness,
    contrast: contrast,
  );
  return Uint8List.fromList(img.encodeJpg(output, quality: 92));
}

class ScanAdjustPage extends StatefulWidget {
  const ScanAdjustPage({super.key, required this.bytes});
  final Uint8List bytes;
  @override
  State<ScanAdjustPage> createState() => _ScanAdjustPageState();
}

class _ScanAdjustPageState extends State<ScanAdjustPage> {
  double brightness = 1, contrast = 1;
  bool shadows = false, busy = false;
  Uint8List? preview;
  String error = '';
  Future<void> process({bool apply = false}) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await compute(enhanceScan, {
        'bytes': widget.bytes,
        'brightness': brightness,
        'contrast': contrast,
        'shadows': shadows,
      });
      if (!mounted) return;
      if (apply) {
        Navigator.pop(context, result);
        return;
      }
      setState(() => preview = result);
    } catch (e) {
      if (mounted) setState(() => error = 'Could not adjust this image: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Image cleanup'),
      actions: [
        TextButton(
          onPressed: busy ? null : () => process(apply: true),
          child: const Text('Apply'),
        ),
      ],
    ),
    body: Column(
      children: [
        if (busy) const LinearProgressIndicator(),
        Expanded(
          child: InteractiveViewer(
            minScale: .5,
            maxScale: 6,
            child: Image.memory(preview ?? widget.bytes, fit: BoxFit.contain),
          ),
        ),
        SizedBox(
          height: math.min(220.0, MediaQuery.sizeOf(context).height * .35),
          child: SingleChildScrollView(
            child: Column(
              children: [
                const Text(
                  'Adjust settings, then Preview or Apply. Original gallery files stay unchanged.',
                ),
                Text('Brightness ${(brightness * 100).round()}%'),
                Slider(
                  value: brightness,
                  min: .5,
                  max: 1.5,
                  onChanged: busy
                      ? null
                      : (v) => setState(() => brightness = v),
                ),
                Text('Contrast ${(contrast * 100).round()}%'),
                Slider(
                  value: contrast,
                  min: .5,
                  max: 2,
                  onChanged: busy ? null : (v) => setState(() => contrast = v),
                ),
                SwitchListTile(
                  title: const Text('Reduce uneven shadows'),
                  value: shadows,
                  onChanged: busy ? null : (v) => setState(() => shadows = v),
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: busy ? null : () => process(),
                      child: const Text('Preview'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() {
                              brightness = 1;
                              contrast = 1;
                              shadows = false;
                              preview = null;
                            }),
                      child: const Text('Reset'),
                    ),
                  ],
                ),
                if (error.isNotEmpty) Text(error),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
