import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_language.dart';
import 'release_links.dart';

class ReaderFrame extends StatefulWidget {
  const ReaderFrame({super.key, required this.child});
  final Widget child;
  @override
  State<ReaderFrame> createState() => ReaderFrameState();
}

class ReaderFrameState extends State<ReaderFrame> {
  bool fullscreen = false, awake = false;
  String rotation = 'auto';
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    final p = await AppPreferences.read();
    if (!mounted) return;
    setState(() {
      fullscreen = p['readerFullscreen'] == true;
      awake = p['readerAwake'] == true;
      rotation = ['portrait', 'landscape'].contains(p['readerRotation'])
          ? p['readerRotation'] as String
          : 'auto';
    });
    await apply();
  }

  Future<void> apply() async {
    await SystemChrome.setEnabledSystemUIMode(
      fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    if (!mounted) return;
    await SystemChrome.setPreferredOrientations(switch (rotation) {
      'portrait' => [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ],
      'landscape' => [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
      _ => [],
    });
    if (!mounted) return;
    try {
      await incomingChannel.invokeMethod<void>('readerDisplay', {
        'awake': awake,
      });
    } on MissingPluginException {
      /* Desktop widget test. */
    } on PlatformException {
      /* The reader remains usable without this optional flag. */
    }
  }

  Future<void> choose(String value) async {
    setState(() {
      if (value == 'fullscreen') {
        fullscreen = !fullscreen;
      } else if (value == 'awake') {
        awake = !awake;
      } else {
        rotation = value;
      }
    });
    await apply();
    await AppPreferences.write({
      'readerFullscreen': fullscreen,
      'readerAwake': awake,
      'readerRotation': rotation,
    });
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(SystemChrome.setPreferredOrientations([]));
    unawaited(
      incomingChannel
          .invokeMethod<void>('readerDisplay', {'awake': false})
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class ReaderOptionsButton extends StatelessWidget {
  const ReaderOptionsButton({super.key});
  @override
  Widget build(BuildContext context) {
    final frame = context.findAncestorStateOfType<ReaderFrameState>();
    return PopupMenuButton<String>(
      tooltip: tr('Display options'),
      icon: const Icon(Icons.display_settings),
      onSelected: frame == null ? null : (value) => frame.choose(value),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: 'fullscreen',
          checked: frame?.fullscreen ?? false,
          child: const LocalizedText('Full screen'),
        ),
        CheckedPopupMenuItem(
          value: 'awake',
          checked: frame?.awake ?? false,
          child: const LocalizedText('Keep screen on'),
        ),
        for (final entry in {
          'auto': 'Automatic rotation',
          'portrait': 'Lock portrait',
          'landscape': 'Lock landscape',
        }.entries)
          CheckedPopupMenuItem(
            value: entry.key,
            checked: frame?.rotation == entry.key,
            child: LocalizedText(entry.value),
          ),
      ],
    );
  }
}
