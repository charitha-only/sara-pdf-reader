/// Everything that can go wrong while opening a document.
///
/// A sealed hierarchy: adding a case makes every non-exhaustive `switch` a
/// compile error, so callers cannot silently miss a state.
///
/// Failures carry no user-facing text on purpose. Wording and translation
/// belong to the host application; the package only reports *what* happened
/// and what the user could do about it ([recovery]).
sealed class DocumentFailure {
  /// Creates a failure with an optional diagnostic [detail].
  const DocumentFailure({this.detail});

  /// Diagnostic detail for logs. **Never show this to users.**
  final String? detail;

  /// Stable identifier, safe to use as a telemetry key or in tests.
  String get code;

  /// What the user could do to get past this.
  RecoveryHint get recovery;

  @override
  String toString() => detail == null ? code : '$code ($detail)';
}

/// What the host application should offer the user after a failure.
enum RecoveryHint {
  /// Nothing to be done; inform and go back.
  none,

  /// The same operation may succeed if repeated.
  retry,

  /// Ask the user to pick the file again (access was lost).
  reselectFile,

  /// The document is password protected.
  enterPassword,

  /// Hand the file to another application.
  openElsewhere,
}

/// The format is not recognised, or is outside the supported set.
final class UnsupportedFormatFailure extends DocumentFailure {
  /// Creates the failure for an unrecognised [extension].
  const UnsupportedFormatFailure({required this.extension, super.detail});

  /// Lowercase extension without the dot, empty when the file had none.
  final String extension;

  @override
  String get code => 'unsupported_format';

  @override
  RecoveryHint get recovery => RecoveryHint.openElsewhere;
}

/// The container is damaged: truncated archive, invalid XML, missing main part.
final class CorruptDocumentFailure extends DocumentFailure {
  /// Creates the failure for a damaged container.
  const CorruptDocumentFailure({super.detail});

  @override
  String get code => 'corrupt_document';

  @override
  RecoveryHint get recovery => RecoveryHint.none;
}

/// Password protected, or an old binary OLE container.
final class EncryptedDocumentFailure extends DocumentFailure {
  /// Creates the failure for a protected or legacy binary document.
  const EncryptedDocumentFailure({super.detail});

  @override
  String get code => 'encrypted_document';

  @override
  RecoveryHint get recovery => RecoveryHint.enterPassword;
}

/// Larger than what can be processed safely on a phone.
final class TooLargeFailure extends DocumentFailure {
  /// Creates the failure for a document of [sizeBytes] exceeding [limitBytes].
  const TooLargeFailure({
    required this.sizeBytes,
    required this.limitBytes,
    super.detail,
  });

  /// Size that was rejected, in bytes.
  final int sizeBytes;

  /// Limit that was exceeded, in bytes.
  final int limitBytes;

  @override
  String get code => 'too_large';

  @override
  RecoveryHint get recovery => RecoveryHint.openElsewhere;
}

/// The archive looks hostile: zip bomb, path traversal, absurd entry count.
final class SuspiciousArchiveFailure extends DocumentFailure {
  /// Creates the failure, explaining why with [reason].
  const SuspiciousArchiveFailure({required this.reason, super.detail});

  /// Which check rejected the archive.
  final SuspiciousReason reason;

  @override
  String get code => 'suspicious_archive';

  @override
  RecoveryHint get recovery => RecoveryHint.none;
}

/// Why an archive was rejected.
enum SuspiciousReason {
  /// Declared uncompressed size is wildly out of proportion.
  zipBomb,

  /// An entry name tries to escape the extraction root.
  pathTraversal,

  /// More entries than any real document has.
  tooManyEntries,
}

/// The rendering engine crashed or did not finish in time.
///
/// On Android a dead WebView renderer process would otherwise take the whole
/// application down; the package intercepts that and reports it here.
final class RendererFailure extends DocumentFailure {
  /// Creates the failure; [timedOut] separates a hang from a crash.
  const RendererFailure({required this.timedOut, super.detail});

  /// `true` when the engine never reported completion within the timeout.
  final bool timedOut;

  @override
  String get code => timedOut ? 'renderer_timeout' : 'renderer_crashed';

  @override
  RecoveryHint get recovery => RecoveryHint.retry;
}

/// The file is gone, or its bytes could not be read.
final class NotFoundFailure extends DocumentFailure {
  /// Creates the failure for missing or unreadable bytes.
  const NotFoundFailure({super.detail});

  @override
  String get code => 'not_found';

  @override
  RecoveryHint get recovery => RecoveryHint.reselectFile;
}

/// An unforeseen error. Reaching this is a defect, not user error.
final class UnexpectedFailure extends DocumentFailure {
  /// Creates the catch-all failure.
  const UnexpectedFailure({super.detail});

  @override
  String get code => 'unexpected';

  @override
  RecoveryHint get recovery => RecoveryHint.retry;
}
