const officeZoomLevels = <double>[.1, .25, .5, .75, 1, 1.25, 1.5, 2, 3];

/// Step from the rendered scale, including fits below the manual zoom range.
String? nextOfficeZoom(double scale, int direction) {
  if (!scale.isFinite || scale <= 0 || direction == 0) return null;
  final levels = direction > 0 ? officeZoomLevels : officeZoomLevels.reversed;
  for (final level in levels) {
    if (direction > 0 ? level > scale + .001 : level < scale - .001) {
      return level == 1 ? 'actual' : level.toString();
    }
  }
  return null;
}
