import 'package:flutter_test/flutter_test.dart';
import 'package:offline_document_viewer/offline_document_viewer.dart';

void main() {
  test('Only valid renderer zoom reports update the controller', () {
    final controller = DocumentViewController();
    var changes = 0;
    controller.addListener(() => changes++);
    controller.reportZoom(.24);
    expect(controller.zoomScale, .24);
    for (final invalid in [double.nan, double.infinity, -1.0, 0.0, 4.0]) {
      controller.reportZoom(invalid);
    }
    controller.reportZoom(.24);
    expect(controller.zoomScale, .24);
    expect(changes, 1);
    controller.dispose();
  });
}
