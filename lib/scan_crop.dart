import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

class ScanCropPage extends StatefulWidget {
  const ScanCropPage({super.key, required this.bytes});
  final Uint8List bytes;
  @override
  State<ScanCropPage> createState() => _ScanCropPageState();
}

class _ScanCropPageState extends State<ScanCropPage> {
  double left = 0, top = 0, right = 1, bottom = 1;
  late final info = img.JpegDecoder().startDecode(widget.bytes)!;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Crop page'),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            left = top = 0;
            right = bottom = 1;
          }),
          child: const Text('Reset'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, <double>[left, top, right, bottom]),
          child: const Text('Apply'),
        ),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: info.width / info.height,
                child: LayoutBuilder(
                  builder: (_, size) => Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(widget.bytes, fit: BoxFit.fill),
                      Positioned.fromRect(
                        rect: Rect.fromLTRB(
                          left * size.maxWidth,
                          top * size.maxHeight,
                          right * size.maxWidth,
                          bottom * size.maxHeight,
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Colors.cyanAccent,
                              width: 3,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: SizedBox(
              height: (constraints.maxHeight * 0.6).clamp(0.0, 230.0),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const Text(
                      'Adjust the four edges. Only the outlined area is kept.',
                    ),
                    edge('Left', left, 0, right - .1, (value) => left = value),
                    edge(
                      'Right',
                      right,
                      left + .1,
                      1,
                      (value) => right = value,
                    ),
                    edge('Top', top, 0, bottom - .1, (value) => top = value),
                    edge(
                      'Bottom',
                      bottom,
                      top + .1,
                      1,
                      (value) => bottom = value,
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
  Widget edge(
    String label,
    double value,
    double minimum,
    double maximum,
    ValueChanged<double> update,
  ) => Row(
    children: [
      SizedBox(width: 65, child: Text(label)),
      Expanded(
        child: Slider(
          label: '$label ${(value * 100).round()}%',
          value: value.clamp(minimum, maximum),
          min: minimum,
          max: maximum,
          onChanged: (value) => setState(() => update(value)),
        ),
      ),
    ],
  );
}
