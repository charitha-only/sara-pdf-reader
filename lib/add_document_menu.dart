import 'package:flutter/material.dart';

/// Opening this sheet never starts hardware access or asks for permission.
class AddDocumentMenu extends StatelessWidget {
  const AddDocumentMenu({super.key});
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in const [
            ('documents', 'Documents', Icons.folder_open),
            ('images', 'Images', Icons.image),
            ('camera', 'Camera / scan', Icons.camera_alt),
            ('gallery', 'Gallery photos → scan', Icons.photo_library),
            ('resume', 'Resume saved scan', Icons.restore),
          ])
            ListTile(
              leading: Icon(item.$3),
              title: Text(item.$2),
              onTap: () => Navigator.pop(context, item.$1),
            ),
        ],
      ),
    ),
  );
}
