import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

bool validScanCorners(List<double> p) {
  if (p.length != 8 || p.any((v) => !v.isFinite || v < 0 || v > 1)) {
    return false;
  }
  var sign = 0.0, area = 0.0;
  for (var i = 0; i < 4; i++) {
    final j = (i + 1) % 4, k = (i + 2) % 4;
    final cross =
        (p[j * 2] - p[i * 2]) * (p[k * 2 + 1] - p[j * 2 + 1]) -
        (p[j * 2 + 1] - p[i * 2 + 1]) * (p[k * 2] - p[j * 2]);
    if (cross.abs() < .0001 || (sign != 0 && cross * sign < 0)) return false;
    sign = cross;
    area += p[i * 2] * p[j * 2 + 1] - p[j * 2] * p[i * 2 + 1];
  }
  return area / 2 > .05;
}

/// Bright-paper heuristic. Return no suggestion for ambiguous/background-only images.
List<double>? suggestScanCorners(Uint8List bytes) {
  final source = img.decodeJpg(bytes);
  if (source == null) return null;
  final image = img.copyResize(
    source,
    width: source.width >= source.height ? 360 : null,
    height: source.height > source.width ? 360 : null,
  );
  final w = image.width, h = image.height;
  var border = 0.0, count = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (x < 3 || y < 3 || x >= w - 3 || y >= h - 3) {
        border += image.getPixel(x, y).luminance;
        count++;
      }
    }
  }
  final threshold = (border / count + 30).clamp(110, 225);
  final seen = Uint8List(w * h);
  List<int> best = [];
  for (var start = 0; start < seen.length; start++) {
    if (seen[start] != 0) continue;
    seen[start] = 1;
    if (image.getPixel(start % w, start ~/ w).luminance < threshold) continue;
    final component = <int>[start];
    for (var q = 0; q < component.length; q++) {
      final pos = component[q], x = pos % w, y = pos ~/ w;
      for (final next in [
        if (x > 0) pos - 1,
        if (x < w - 1) pos + 1,
        if (y > 0) pos - w,
        if (y < h - 1) pos + w,
      ]) {
        if (seen[next] != 0) continue;
        seen[next] = 1;
        if (image.getPixel(next % w, next ~/ w).luminance >= threshold) {
          component.add(next);
        }
      }
    }
    if (component.length > best.length) best = component;
  }
  if (best.length < w * h * .15 || best.length > w * h * .95) return null;
  var tl = best.first, tr = tl, br = tl, bl = tl;
  for (final n in best) {
    final x = n % w, y = n ~/ w;
    if (x + y < tl % w + tl ~/ w) tl = n;
    if (x - y > tr % w - tr ~/ w) tr = n;
    if (x + y > br % w + br ~/ w) br = n;
    if (x - y < bl % w - bl ~/ w) bl = n;
  }
  final corners = [
    for (final n in [tl, tr, br, bl]) ...[n % w / (w - 1), n ~/ w / (h - 1)],
  ];
  return validScanCorners(corners) ? corners : null;
}

Uint8List rectifyScan(Map<String, dynamic> args) {
  final p = List<double>.from(args['corners'] as List);
  if (!validScanCorners(p)) {
    throw ArgumentError('Choose four non-crossing corners around the page.');
  }
  final source = img.decodeJpg(args['bytes'] as Uint8List);
  if (source == null) throw StateError('Invalid scan image');
  final xs = [for (var i = 0; i < 4; i++) p[i * 2] * (source.width - 1)],
      ys = [for (var i = 0; i < 4; i++) p[i * 2 + 1] * (source.height - 1)];
  double distance(int a, int b) =>
      math.sqrt(math.pow(xs[a] - xs[b], 2) + math.pow(ys[a] - ys[b], 2));
  final width = (((distance(0, 1) + distance(3, 2)) / 2).round() + 1).clamp(
    2,
    2400,
  );
  final height = (((distance(0, 3) + distance(1, 2)) / 2).round() + 1).clamp(
    2,
    2400,
  );
  final dx1 = xs[1] - xs[2],
      dx2 = xs[3] - xs[2],
      dx3 = xs[0] - xs[1] + xs[2] - xs[3];
  final dy1 = ys[1] - ys[2],
      dy2 = ys[3] - ys[2],
      dy3 = ys[0] - ys[1] + ys[2] - ys[3];
  double g = 0, h = 0;
  if (dx3.abs() + dy3.abs() > .00001) {
    final denominator = dx1 * dy2 - dx2 * dy1;
    if (denominator.abs() < .000001) {
      throw ArgumentError('Page corners are too narrow.');
    }
    g = (dx3 * dy2 - dx2 * dy3) / denominator;
    h = (dx1 * dy3 - dx3 * dy1) / denominator;
  }
  final a = xs[1] - xs[0] + g * xs[1],
      b = xs[3] - xs[0] + h * xs[3],
      d = ys[1] - ys[0] + g * ys[1],
      e = ys[3] - ys[0] + h * ys[3];
  final target = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    final v = y / (height - 1);
    for (var x = 0; x < width; x++) {
      final u = x / (width - 1), z = g * u + h * v + 1;
      final sx = ((a * u + b * v + xs[0]) / z).clamp(0.0, source.width - 1.0),
          sy = ((d * u + e * v + ys[0]) / z).clamp(0.0, source.height - 1.0);
      target.setPixel(
        x,
        y,
        source.getPixelInterpolate(
          sx,
          sy,
          interpolation: img.Interpolation.linear,
        ),
      );
    }
  }
  return Uint8List.fromList(img.encodeJpg(target, quality: 92));
}
