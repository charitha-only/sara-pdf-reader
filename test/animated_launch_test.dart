import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/animated_launch.dart';

void main() {
  testWidgets('Launch animates cap/stars and opens child automatically once', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AnimatedLaunch(child: Scaffold(body: Text('Library ready'))),
      ),
    );
    expect(find.text('Get Started'), findsNothing);
    for (
      var i = 0;
      i < 50 && find.byType(CustomPaint).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    final paintings = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .where((p) => p.painter is SaraLaunchPainter);
    expect(paintings, isNotEmpty);
    final painter = paintings.first.painter! as SaraLaunchPainter;
    expect(painter.progress, greaterThan(0));
    expect(painter.progress, lessThan(1));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('Library ready'), findsOneWidget);
    expect(
      tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((p) => p.painter is SaraLaunchPainter),
      isEmpty,
    );
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Library ready'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Reduced motion opens library without waiting for animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: AnimatedLaunch(child: Text('Library ready')),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Library ready'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    expect(tester.takeException(), isNull);
  });
}
