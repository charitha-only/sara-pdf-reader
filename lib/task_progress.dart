import 'app_language.dart';

import 'package:flutter/material.dart';

class TaskCancelled implements Exception {
  const TaskCancelled();
  @override
  String toString() => 'Cancelled by user.';
}

class TaskProgress extends ChangeNotifier {
  bool cancelled = false;
  VoidCallback? onCancel;
  double? fraction;
  String message = 'Preparing…';
  void cancel() {
    if (cancelled) return;
    cancelled = true;
    onCancel?.call();
    message = 'Stopping after the current step…';
    notifyListeners();
  }

  void check() {
    if (cancelled) throw const TaskCancelled();
  }

  void update(String text, {int? done, int? total}) {
    check();
    message = text;
    fraction = done != null && total != null && total > 0
        ? (done / total).clamp(0, 1)
        : null;
    notifyListeners();
  }

  Future<void> step(String text, {int? done, int? total}) async {
    check();
    update(text, done: done, total: total);
    await Future<void>.delayed(Duration.zero);
    check();
  }
}

Future<T> runPdfTask<T>(
  BuildContext context,
  String title,
  Future<T> Function(TaskProgress) work,
) async {
  final progress = TaskProgress();
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AnimatedBuilder(
        animation: progress,
        builder: (context, _) => AlertDialog(
          title: LocalizedText(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress.fraction),
              const SizedBox(height: 16),
              LocalizedText(progress.message),
            ],
          ),
          actions: [
            TextButton(
              onPressed: progress.cancelled ? null : progress.cancel,
              child: const LocalizedText('Cancel'),
            ),
          ],
        ),
      ),
    ),
  );
  navigator.push(route);
  try {
    await Future<void>.delayed(Duration.zero);
    final result = await work(progress);
    progress.check();
    return result;
  } catch (_) {
    if (progress.cancelled) throw const TaskCancelled();
    rethrow;
  } finally {
    if (route.isActive) navigator.removeRoute(route);
    progress.dispose();
  }
}
