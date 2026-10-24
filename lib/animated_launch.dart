import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One launch animation, then the reader. No extra route or Get Started step.
class AnimatedLaunch extends StatefulWidget {
  const AnimatedLaunch({super.key, required this.child});
  final Widget child;
  @override
  State<AnimatedLaunch> createState() => _AnimatedLaunchState();
}

class _AnimatedLaunchState extends State<AnimatedLaunch>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1800),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed) complete();
      });
  ui.Image? logo;
  bool finished = false, reducedMotion = false;

  @override
  void initState() {
    super.initState();
    loadLogo();
  }

  Future<void> loadLogo() async {
    ui.Codec? codec;
    try {
      final data = await rootBundle.load(
        'assets/branding/Sara-PDF-Reader-logo-transparent.png',
      );
      codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      final image = (await codec.getNextFrame()).image;
      if (!mounted || finished) {
        image.dispose();
        return;
      }
      setState(() => logo = image);
    } catch (_) {
      // A missing/corrupt brand asset must never prevent reading documents.
      if (!mounted || finished) return;
    } finally {
      codec?.dispose();
    }
    if (mounted && !finished && !reducedMotion) controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (reducedMotion && !finished) {
      WidgetsBinding.instance.addPostFrameCallback((_) => complete());
    }
  }

  void complete() {
    if (!mounted || finished) return;
    controller.stop();
    final oldLogo = logo;
    setState(() {
      finished = true;
      logo = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => oldLogo?.dispose());
  }

  @override
  void dispose() {
    controller.dispose();
    logo?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (finished) return widget.child;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: dark ? const Color(0xFF10191A) : const Color(0xFFF3F7F7),
      body: SafeArea(
        child: Center(
          child: Semantics(
            label: 'Sara PDF Reader is opening',
            image: true,
            child: ExcludeSemantics(
              child: LayoutBuilder(
                builder: (context, box) {
                  final width = math.min(
                    310.0,
                    math.min(box.maxWidth * .78, box.maxHeight * .62),
                  );
                  return SizedBox(
                    width: width,
                    height: width * 860 / 620,
                    child: AnimatedBuilder(
                      animation: controller,
                      builder: (context, _) => logo == null
                          ? const Center(
                              child: Icon(
                                Icons.description_outlined,
                                size: 72,
                                color: Color(0xFF00DDE0),
                              ),
                            )
                          : CustomPaint(
                              painter: SaraLaunchPainter(
                                logo!,
                                controller.value,
                              ),
                            ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Clip the existing transparent artwork into layers; no altered logo bitmap.
class SaraLaunchPainter extends CustomPainter {
  SaraLaunchPainter(this.image, this.progress);
  final ui.Image image;
  final double progress;
  static const stars = [
    Rect.fromLTRB(710, 140, 802, 226),
    Rect.fromLTRB(772, 96, 824, 149),
    Rect.fromLTRB(817, 110, 906, 198),
    Rect.fromLTRB(782, 213, 854, 282),
  ];
  static Path cap() => Path()
    ..moveTo(584, 284)
    ..lineTo(663, 229)
    ..lineTo(761, 234)
    ..lineTo(724, 261)
    ..lineTo(731, 274)
    ..lineTo(710, 281)
    ..lineTo(687, 298)
    ..lineTo(650, 293)
    ..lineTo(629, 299)
    ..lineTo(625, 288)
    ..lineTo(615, 287)
    ..lineTo(610, 319)
    ..lineTo(600, 336)
    ..lineTo(592, 350)
    ..lineTo(575, 341)
    ..lineTo(575, 331)
    ..lineTo(601, 311)
    ..lineTo(607, 285)
    ..close();
  double phase(double start, double end) =>
      ((progress - start) / (end - start)).clamp(0.0, 1.0);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 620, size.height / 860);
    canvas.translate(-390, -90);
    final capPath = cap();
    var cutouts = capPath;
    for (final star in stars) {
      cutouts = Path.combine(
        PathOperation.union,
        cutouts,
        Path()..addRect(star),
      );
    }
    final body = Path.combine(
      PathOperation.difference,
      Path()..addRect(const Rect.fromLTWH(0, 0, 1402, 1122)),
      cutouts,
    );
    void layer(
      Path clip,
      double opacity, {
      Offset shift = Offset.zero,
      Offset pivot = Offset.zero,
      double angle = 0,
      double scale = 1,
    }) {
      canvas.save();
      canvas.translate(shift.dx, shift.dy);
      canvas.translate(pivot.dx, pivot.dy);
      canvas.rotate(angle);
      canvas.scale(scale);
      canvas.translate(-pivot.dx, -pivot.dy);
      canvas.clipPath(clip);
      canvas.drawImage(
        image,
        Offset.zero,
        Paint()..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0)),
      );
      canvas.restore();
    }

    final bodyT = Curves.easeOut.transform(phase(0, .3));
    layer(body, bodyT, shift: Offset(0, 18 * (1 - bodyT)));
    final capT = Curves.easeOutCubic.transform(phase(.12, .65));
    layer(
      capPath,
      phase(.12, .3),
      shift: Offset(0, -65 * (1 - capT)),
      pivot: const Offset(668, 280),
      angle: -.18 * (1 - capT),
    );
    for (var i = 0; i < stars.length; i++) {
      final t = phase(.3 + i * .09, .65 + i * .09);
      final pop = Curves.easeOutBack.transform(t);
      layer(
        Path()..addRect(stars[i]),
        t,
        pivot: stars[i].center,
        scale: .25 + .75 * pop,
        angle: (1 - t) * .25,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SaraLaunchPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.progress != progress;
}
