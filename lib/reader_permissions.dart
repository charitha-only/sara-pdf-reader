import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ReaderPermissionsPage extends StatefulWidget {
  const ReaderPermissionsPage({super.key, this.requestOnOpen = false});
  final bool requestOnOpen;
  @override
  State<ReaderPermissionsPage> createState() => _ReaderPermissionsPageState();
}

class _ReaderPermissionsPageState extends State<ReaderPermissionsPage>
    with WidgetsBindingObserver {
  static const channel = MethodChannel('pageflow_reader/incoming');
  Map<String, dynamic> access = {};
  bool busy = false;
  String error = '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => update(request: widget.requestOnOpen),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy) update();
  }

  Future<void> update({bool request = false, String kind = 'all'}) async {
    if (busy || !mounted) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final state = await channel.invokeMapMethod<String, dynamic>(
        request ? 'requestReaderPermissions' : 'permissionState',
        request ? {'kind': kind} : null,
      );
      if (mounted) setState(() => access = state ?? {});
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => error = e.message ?? 'Permission request failed.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Permission settings are available on Android.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Permissions')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Allow camera access for scans and photo access for your image library. Android may offer access to all photos or only selected photos. You can change these choices later.',
        ),
        if (busy) const LinearProgressIndicator(),
        ListTile(
          leading: const Icon(Icons.camera_alt),
          title: const Text('Camera'),
          subtitle: Text(access['camera'] == true ? 'Allowed' : 'Not allowed'),
          trailing: TextButton(
            onPressed: busy
                ? null
                : () => update(request: true, kind: 'camera'),
            child: const Text('Allow'),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library),
          title: const Text('Photos / gallery'),
          subtitle: Text(switch (access['photos']) {
            'all' => 'All photos allowed',
            'selected' => 'Selected photos only',
            _ => 'Not allowed',
          }),
          trailing: TextButton(
            onPressed: busy
                ? null
                : () => update(request: true, kind: 'photos'),
            child: const Text('Manage'),
          ),
        ),
        const ListTile(
          leading: Icon(Icons.folder_open),
          title: Text('Documents and saving files'),
          subtitle: Text(
            'Choose documents or a save location in the Android file picker. That selection grants access. App-private library data needs no extra permission.',
          ),
        ),
        if (error.isNotEmpty) Text(error),
        FilledButton(
          onPressed: busy ? null : () => update(request: true),
          child: const Text('Request camera and photos access'),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () async {
                  try {
                    await channel.invokeMethod<void>('openDefaultSettings');
                  } on PlatformException {
                    if (mounted) {
                      setState(
                        () => error = 'Open Android Settings > Apps > Sara PDF Reader > Permissions.',
                      );
                    }
                  }
                },
          child: const Text('Open Android app settings'),
        ),
        const Text(
          'If Android stops showing a request after repeated denials, allow access from app settings. You can continue reading chosen files without gallery access.',
        ),
        OutlinedButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
}

class PermissionLaunchGate extends StatefulWidget {
  const PermissionLaunchGate({super.key, required this.child});
  final Widget child;
  static Future<void>? _pending;
  static Future<void> ensure(BuildContext context) =>
      _pending ??= _open(context).whenComplete(() => _pending = null);
  static Future<void> _open(BuildContext context) async {
    if (!Platform.isAndroid) return;
    try {
      final seen = await const MethodChannel('pageflow_reader/incoming')
          .invokeMethod<bool>('permissionSetupSeen');
      if (seen != true && context.mounted) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => const ReaderPermissionsPage(requestOnOpen: true),
          ),
        );
      }
    } on PlatformException {
      /* Access can be retried from Settings. */
    } on MissingPluginException {
      /* Non-Android host. */
    }
  }

  @override
  State<PermissionLaunchGate> createState() => _PermissionLaunchGateState();
}

class _PermissionLaunchGateState extends State<PermissionLaunchGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) PermissionLaunchGate.ensure(context);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
