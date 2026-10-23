import 'dart:io';

import 'package:pageflow_reader/scan_draft.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pageflow_reader/reader_permissions.dart';
import 'package:pageflow_reader/camera_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pageflow_reader/incoming');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  testWidgets(
    'First-open requests access and represents selected photos accurately',
    (tester) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return {'camera': false, 'photos': 'selected'};
          });
      await tester.pumpWidget(
        const MaterialApp(home: ReaderPermissionsPage(requestOnOpen: true)),
      );
      await tester.pumpAndSettle();
      expect(calls, contains('requestReaderPermissions'));
      expect(find.text('Selected photos only'), findsOneWidget);
      expect(find.text('All photos allowed'), findsNothing);
      expect(find.text('Open Android app settings'), findsOneWidget);
    },
  );
  testWidgets(
    'Camera denial never launches capture and leaves recovery guidance',
    (tester) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return {'camera': false, 'photos': 'denied'};
          });
      await tester.pumpWidget(
        MaterialApp(home: CameraCapturePage(store: _NoDraftStore())),
      );
      await tester.pumpAndSettle();
      expect(calls, contains('requestReaderPermissions'));
      expect(calls, isNot(contains('capturePhoto')));
      expect(find.textContaining('Camera permission denied.'), findsOneWidget);
    },
  );
}

class _NoDraftStore extends ScanDraftStore {
  _NoDraftStore() : super(Directory.systemTemp);
  @override
  Future<Map<String, dynamic>?> load() async => {
    'pages': <Map<String, dynamic>>[],
    'selected': 0,
  };
  @override
  Future<void> save(List<Map<String, dynamic>> pages, int selected) async {}
}
