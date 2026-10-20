/// View PDF, Word, Excel and PowerPoint documents fully offline.
///
/// Everything renders on the device. The package bundles open-source
/// rendering engines and metric-compatible fonts; it never opens a network
/// connection, and the WebView that hosts the Office engines is locked down so
/// that a document cannot reach the network either.
///
/// ```dart
/// DocumentView(
///   source: DocumentSource.file('/path/to/report.xlsx'),
/// )
/// ```
///
/// For control over search and navigation, pass a [DocumentViewController].
library;

export 'src/document_format.dart'
    show ContainerKind, DocumentFormat, FidelityLevel, FormatFamily;
export 'src/document_source.dart' show DocumentSource;
export 'src/document_view.dart' show DocumentView;
export 'src/document_view_controller.dart'
    show DocumentInfo, DocumentViewController, DocumentViewStatus;
export 'src/failures.dart'
    show
        CorruptDocumentFailure,
        DocumentFailure,
        EncryptedDocumentFailure,
        NotFoundFailure,
        RecoveryHint,
        RendererFailure,
        SuspiciousArchiveFailure,
        SuspiciousReason,
        TooLargeFailure,
        UnexpectedFailure,
        UnsupportedFormatFailure;
export 'src/preflight.dart' show DocumentPreflight, PreflightReport;
