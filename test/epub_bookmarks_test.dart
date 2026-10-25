import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/reading_state.dart';

void main() {
  test(
    'EPUB bookmark state retains exact locations and bounds hostile metadata',
    () {
      final saved = ReadingStateStore.sanitize({
        'unit': 2,
        'scroll': .25,
        'bookMarks': [
          {'unit': 1, 'fraction': .55, 'label': 'Chapter two'},
          {'unit': double.nan, 'fraction': 0},
          {'unit': -4, 'fraction': 8, 'label': 'x' * 200},
        ],
      });
      final marks = saved['bookMarks'] as List;
      expect(marks.length, 2);
      expect(marks[0]['fraction'], .55);
      expect(marks[1]['unit'], 0);
      expect(marks[1]['fraction'], 1);
      expect((marks[1]['label'] as String).length, 80);
      expect(
        (ReadingStateStore.sanitize({
                  'bookMarks': List.generate(
                    300,
                    (_) => {'unit': 0, 'fraction': 0},
                  ),
                })['bookMarks']
                as List)
            .length,
        100,
      );
    },
  );
}
