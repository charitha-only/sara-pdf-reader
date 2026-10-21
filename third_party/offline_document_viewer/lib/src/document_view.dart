import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:pdfrx/pdfrx.dart';

import 'bridge/viewer_bridge.dart';
import 'document_format.dart';
import 'document_source.dart';
import 'document_view_controller.dart';
import 'failures.dart';
import 'preflight.dart';
import 'workspace/workspace.dart';

/// Renders a document, entirely on the device.
///
/// ```dart
/// DocumentView(source: DocumentSource.file(path))
/// ```
///
/// The widget deliberately ships **no chrome**: no app bar, no toolbar, no
/// page counter. It draws the document and nothing else, so it drops into any
/// design. Wire a [DocumentViewController] to build your own controls.
///
/// PDFs render natively through PDFium. Office formats render in a locked-down
/// [InAppWebView] that hosts bundled JavaScript engines — it has no network
/// permission, a strict content security policy, and every navigation outside
/// the document's private workspace is refused.
class DocumentView extends StatefulWidget {
  /// Creates a view that renders [source].
  const DocumentView({
    required this.source,
    this.controller,
    this.placeholderBuilder,
    this.errorBuilder,
    this.backgroundColor = const Color(0xFFFFFFFF),
    this.renderTimeout = const Duration(seconds: 20),
    this.onReady,
    this.onFailure,
    super.key,
  });

  /// Where the bytes come from.
  final DocumentSource source;

  /// Optional handle for search, navigation and status.
  ///
  /// Dispose it yourself; the view does not own it.
  final DocumentViewController? controller;

  /// Shown while the document is being prepared and rendered.
  ///
  /// Defaults to an empty box — a skeleton that matches your design beats any
  /// spinner this package could pick.
  final WidgetBuilder? placeholderBuilder;

  /// Shown when loading fails.
  ///
  /// Defaults to an empty box. The failure is also delivered to [onFailure]
  /// and [DocumentViewController.failure], where you can render it with your
  /// own wording and translations.
  final Widget Function(BuildContext context, DocumentFailure failure)?
      errorBuilder;

  /// Colour behind the document.
  ///
  /// White by default and worth keeping that way: documents assume a white
  /// page, and tinting it changes how their own colours read.
  final Color backgroundColor;

  /// How long the engine may take before the attempt is abandoned.
  ///
  /// Prevents a stuck engine from leaving the UI loading forever.
  final Duration renderTimeout;

  /// Called once the document is rendered and interactive.
  final void Function(DocumentInfo info)? onReady;

  /// Called when the document cannot be shown.
  final void Function(DocumentFailure failure)? onFailure;

  @override
  State<DocumentView> createState() => _DocumentViewState();
}

class _DocumentViewState extends State<DocumentView> {
  DocumentViewController? _ownController;
  DocumentViewController get _controller =>
      widget.controller ?? (_ownController ??= DocumentViewController());

  Workspace? _workspace;
  Uint8List? _pdfBytes;
  DocumentFailure? _failure;
  DocumentFormat? _format;
  bool _rendered = false;

  InAppWebViewController? _webView;
  Timer? _timeout;
  Stopwatch? _clock;

  @override
  void initState() {
    super.initState();
    _controller.attach(onSearch: _search, onGoto: _goTo, onCommand: _command);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_prepare());
    });
  }

  @override
  void didUpdateWidget(DocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _reset();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_prepare());
      });
    }
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _controller.detach();
    _ownController?.dispose();
    super.dispose();
  }

  void _reset() {
    _timeout?.cancel();
    _workspace = null;
    _pdfBytes = null;
    _failure = null;
    _rendered = false;
    _webView = null;
  }

  void _fail(DocumentFailure failure) {
    if (!mounted) {
      return;
    }
    _timeout?.cancel();
    setState(() => _failure = failure);
    _controller.reportFailure(failure);
    widget.onFailure?.call(failure);
  }

  Future<void> _prepare() async {
    _controller.reportStatus(DocumentViewStatus.preparing);
    _clock = Stopwatch()..start();

    final Uint8List bytes;
    try {
      bytes = await widget.source.load();
    } on Object catch (error) {
      return _fail(NotFoundFailure(detail: error.toString()));
    }

    // Untrusted input is vetted before any engine sees it.
    final Object report = await compute(_inspectDocument, (bytes, widget.source.name));
    if (!mounted) return;
    if (report is DocumentFailure) {
      return _fail(report);
    }
    final PreflightReport ok = report as PreflightReport;
    _format = ok.format;

    if (ok.format == DocumentFormat.pdf) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pdfBytes = bytes;
        _rendered = true;
      });
      _reportReady(unitCount: 0, outline: const <String>[]);
      return;
    }

    if (!WorkspaceBuilder.supports(ok.format)) {
      return _fail(
        UnsupportedFormatFailure(extension: ok.format.extensions.first),
      );
    }

    try {
      final Workspace workspace = await const WorkspaceBuilder()
          .build(bytes: bytes, format: ok.format);
      if (!mounted) {
        return;
      }
      setState(() => _workspace = workspace);
      _controller.reportStatus(DocumentViewStatus.rendering);
      _timeout = Timer(widget.renderTimeout, () {
        if (mounted && !_rendered) {
          _fail(const RendererFailure(timedOut: true));
        }
      });
    } on Object catch (error) {
      _fail(UnexpectedFailure(detail: error.toString()));
    }
  }

  void _reportReady({
    required int unitCount,
    required List<String> outline,
    bool truncated = false,
  }) {
    final DocumentInfo info = DocumentInfo(
      format: _format ?? DocumentFormat.pdf,
      unitCount: unitCount,
      outline: outline,
      renderDuration: _clock?.elapsed ?? Duration.zero,
      truncated: truncated,
    );
    _controller.reportReady(info);
    widget.onReady?.call(info);
  }

  Future<void> _onBridgeMessage(List<dynamic> args) async {
    if (args.isEmpty) {
      return;
    }
    final BridgeMessage message = BridgeMessage.decode(args.first as String);

    switch (message.type) {
      case 'needBytes':
        final Workspace? workspace = _workspace;
        final InAppWebViewController? controller = _webView;
        if (workspace != null && controller != null) {
          await ViewerBridge.pushBytes(controller, workspace.documentBytes);
        }

      case 'rendered':
        _timeout?.cancel();
        if (!mounted) {
          return;
        }
        setState(() => _rendered = true);
        _reportReady(
          unitCount: (message.payload['units'] as int?) ?? 0,
          outline: ((message.payload['outline'] as List<Object?>?) ??
                  const <Object?>[])
              .whereType<String>()
              .toList(),
          truncated: (message.payload['truncated'] as bool?) ?? false,
        );

      case 'located':
        _controller.reportPosition((message.payload['index'] as int?) ?? 0);

      case 'viewport':
        _controller.reportViewport((message.payload['fraction'] as num?)?.toDouble() ?? 0, (message.payload['horizontal'] as num?)?.toDouble() ?? 0);
      case 'searchIndex':
        _controller.reportSearchIndex((message.payload['index'] as int?) ?? -1);
      case 'searchResult':
        _controller.reportSearchHits((message.payload['hits'] as int?) ?? 0);

      case 'error':
        _fail(
          RendererFailure(
            timedOut: false,
            detail: '${message.payload['code']}: ${message.payload['detail']}',
          ),
        );
    }
  }

  Future<void> _command(String type, Map<String, Object?> payload) async {
    final controller = _webView;
    if (controller != null) await ViewerBridge.send(controller, BridgeMessage(type, payload));
  }

  Future<void> _search(String query) async {
    final InAppWebViewController? controller = _webView;
    if (controller == null) {
      return;
    }
    await ViewerBridge.send(
      controller,
      BridgeMessage('search', <String, Object?>{'query': query}),
    );
  }

  Future<void> _goTo(int index) async {
    final InAppWebViewController? controller = _webView;
    if (controller == null) {
      return;
    }
    await ViewerBridge.send(
      controller,
      BridgeMessage('goto', <String, Object?>{'index': index}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DocumentFailure? failure = _failure;
    if (failure != null) {
      return widget.errorBuilder?.call(context, failure) ??
          const SizedBox.shrink();
    }

    final Uint8List? pdf = _pdfBytes;
    if (pdf != null) {
      return ColoredBox(
        color: widget.backgroundColor,
        child: PdfViewer.data(
          pdf,
          sourceName: widget.source.name,
          params: PdfViewerParams(
            backgroundColor: widget.backgroundColor,
            onPageChanged: (int? page) {
              if (page != null) {
                _controller.reportPosition(page);
              }
            },
          ),
        ),
      );
    }

    final Workspace? workspace = _workspace;
    if (workspace == null) {
      return _placeholder(context);
    }

    // PAGEFLOW PATCH: keep the Android WebView mounted at its real viewport
    // while loading. Reparenting after readiness recreates the platform view.
    return Stack(children: <Widget>[
      Positioned.fill(child: _buildWebView(workspace)),
      if (!_rendered) Positioned.fill(child: _placeholder(context)),
    ]);
  }

  Widget _placeholder(BuildContext context) =>
      widget.placeholderBuilder?.call(context) ??
      ColoredBox(color: widget.backgroundColor);

  Widget _buildWebView(Workspace workspace) {
    return ColoredBox(
      color: widget.backgroundColor,
      child: SizedBox.expand(
        child: InAppWebView(
          initialSettings: ViewerBridge.settingsFor(workspace),
          onWebViewCreated: (InAppWebViewController controller) {
            _webView = controller;
            controller.addJavaScriptHandler(
              handlerName: ViewerBridge.channelName,
              callback: _onBridgeMessage,
            );
            unawaited(ViewerBridge.load(controller, workspace));
          },
          shouldOverrideUrlLoading: (
            InAppWebViewController _,
            NavigationAction action,
          ) async =>
              ViewerBridge.decidePolicy(action.request.url),
          // On Android an unhandled renderer-process death takes the whole
          // application with it. Intercepting turns it into a recoverable
          // failure instead.
          onRenderProcessGone: (
            InAppWebViewController _,
            RenderProcessGoneDetail detail,
          ) async {
            _fail(const RendererFailure(timedOut: false));
          },
        ),
      ),
    );
  }
}

Object _inspectDocument((Uint8List, String) request) => DocumentPreflight.inspect(bytes: request.$1, fileName: request.$2);
