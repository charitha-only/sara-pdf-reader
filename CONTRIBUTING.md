# Contributing

Keep the default app focused on reading. Editing and conversion interfaces are
experimental and disabled by default. Do not enable them in a reader bug fix.

Before submitting a change, run `flutter analyze` and `flutter test`, and run the
vendored Office engine tests when changing document rendering. For visual changes,
check on an Android device with a representative synthetic document. Describe
tested formats and any remaining limitations in the pull request.

Use generated or openly licensed test documents. Never commit real invoices,
customer documents, signing keys, passwords or base64 copies of private files.
Keep upstream copyright/license notices and document vendored modifications.

Contributions to original Sara PDF Reader code are provided under the repository's MIT
license. Upstream dependencies remain governed by their own licenses.
