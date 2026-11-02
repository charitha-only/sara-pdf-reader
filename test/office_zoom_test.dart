import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/office_zoom.dart';
import 'package:pageflow_reader/reading_state.dart';

void main() {
  test('Zoom steps follow the displayed fit rather than jumping to 125%', () {
    expect(nextOfficeZoom(.24, 1), '0.25');
    expect(nextOfficeZoom(.24, -1), '0.1');
    expect(nextOfficeZoom(.03, 1), '0.1');
    expect(nextOfficeZoom(.03, -1), isNull);
    expect(nextOfficeZoom(1, 1), '1.25');
    expect(nextOfficeZoom(.75, 1), 'actual');
    expect(nextOfficeZoom(3, 1), isNull);
    expect(nextOfficeZoom(.1, -1), isNull);
    expect(nextOfficeZoom(double.nan, 1), isNull);
    expect(nextOfficeZoom(1, 0), isNull);
  });
  test('New manual Office zoom levels survive saved-state sanitization', () {
    for (final mode in ['0.1', '0.25', 'width', 'page', 'actual', '3']) {
      expect(ReadingStateStore.sanitize({'mode': mode})['mode'], mode);
    }
    expect(ReadingStateStore.sanitize({'mode': '500'})['mode'], 'width');
  });
}
