import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'scan_geometry.dart';

class ScanCornersPage extends StatefulWidget {
  const ScanCornersPage({super.key, required this.bytes});
  final Uint8List bytes;
  @override
  State<ScanCornersPage> createState() => _ScanCornersPageState();
}

class _ScanCornersPageState extends State<ScanCornersPage> {
  List<double> corners = [0, 0, 1, 0, 1, 1, 0, 1];
  int selected = 0;
  bool busy = false;
  String message = 'Move the four corners around the paper, then Apply.';
  late final info = img.JpegDecoder().startDecode(widget.bytes)!;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => detect());
  }

  Future<void> detect() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await compute(suggestScanCorners, widget.bytes);
      if (mounted) {
        setState(() {
          if (result != null) corners = result;
          message = result == null
              ? 'No reliable page edge found. Set the corners manually.'
              : 'Suggested corners: review and adjust before applying.';
        });
      }
    } catch (_) {
      if (mounted) setState(() => message = 'Set the corners manually.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Page corners'),
      actions: [
        TextButton(
          onPressed: busy || !validScanCorners(corners)
              ? null
              : () => Navigator.pop(context, corners),
          child: const Text('Apply'),
        ),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, viewport) => Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: info.width / info.height,
                child: LayoutBuilder(
                  builder: (_, size) => GestureDetector(
                    onPanStart: busy
                        ? null
                        : (event) {
                            final point = event.localPosition;
                            var best = double.infinity;
                            for (var i = 0; i < 4; i++) {
                              final distance =
                                  (point -
                                          Offset(
                                            corners[i * 2] * size.maxWidth,
                                            corners[i * 2 + 1] * size.maxHeight,
                                          ))
                                      .distanceSquared;
                              if (distance < best) {
                                best = distance;
                                selected = i;
                              }
                            }
                          },
                    onPanUpdate: busy
                        ? null
                        : (event) => setState(() {
                            corners = List.of(corners);
                            corners[selected *
                                2] = (event.localPosition.dx / size.maxWidth)
                                .clamp(0, 1);
                            corners[selected * 2 +
                                1] = (event.localPosition.dy / size.maxHeight)
                                .clamp(0, 1);
                          }),
                    child: CustomPaint(
                      foregroundPainter: _CornersPainter(corners),
                      child: Image.memory(widget.bytes, fit: BoxFit.fill),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: (viewport.maxHeight * .45).clamp(0.0, 210.0),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  Text(message),
                  Wrap(
                    children: [
                      TextButton(
                        onPressed: busy ? null : detect,
                        child: const Text('Detect page'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(
                                () => corners = [0, 0, 1, 0, 1, 1, 0, 1],
                              ),
                        child: const Text('Reset'),
                      ),
                      DropdownButton<int>(
                        value: selected,
                        items: [
                          for (var i = 0; i < 4; i++)
                            DropdownMenuItem(
                              value: i,
                              child: Text(
                                [
                                  'Top left',
                                  'Top right',
                                  'Bottom right',
                                  'Bottom left',
                                ][i],
                              ),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (value) => setState(() => selected = value!),
                      ),
                    ],
                  ),
                  Slider(
                    label: 'Corner horizontal position',
                    value: corners[selected * 2],
                    onChanged: busy
                        ? null
                        : (value) =>
                              setState(() => corners[selected * 2] = value),
                  ),
                  Slider(
                    label: 'Corner vertical position',
                    value: corners[selected * 2 + 1],
                    onChanged: busy
                        ? null
                        : (value) =>
                              setState(() => corners[selected * 2 + 1] = value),
                  ),
                  if (!validScanCorners(corners))
                    const Text('Corners must outline a page without crossing.'),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CornersPainter extends CustomPainter {
  _CornersPainter(List<double> points) : points = List.of(points);
  final List<double> points;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(points[0] * size.width, points[1] * size.height);
    for (var i = 1; i < 4; i++) {
      path.lineTo(points[i * 2] * size.width, points[i * 2 + 1] * size.height);
    }
    path.close();
    final paint = Paint()
      ..color = validScanCorners(points) ? Colors.cyanAccent : Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawPath(path, paint);
    for (var i = 0; i < 4; i++) {
      canvas.drawCircle(
        Offset(points[i * 2] * size.width, points[i * 2 + 1] * size.height),
        10,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CornersPainter oldDelegate) =>
      !listEquals(points, oldDelegate.points);
}
