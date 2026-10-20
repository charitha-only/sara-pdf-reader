import 'package:flutter/material.dart';

import 'app_language.dart';

class DocumentPasswordDialog extends StatefulWidget {
  const DocumentPasswordDialog({super.key});
  @override
  State<DocumentPasswordDialog> createState() => _DocumentPasswordDialogState();
}

class _DocumentPasswordDialogState extends State<DocumentPasswordDialog> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const LocalizedText('Document password'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Enter the password to import an unlocked app copy. The original encrypted file stays unchanged. The password is not saved.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('Password')),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const LocalizedText('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text),
        child: const LocalizedText('Unlock'),
      ),
    ],
  );
}
