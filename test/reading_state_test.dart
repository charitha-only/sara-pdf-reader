import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/reading_state.dart';

void main() {
  test(
    'Restored reading metadata clamps invalid values and strips unrelated data',
    () {
      expect(
        ReadingStateStore.sanitize({
          'unit': -20,
          'scroll': 4,
          'horizontal': double.infinity,
          'mode': 'javascript:bad',
          'unrelated': 'discard',
        }),
        {'unit': 0, 'scroll': 1.0, 'horizontal': 0.0, 'mode': 'width'},
      );
      expect(
        ReadingStateStore.sanitize({
          'unit': 'invalid',
          'scroll': double.nan,
          'horizontal': -4,
        }),
        {'unit': 0, 'scroll': 0.0, 'horizontal': 0.0, 'mode': 'width'},
      );
    },
  );
  test(
    'Reading metadata preserves the valid sheet, viewport and size mode',
    () {
      expect(
        ReadingStateStore.sanitize({
          'unit': 3,
          'scroll': .62,
          'horizontal': 150,
          'mode': 'actual',
        }),
        {'unit': 3, 'scroll': .62, 'horizontal': 150.0, 'mode': 'actual'},
      );
    },
  );
}
