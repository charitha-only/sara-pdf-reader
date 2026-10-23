import 'package:flutter/foundation.dart';

import 'document_format.dart';
import 'failures.dart';

/// Drives a [DocumentView] and reports what it is showing.
///
/// Attach one when you need search, navigation, or the document outline for
/// your own chrome:
///
/// ```dart
/// final controller = DocumentViewController();
///
/// DocumentView(source: source, controller: controller);
///
/// // later
/// await controller.search('invoice');
/// await controller.goTo(2);
/// ```
///
/// The controller is a [ChangeNotifier]; listen to it to keep your UI in sync
/// with [status], [info] and [failure]. Dispose it with the widget that owns
/// it, not with the view.
class DocumentViewController extends ChangeNotifier {
  DocumentViewStatus _status = DocumentViewStatus.idle;
  DocumentInfo? _info;
  DocumentFailure? _failure;
  int _position = 0;
  double scrollFraction = 0;
  double horizontalOffset = 0;
  int searchIndex = -1;
  Future<void> Function(String, Map<String, Object?>)? _commandHandler;
  int _lastSearchHits = 0;

  Future<void> Function(String query)? _searchHandler;
  Future<void> Function(int index)? _gotoHandler;

  /// Current lifecycle state.
  DocumentViewStatus get status => _status;

  /// What the renderer reported once it finished. `null` until then.
  DocumentInfo? get info => _info;

  /// Why loading failed, when [status] is [DocumentViewStatus.failed].
  DocumentFailure? get failure => _failure;

  /// Index of the page, sheet or slide currently in view.
  int get position => _position;

  /// Number of matches from the last [search]. `0` when nothing is highlighted.
  int get searchHits => _lastSearchHits;

  /// Highlights [query] inside the document.
  ///
  /// Pass an empty string to clear highlighting. Matching is case-insensitive
  /// and locale-aware, so Turkish `İ`/`ı` behave correctly.
  Future<void> search(String query) async => _searchHandler?.call(query);

  /// Scrolls to the page, sheet or slide at [index].
  Future<void> goTo(int index) async => _gotoHandler?.call(index);

  Future<void> printDocument() async => _commandHandler?.call('print', {});

  Future<void> setViewMode(String mode) async => _commandHandler?.call('viewMode', {'mode': mode});
  Future<void> moveSearch(int direction) async => _commandHandler?.call('searchMove', {'direction': direction});
  Future<void> restoreScroll(double fraction, double horizontal) async => _commandHandler?.call('restoreViewport', {'fraction': fraction, 'horizontal': horizontal});
  void reportViewport(double fraction, double horizontal) {
    scrollFraction = fraction.clamp(0, 1);
    horizontalOffset = horizontal;
    notifyListeners();
  }
  void reportSearchIndex(int index) { searchIndex = index; notifyListeners(); }

  // ── wiring used by DocumentView ──────────────────────────────────────

  /// @nodoc
  @internal
  void attach({
    required Future<void> Function(String query) onSearch,
    required Future<void> Function(int index) onGoto,
    Future<void> Function(String, Map<String, Object?>)? onCommand,
  }) {
    _commandHandler = onCommand;
    _searchHandler = onSearch;
    _gotoHandler = onGoto;
  }

  /// @nodoc
  @internal
  void detach() {
    _commandHandler = null;
    _searchHandler = null;
    _gotoHandler = null;
  }

  /// @nodoc
  @internal
  void reportStatus(DocumentViewStatus status) {
    if (_status == status) {
      return;
    }
    _status = status;
    notifyListeners();
  }

  /// @nodoc
  @internal
  void reportReady(DocumentInfo info) {
    _info = info;
    _failure = null;
    _status = DocumentViewStatus.ready;
    notifyListeners();
  }

  /// @nodoc
  @internal
  void reportFailure(DocumentFailure failure) {
    _failure = failure;
    _status = DocumentViewStatus.failed;
    notifyListeners();
  }

  /// @nodoc
  @internal
  void reportPosition(int index) {
    if (_position == index) {
      return;
    }
    _position = index;
    notifyListeners();
  }

  /// @nodoc
  @internal
  void reportSearchHits(int hits) {
    if (_lastSearchHits == hits) {
      return;
    }
    _lastSearchHits = hits;
    notifyListeners();
  }
}

/// Lifecycle of a [DocumentView].
enum DocumentViewStatus {
  /// Nothing loaded yet.
  idle,

  /// Reading bytes, running preflight, preparing the workspace.
  preparing,

  /// The engine is rendering.
  rendering,

  /// Rendered and interactive.
  ready,

  /// Gave up; see [DocumentViewController.failure].
  failed,
}

/// What a rendered document turned out to contain.
@immutable
class DocumentInfo {
  /// Creates a description of a rendered document.
  const DocumentInfo({
    required this.format,
    required this.unitCount,
    required this.outline,
    required this.renderDuration,
    this.truncated = false,
  });

  /// Format resolved from the bytes.
  final DocumentFormat format;

  /// Pages, sheets or slides, depending on the format.
  final int unitCount;

  /// Headings, sheet names or slide titles — whatever the format offers.
  ///
  /// Empty when the format has no meaningful outline.
  final List<String> outline;

  /// How long the engine took. Useful for diagnostics and budgets.
  final Duration renderDuration;

  /// Whether the renderer stopped short of the whole document.
  ///
  /// Very large spreadsheets are cut off rather than exhausting memory; show
  /// the user a note when this is `true`.
  final bool truncated;
}
