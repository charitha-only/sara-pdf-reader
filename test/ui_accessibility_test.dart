import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/animated_launch.dart';
import 'package:pageflow_reader/app_language.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final size in [const Size(320, 640), const Size(1024, 768)]) {
    testWidgets('launch fits ${size.width} wide with large accessible text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: const TextScaler.linear(1.5),
            ),
            child: const AnimatedLaunch(
              child: Scaffold(body: Text('Library ready')),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Get Started'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('Sinhala controls update without translating document content', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            LocalizedText('Save copy'),
            Text('English document content'),
          ],
        ),
      ),
    );
    AppLanguage.instance.value = 'si';
    await tester.pump();
    expect(find.text('පිටපතක් සුරකින්න'), findsOneWidget);
    expect(find.text('English document content'), findsOneWidget);
    AppLanguage.instance.value = 'en';
    await tester.pump();
    expect(find.text('Save copy'), findsOneWidget);
  });
}
