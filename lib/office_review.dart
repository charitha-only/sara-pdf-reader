import 'app_language.dart';

import 'package:flutter/material.dart';

class OfficeTextReview extends StatefulWidget {
  const OfficeTextReview({super.key, required this.pages});
  final List<String> pages;
  @override
  State<OfficeTextReview> createState() => _OfficeTextReviewState();
}

class _OfficeTextReviewState extends State<OfficeTextReview> {
  late final List<TextEditingController> controllers;
  @override
  void initState() {
    super.initState();
    controllers = widget.pages
        .map((text) => TextEditingController(text: text))
        .toList();
  }

  @override
  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const LocalizedText('Review text before export'),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, controllers.map((c) => c.text).toList()),
          child: const LocalizedText('Export'),
        ),
      ],
    ),
    body: ListView.builder(
      itemCount: controllers.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: LocalizedText(
              'Correct OCR mistakes and arrange paragraphs here. Exported text is editable. Tables, fonts and page layout can differ from the PDF.',
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: controllers[index - 1],
            minLines: 5,
            maxLines: 15,
            decoration: InputDecoration(
              labelText: 'Page $index',
              border: const OutlineInputBorder(),
            ),
          ),
        );
      },
    ),
  );
}
