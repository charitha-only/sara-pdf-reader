import 'dart:convert';
import 'dart:math' as math;

import 'text_box.dart';
import 'pdf_forms.dart';

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;

/// Native PDF handles and callbacks stay on pdfrx's single worker isolate.
/// The UI receives only immutable descriptions and serialized PDF bytes.
class PdfiumObjectEditor {
  PdfiumObjectEditor._(this._id, this._state);
  final int _id;
  _EditorState _state;
  Future<void> _queue = Future<void>.value();
  bool _disposed = false;

  /// Produces an app-owned unlocked copy using a password supplied by the user.
  static Future<Uint8List> unlock(Uint8List bytes, String password) async {
    await pdfrx.pdfrxFlutterInitialize();
    return pdfrx.PdfrxEntryFunctions.instance.compute(_unlockPdf, (
      bytes: bytes,
      password: password,
    ));
  }

  static Future<PdfiumObjectEditor> open(
    String path, {
    int historyLimit = 20,
  }) async {
    if (historyLimit < 1) {
      throw ArgumentError('History limit must be positive.');
    }
    final bytes = await File(path).readAsBytes();
    await pdfrx.pdfrxFlutterInitialize();
    final created = await pdfrx.PdfrxEntryFunctions.instance.compute(
      _createSession,
      (bytes: bytes, limit: historyLimit),
    );
    return PdfiumObjectEditor._(created.id, created.state);
  }

  Uint8List get currentBytes => Uint8List.fromList(_state.bytes);
  Future<List<PdfTapTarget>> tapTargets(int page) async =>
      (await _execute('tapTargets', {'page': page}))! as List<PdfTapTarget>;
  bool get canUndo => !_disposed && _state.canUndo;
  bool get canRedo => !_disposed && _state.canRedo;
  int get pageCount => _state.pages;

  Future<List<PdfFormField>> formFields() async =>
      (await _execute('formFields'))! as List<PdfFormField>;
  Future<void> fillFormField(
    int page,
    int index, {
    String? text,
    bool? checked,
  }) async {
    await _execute('fillForm', {
      'page': page,
      'index': index,
      'text': ?text,
      'checked': ?checked,
    });
  }

  Future<void> deletePages(List<int> pages) async {
    await _execute('deletePages', {'pages': pages});
  }

  Future<void> cropPage(
    int page, {
    required double left,
    required double bottom,
    required double right,
    required double top,
  }) async {
    await _execute('cropPage', {
      'page': page,
      'left': left,
      'bottom': bottom,
      'right': right,
      'top': top,
    });
  }

  Future<void> insertPdf(int beforePage, Uint8List bytes) async {
    await _execute('insertPdf', {'before': beforePage, 'pdf': bytes});
  }

  Future<List<Uint8List>> splitPages(List<List<int>> groups) async =>
      (await _execute('splitPages', {'groups': groups}))! as List<Uint8List>;
  Future<void> replaceWithSanitizedPdf(Uint8List bytes) async {
    await _execute('sanitized', {'pdf': bytes});
  }

  Future<Object?> _execute(
    String command, [
    Map<String, Object> data = const {},
  ]) {
    final next = _queue.then((_) async {
      if (_disposed) throw StateError('This PDF editor is closed.');
      final result = await pdfrx.PdfrxEntryFunctions.instance.compute(
        _dispatchSession,
        (id: _id, command: command, data: data),
      );
      _state = result.state;
      return result.value;
    });
    _queue = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  Future<List<PdfObjectInfo>> listObjects(int page) async =>
      (await _execute('list', {'page': page}))! as List<PdfObjectInfo>;
  Future<({double width, double height})> pageSize(int page) async =>
      (await _execute('size', {'page': page}))!
          as ({double width, double height});

  Future<void> upsertTextBox(
    int page,
    PdfTextBox box, {
    int? objectIndex,
  }) async {
    final expected = _state.revision;
    final pdf = await TextBoxRenderer.pdf(box);
    await _execute('box', {
      'page': page,
      'box': box.toJson(),
      'pdf': pdf,
      'index': ?objectIndex,
      'revision': expected,
    });
  }

  Future<int> replaceTextMatches(int page, String find, String replace) =>
      _replacePrepared(find, replace, onlyPage: page);
  Future<int> replaceTextMatchesEverywhere(String find, String replace) =>
      _replacePrepared(find, replace);
  Future<int> _replacePrepared(
    String find,
    String replace, {
    int? onlyPage,
  }) async {
    if (find.isEmpty) throw ArgumentError('Search text cannot be empty.');
    if (find == replace) return 0;
    final prepared = <Map<String, Object>>[];
    final expected = _state.revision;
    for (var page = onlyPage ?? 1; page <= (onlyPage ?? pageCount); page++) {
      for (final info in await listObjects(page)) {
        final box = info.textBox;
        if (box == null || !box.text.contains(find)) continue;
        final replacement = box.copyWith(
          text: box.text.replaceAll(find, replace),
        );
        prepared.add({
          'page': page,
          'index': info.index,
          'box': replacement.toJson(),
          'pdf': await TextBoxRenderer.pdf(replacement),
        });
      }
    }
    return (await _execute('replacePrepared', {
          'find': find,
          'replace': replace,
          'boxes': prepared,
          'page': ?onlyPage,
          'revision': expected,
        }))!
        as int;
  }

  Future<Uint8List> scanSourceBytes(int page) async =>
      (await _execute('scanSource', {'page': page}))! as Uint8List;

  Future<void> replaceScannedPage(
    int page,
    Uint8List backgroundPdf,
    PdfTextBox box, {
    int rotation = 0,
  }) async {
    final expected = _state.revision;
    final textPdf = await TextBoxRenderer.pdf(box);
    await _execute('scan', {
      'page': page,
      'background': backgroundPdf,
      'rotation': rotation,
      'box': box.toJson(),
      'pdf': textPdf,
      'revision': expected,
    });
  }

  Future<void> transformObject(
    int page,
    int index, {
    required double left,
    required double bottom,
    required double width,
    required double height,
  }) async {
    final info = (await listObjects(page))
        .where((o) => o.index == index)
        .firstOrNull;
    if (info?.textBox != null) {
      await upsertTextBox(
        page,
        info!.textBox!.copyWith(
          left: left,
          bottom: bottom,
          width: info.textBox!.rotation.isOdd ? height : width,
          height: info.textBox!.rotation.isOdd ? width : height,
        ),
        objectIndex: index,
      );
      return;
    }
    await _execute('transform', {
      'page': page,
      'index': index,
      'left': left,
      'bottom': bottom,
      'width': width,
      'height': height,
    });
  }

  Future<void> deleteObject(int page, int index) async {
    await _execute('delete', {'page': page, 'index': index});
  }

  Future<void> addTextObject(
    int page, {
    required String text,
    required String fontName,
    required double fontSize,
    required double left,
    required double bottom,
    required int red,
    required int green,
    required int blue,
    required String alignment,
  }) async {
    await _execute('add', {
      'page': page,
      'text': text,
      'font': fontName,
      'size': fontSize,
      'left': left,
      'bottom': bottom,
      'red': red,
      'green': green,
      'blue': blue,
      'alignment': alignment,
    });
  }

  Future<void> undo() async {
    await _execute('undo');
  }

  Future<void> redo() async {
    await _execute('redo');
  }

  Future<void> saveTo(String path) async {
    await _execute('save', {'path': path});
  }

  Future<void> dispose() {
    final next = _queue.then((_) async {
      if (_disposed) return;
      _disposed = true;
      await pdfrx.PdfrxEntryFunctions.instance.compute(_disposeSession, _id);
      _state = _EditorState(Uint8List(0), 0, false, false);
    });
    _queue = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }
}

class _EditorState {
  _EditorState(
    this.bytes,
    this.pages,
    this.canUndo,
    this.canRedo, [
    this.revision = 0,
  ]);
  final Uint8List bytes;
  final int pages;
  final int revision;
  final bool canUndo, canRedo;
}

class _EditorResult {
  _EditorResult(this.state, this.value);
  final _EditorState state;
  final Object? value;
}

// These globals are accessed exclusively inside pdfrx's worker isolate.
final _sessions = <int, _PdfiumSession>{};
Future<Uint8List> _unlockPdf(
  ({Uint8List bytes, String password}) request,
) async {
  final session = _PdfiumSession._(
    pdfium.getPdfium(modulePath: pdfrx.Pdfrx.pdfiumModulePath),
    1,
  );
  try {
    await session._loadBytes(request.bytes, password: request.password);
    return session._saveBytes(flags: pdfium.FPDF_REMOVE_SECURITY);
  } finally {
    await session.dispose();
  }
}

int _nextSession = 0;
_EditorState _stateOf(_PdfiumSession session) => _EditorState(
  session.currentBytes,
  session.pageCount,
  session.canUndo,
  session.canRedo,
  session._revision,
);

Future<({int id, _EditorState state})> _createSession(
  ({Uint8List bytes, int limit}) request,
) async {
  final session = _PdfiumSession._(
    pdfium.getPdfium(modulePath: pdfrx.Pdfrx.pdfiumModulePath),
    request.limit,
  );
  try {
    await session._loadBytes(request.bytes);
    final id = ++_nextSession;
    _sessions[id] = session;
    return (id: id, state: _stateOf(session));
  } catch (_) {
    await session.dispose();
    rethrow;
  }
}

Future<void> _disposeSession(int id) async {
  await _sessions.remove(id)?.dispose();
}

Future<_EditorResult> _dispatchSession(
  ({int id, String command, Map<String, Object> data}) request,
) async {
  final s = _sessions[request.id];
  if (s == null) throw StateError('This PDF editor is closed.');
  final d = request.data;
  if (d.containsKey('revision') && d['revision'] != s._revision) {
    throw StateError(
      'The PDF changed during text preparation. Refresh and try again.',
    );
  }
  Object? value;
  switch (request.command) {
    case 'tapTargets':
      value = s._tapTargets(d['page']! as int);
    case 'deletePages':
      await s._transaction(() async {
        final pages = (d['pages']! as List).cast<int>().toSet().toList()
          ..sort();
        if (pages.isEmpty ||
            pages.any((p) => p < 1 || p > s.pageCount) ||
            pages.length >= s.pageCount) {
          throw ArgumentError('Keep at least one PDF page.');
        }
        final before = s._snapshot();
        for (final number in pages.reversed) {
          s._api.FPDFPage_Delete(s._document, number - 1);
        }
        s._pageCount = s._api.FPDF_GetPageCount(s._document);
        s._commit(before);
      });
    case 'cropPage':
      await s._transaction(() async {
        final before = s._snapshot();
        final page = s._loadPage(d['page']! as int);
        try {
          final l = d['left']! as double,
              b = d['bottom']! as double,
              r = d['right']! as double,
              t = d['top']! as double;
          if (![l, b, r, t].every((v) => v.isFinite) ||
              l < 0 ||
              b < 0 ||
              r <= l ||
              t <= b ||
              r > s._api.FPDF_GetPageWidthF(page) ||
              t > s._api.FPDF_GetPageHeightF(page)) {
            throw ArgumentError('Enter a valid crop inside the page.');
          }
          s._api.FPDFPage_SetCropBox(page, l, b, r, t);
          s._generate(page);
          s._commit(before);
        } finally {
          s._api.FPDF_ClosePage(page);
        }
      });
    case 'insertPdf':
      await s._transaction(
        () async => s._insertPdf(d['before']! as int, d['pdf']! as Uint8List),
      );
    case 'splitPages':
      value = s._splitPages(
        (d['groups']! as List).map((g) => (g as List).cast<int>()).toList(),
      );
    case 'sanitized':
      await s._transaction(() async {
        final before = s._snapshot();
        await s._loadBytes(d['pdf']! as Uint8List);
        s._commit(before);
      });
    case 'formFields':
      final env = PdfFormEnvironment(s._api, s._document);
      try {
        value = env.fields();
      } finally {
        env.dispose();
      }
    case 'fillForm':
      await s._transaction(() async {
        final before = s._snapshot();
        final env = PdfFormEnvironment(s._api, s._document);
        try {
          env.fill(
            d['page']! as int,
            d['index']! as int,
            text: d['text'] as String?,
            checked: d['checked'] as bool?,
          );
        } finally {
          env.dispose();
        }
        s._commit(before);
      });
    case 'size':
      final page = s._loadPage(d['page']! as int);
      try {
        value = (
          width: s._api.FPDF_GetPageWidthF(page),
          height: s._api.FPDF_GetPageHeightF(page),
        );
      } finally {
        s._api.FPDF_ClosePage(page);
      }
    case 'box':
      await s._transaction(() async => s._upsertBox(d));
    case 'scanSource':
      value = await s._scanSource(d['page']! as int);
    case 'scan':
      await s._transaction(() async => s._scanPage(d));
    case 'replacePrepared':
      value = await s._transaction(() async => s._replacePrepared(d));
    case 'list':
      value = s._listObjects(d['page']! as int);
    case 'replace':
      value = await s.replaceTextMatches(
        d['page']! as int,
        d['find']! as String,
        d['replace']! as String,
      );
    case 'replaceAll':
      value = await s.replaceTextMatchesEverywhere(
        d['find']! as String,
        d['replace']! as String,
      );
    case 'transform':
      await s.transformObject(
        d['page']! as int,
        d['index']! as int,
        left: d['left']! as double,
        bottom: d['bottom']! as double,
        width: d['width']! as double,
        height: d['height']! as double,
      );
    case 'delete':
      await s.deleteObject(d['page']! as int, d['index']! as int);
    case 'add':
      await s.addTextObject(
        d['page']! as int,
        text: d['text']! as String,
        fontName: d['font']! as String,
        fontSize: d['size']! as double,
        left: d['left']! as double,
        bottom: d['bottom']! as double,
        red: d['red']! as int,
        green: d['green']! as int,
        blue: d['blue']! as int,
        alignment: d['alignment']! as String,
      );
    case 'undo':
      await s.undo();
    case 'redo':
      await s.redo();
    case 'save':
      await s.saveTo(d['path']! as String);
    default:
      throw ArgumentError('Unknown PDF editing action.');
  }
  return _EditorResult(_stateOf(s), value);
}

/// Low-level, local PDF object editing session backed by the app's PDFium.
/// Each successful operation records a complete PDF snapshot for undo/redo.
class _PdfiumSession {
  bool _disposed = false;
  int _revision = 0;
  bool _batch = false;
  int _pageCount = 0;
  _PdfiumSession._(this._api, this._historyLimit);

  final pdfium.PDFium _api;
  final int _historyLimit;
  pdfium.FPDF_DOCUMENT _document = ffi.nullptr;
  ffi.Pointer<ffi.Uint8> _documentMemory = ffi.nullptr;
  Uint8List _currentBytes = Uint8List(0);
  final List<Uint8List> _undo = [];
  final List<Uint8List> _redo = [];

  Uint8List get currentBytes => Uint8List.fromList(_currentBytes);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get pageCount => _pageCount;

  Future<void> _loadBytes(Uint8List bytes, {String? password}) async {
    if (bytes.isEmpty) throw const FormatException('The PDF is empty.');
    final memory = calloc<ffi.Uint8>(bytes.length);
    memory.asTypedList(bytes.length).setAll(0, bytes);
    final encoded = password?.toNativeUtf8(allocator: calloc);
    late final pdfium.FPDF_DOCUMENT document;
    try {
      document = _api.FPDF_LoadMemDocument(
        memory.cast(),
        bytes.length,
        encoded?.cast<ffi.Char>() ?? ffi.nullptr,
      );
    } finally {
      if (encoded != null) calloc.free(encoded);
    }
    if (document == ffi.nullptr) {
      calloc.free(memory);
      throw const FormatException(
        'Could not open PDF. It may be damaged or password-protected.',
      );
    }
    if (_api.FPDF_GetPageCount(document) < 1) {
      _api.FPDF_CloseDocument(document);
      calloc.free(memory);
      throw const FormatException('This PDF has no readable pages.');
    }
    if (_document != ffi.nullptr) _api.FPDF_CloseDocument(_document);
    if (_documentMemory != ffi.nullptr) calloc.free(_documentMemory);
    _document = document;
    _documentMemory = memory;
    _pageCount = _api.FPDF_GetPageCount(document);
    _currentBytes = Uint8List.fromList(bytes);
  }

  Future<T> _locked<T>(Future<T> Function() action) {
    if (_disposed) throw StateError('This PDF editor is closed.');
    return action();
  }

  Future<T> _transaction<T>(Future<T> Function() action) => _locked(() async {
    final before = _snapshot();
    final undo = List<Uint8List>.of(_undo);
    final redo = List<Uint8List>.of(_redo);
    try {
      final result = await action();
      _revision++;
      return result;
    } catch (_) {
      await _loadBytes(before);
      _undo
        ..clear()
        ..addAll(undo);
      _redo
        ..clear()
        ..addAll(redo);
      rethrow;
    }
  });

  Future<List<PdfObjectInfo>> listObjects(int pageNumber) =>
      _locked(() async => _listObjects(pageNumber));
  Future<int> replaceTextMatches(int pageNumber, String find, String replace) =>
      _transaction(() => _replaceTextMatches(pageNumber, find, replace));
  Future<int> replaceTextMatchesEverywhere(String find, String replace) =>
      _transaction(() => _replaceTextMatchesEverywhere(find, replace));
  Future<void> transformObject(
    int pageNumber,
    int objectIndex, {
    required double left,
    required double bottom,
    required double width,
    required double height,
  }) => _transaction(
    () => _transformObject(
      pageNumber,
      objectIndex,
      left: left,
      bottom: bottom,
      width: width,
      height: height,
    ),
  );
  Future<void> deleteObject(int pageNumber, int objectIndex) =>
      _transaction(() => _deleteObject(pageNumber, objectIndex));
  Future<void> addTextObject(
    int pageNumber, {
    required String text,
    required String fontName,
    required double fontSize,
    required double left,
    required double bottom,
    required int red,
    required int green,
    required int blue,
    required String alignment,
  }) => _transaction(
    () => _addTextObject(
      pageNumber,
      text: text,
      fontName: fontName,
      fontSize: fontSize,
      left: left,
      bottom: bottom,
      red: red,
      green: green,
      blue: blue,
      alignment: alignment,
    ),
  );
  Future<void> undo() => _transaction(_undoEdit);
  Future<void> redo() => _transaction(_redoEdit);

  List<PdfObjectInfo> _listObjects(int pageNumber) {
    final page = _loadPage(pageNumber);
    final textPage = _api.FPDFText_LoadPage(page);
    try {
      final result = <PdfObjectInfo>[];
      final count = _api.FPDFPage_CountObjects(page);
      for (var index = 0; index < count; index++) {
        final object = _api.FPDFPage_GetObject(page, index);
        final type = _api.FPDFPageObj_GetType(object);
        final left = calloc<ffi.Float>();
        final bottom = calloc<ffi.Float>();
        final right = calloc<ffi.Float>();
        final top = calloc<ffi.Float>();
        try {
          if (_api.FPDFPageObj_GetBounds(object, left, bottom, right, top) ==
              0) {
            continue;
          }
          final box = _boxOf(object);
          result.add(
            PdfObjectInfo(
              index: index,
              type: type,
              left: box?.left ?? left.value,
              bottom: box?.bottom ?? bottom.value,
              right: box == null
                  ? right.value
                  : box.left + (box.rotation.isOdd ? box.height : box.width),
              top: box == null
                  ? top.value
                  : box.bottom + (box.rotation.isOdd ? box.width : box.height),
              textBox: box,
              text: type == pdfium.FPDF_PAGEOBJ_TEXT && textPage != ffi.nullptr
                  ? _textOf(object, textPage)
                  : '',
              fontSize: _fontSize(object, type),
              color: _colorOf(object),
            ),
          );
        } finally {
          calloc.free(left);
          calloc.free(bottom);
          calloc.free(right);
          calloc.free(top);
        }
      }
      return result;
    } finally {
      if (textPage != ffi.nullptr) _api.FPDFText_ClosePage(textPage);
      _api.FPDF_ClosePage(page);
    }
  }

  List<PdfTapTarget> _tapTargets(int number) {
    final objects = _listObjects(number), page = _loadPage(number);
    final x = calloc<ffi.Int>(), y = calloc<ffi.Int>();
    try {
      final targets = <PdfTapTarget>[];
      for (final object in objects) {
        final xs = <double>[], ys = <double>[];
        for (final point in [
          (object.left, object.bottom),
          (object.right, object.bottom),
          (object.left, object.top),
          (object.right, object.top),
        ]) {
          if (_api.FPDF_PageToDevice(
                page,
                0,
                0,
                100000,
                100000,
                0,
                point.$1,
                point.$2,
                x,
                y,
              ) ==
              0) {
            continue;
          }
          xs.add(x.value / 100000);
          ys.add(y.value / 100000);
        }
        if (xs.length != 4) continue;
        final l = xs.reduce(math.min).clamp(0.0, 1.0),
            r = xs.reduce(math.max).clamp(0.0, 1.0),
            t = ys.reduce(math.min).clamp(0.0, 1.0),
            b = ys.reduce(math.max).clamp(0.0, 1.0);
        if (r > l && b > t) targets.add(PdfTapTarget(object, l, t, r, b));
      }
      return targets;
    } finally {
      calloc.free(x);
      calloc.free(y);
      _api.FPDF_ClosePage(page);
    }
  }

  Future<int> _replaceTextMatches(
    int pageNumber,
    String find,
    String replace,
  ) async {
    if (find.isEmpty) throw ArgumentError('Search text cannot be empty.');
    if (find == replace) return 0;
    final before = _batch ? Uint8List(0) : _snapshot();
    final page = _loadPage(pageNumber);
    var changed = 0;
    try {
      final textPage = _api.FPDFText_LoadPage(page);
      if (textPage == ffi.nullptr) {
        throw StateError('Could not read page text.');
      }
      try {
        final count = _api.FPDFPage_CountObjects(page);
        for (var index = 0; index < count; index++) {
          final object = _api.FPDFPage_GetObject(page, index);
          if (_api.FPDFPageObj_GetType(object) != pdfium.FPDF_PAGEOBJ_TEXT) {
            continue;
          }
          final size = _api.FPDFTextObj_GetText(
            object,
            textPage,
            ffi.nullptr,
            0,
          );
          if (size < 2) continue;
          final buffer = calloc<pdfium.FPDF_WCHAR>(size ~/ 2);
          try {
            if (_api.FPDFTextObj_GetText(object, textPage, buffer, size) == 0) {
              continue;
            }
            final text = String.fromCharCodes(
              buffer
                  .cast<ffi.Uint16>()
                  .asTypedList(size ~/ 2)
                  .takeWhile((unit) => unit != 0),
            );
            if (!text.contains(find)) continue;
            final replacement = text.replaceAll(find, replace);
            final wide = calloc<pdfium.FPDF_WCHAR>(
              replacement.codeUnits.length + 1,
            );
            try {
              wide.cast<ffi.Uint16>().asTypedList(
                  replacement.codeUnits.length + 1,
                )
                ..setRange(
                  0,
                  replacement.codeUnits.length,
                  replacement.codeUnits,
                )
                ..[replacement.codeUnits.length] = 0;
              if (_api.FPDFText_SetText(object, wide) == 0) {
                throw StateError(
                  'The PDF font cannot encode this replacement.',
                );
              }
              changed++;
            } finally {
              calloc.free(wide);
            }
          } finally {
            calloc.free(buffer);
          }
        }
      } finally {
        _api.FPDFText_ClosePage(textPage);
      }
      if (changed > 0) {
        _generate(page);
        _commit(before);
      }
      return changed;
    } finally {
      _api.FPDF_ClosePage(page);
    }
  }

  Future<int> _replaceTextMatchesEverywhere(String find, String replace) async {
    final before = _snapshot();
    var changed = 0;
    _batch = true;
    try {
      for (var page = 1; page <= pageCount; page++) {
        changed += await _replaceTextMatches(page, find, replace);
      }
    } finally {
      _batch = false;
    }
    if (changed > 0) _commit(before);
    return changed;
  }

  Future<void> _transformObject(
    int pageNumber,
    int objectIndex, {
    required double left,
    required double bottom,
    required double width,
    required double height,
  }) async {
    if (![left, bottom, width, height].every((v) => v.isFinite) ||
        width <= 0 ||
        height <= 0) {
      throw ArgumentError('Enter finite positions and positive dimensions.');
    }
    final before = _snapshot();
    final page = _loadPage(pageNumber);
    try {
      final object = _objectAt(page, objectIndex);
      final oldLeft = calloc<ffi.Float>();
      final oldBottom = calloc<ffi.Float>();
      final oldRight = calloc<ffi.Float>();
      final oldTop = calloc<ffi.Float>();
      try {
        if (_api.FPDFPageObj_GetBounds(
              object,
              oldLeft,
              oldBottom,
              oldRight,
              oldTop,
            ) ==
            0) {
          throw StateError('Could not read object bounds.');
        }
        final oldWidth = oldRight.value - oldLeft.value;
        final oldHeight = oldTop.value - oldBottom.value;
        if (oldWidth.abs() < .001 || oldHeight.abs() < .001) {
          throw StateError('This PDF object cannot be resized.');
        }
        _api.FPDFPageObj_Transform(
          object,
          width / oldWidth,
          0,
          0,
          height / oldHeight,
          left - oldLeft.value * width / oldWidth,
          bottom - oldBottom.value * height / oldHeight,
        );
        _generate(page);
        _commit(before);
      } finally {
        calloc.free(oldLeft);
        calloc.free(oldBottom);
        calloc.free(oldRight);
        calloc.free(oldTop);
      }
    } finally {
      _api.FPDF_ClosePage(page);
    }
  }

  Future<void> _deleteObject(int pageNumber, int objectIndex) async {
    final before = _snapshot();
    final page = _loadPage(pageNumber);
    try {
      final object = _objectAt(page, objectIndex);
      if (_api.FPDFPage_RemoveObject(page, object) == 0) {
        throw StateError('PDFium could not remove this object.');
      }
      _api.FPDFPageObj_Destroy(object);
      _generate(page);
      _commit(before);
    } finally {
      _api.FPDF_ClosePage(page);
    }
  }

  Future<void> _addTextObject(
    int pageNumber, {
    required String text,
    required String fontName,
    required double fontSize,
    required double left,
    required double bottom,
    required int red,
    required int green,
    required int blue,
    required String alignment,
  }) async {
    if (text.isEmpty ||
        ![fontSize, left, bottom].every((v) => v.isFinite) ||
        fontSize <= 0) {
      throw ArgumentError(
        'Enter text, finite positions and a positive font size.',
      );
    }
    if (text.codeUnits.any((u) => u > 255 || u < 32)) {
      throw ArgumentError(
        'Use single-line Latin text here. Other scripts need an embedded font.',
      );
    }
    final before = _snapshot();
    final page = _loadPage(pageNumber);
    final font = fontName.toNativeUtf8();
    final wide = calloc<pdfium.FPDF_WCHAR>(text.codeUnits.length + 1);
    pdfium.FPDF_PAGEOBJECT object = ffi.nullptr;
    var inserted = false;
    try {
      wide.cast<ffi.Uint16>().asTypedList(text.codeUnits.length + 1)
        ..setRange(0, text.codeUnits.length, text.codeUnits)
        ..[text.codeUnits.length] = 0;
      object = _api.FPDFPageObj_NewTextObj(_document, font.cast(), fontSize);
      if (object == ffi.nullptr || _api.FPDFText_SetText(object, wide) == 0) {
        throw StateError('PDFium could not create this text object.');
      }
      _api.FPDFPageObj_SetFillColor(object, red, green, blue, 255);
      final objLeft = calloc<ffi.Float>();
      final objBottom = calloc<ffi.Float>();
      final objRight = calloc<ffi.Float>();
      final objTop = calloc<ffi.Float>();
      try {
        if (_api.FPDFPageObj_GetBounds(
              object,
              objLeft,
              objBottom,
              objRight,
              objTop,
            ) ==
            0) {
          throw StateError('Could not measure the new text object.');
        }
        final textWidth = objRight.value - objLeft.value;
        final alignedLeft = switch (alignment) {
          'center' => left - textWidth / 2,
          'right' => left - textWidth,
          _ => left,
        };
        _api.FPDFPageObj_Transform(
          object,
          1,
          0,
          0,
          1,
          alignedLeft - objLeft.value,
          bottom - objBottom.value,
        );
      } finally {
        calloc.free(objLeft);
        calloc.free(objBottom);
        calloc.free(objRight);
        calloc.free(objTop);
      }
      if (_api.FPDFPage_InsertObject(page, object) == 0) {
        throw StateError('Could not add the text object to this page.');
      }
      inserted = true;
      _generate(page);
      _commit(before);
    } finally {
      if (!inserted && object != ffi.nullptr) _api.FPDFPageObj_Destroy(object);
      calloc.free(wide);
      calloc.free(font);
      _api.FPDF_ClosePage(page);
    }
  }

  Future<void> _undoEdit() async {
    if (_undo.isEmpty) return;
    _redo.add(_snapshot());
    await _loadBytes(_undo.removeLast());
  }

  Future<void> _redoEdit() async {
    if (_redo.isEmpty) return;
    _undo.add(_snapshot());
    await _loadBytes(_redo.removeLast());
  }

  Future<void> saveTo(String path) async {
    final bytes = await _locked(() async => _saveBytes());
    final temporary = File(
      '$path.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  String _textOf(pdfium.FPDF_PAGEOBJECT object, pdfium.FPDF_TEXTPAGE textPage) {
    final length = _api.FPDFTextObj_GetText(object, textPage, ffi.nullptr, 0);
    if (length < 2 || length > 1000000) return '';
    final buffer = calloc<ffi.Uint16>(length ~/ 2);
    try {
      if (_api.FPDFTextObj_GetText(object, textPage, buffer.cast(), length) ==
          0) {
        return '';
      }
      return String.fromCharCodes(
        buffer.asTypedList(length ~/ 2).takeWhile((c) => c != 0),
      );
    } finally {
      calloc.free(buffer);
    }
  }

  double _fontSize(pdfium.FPDF_PAGEOBJECT object, int type) {
    if (type != pdfium.FPDF_PAGEOBJ_TEXT) return 18;
    final size = calloc<ffi.Float>();
    try {
      return _api.FPDFTextObj_GetFontSize(object, size) != 0 ? size.value : 18;
    } finally {
      calloc.free(size);
    }
  }

  int _colorOf(pdfium.FPDF_PAGEOBJECT object) {
    final colors = calloc<ffi.UnsignedInt>(4);
    try {
      if (_api.FPDFPageObj_GetFillColor(
            object,
            colors,
            colors + 1,
            colors + 2,
            colors + 3,
          ) ==
          0) {
        return 0xff111111;
      }
      return 0xff000000 | colors[0] << 16 | colors[1] << 8 | colors[2];
    } finally {
      calloc.free(colors);
    }
  }

  PdfTextBox? _boxOf(pdfium.FPDF_PAGEOBJECT object) {
    final key = 'PageflowBox'.toNativeUtf8();
    final size = calloc<ffi.UnsignedLong>();
    try {
      for (var i = 0; i < _api.FPDFPageObj_CountMarks(object); i++) {
        final mark = _api.FPDFPageObj_GetMark(object, i);
        if (_api.FPDFPageObjMark_GetParamBlobValue(
                  mark,
                  key.cast(),
                  ffi.nullptr,
                  0,
                  size,
                ) ==
                0 ||
            size.value < 1 ||
            size.value > 32768) {
          continue;
        }
        final buffer = calloc<ffi.Uint8>(size.value);
        try {
          if (_api.FPDFPageObjMark_GetParamBlobValue(
                mark,
                key.cast(),
                buffer.cast(),
                size.value,
                size,
              ) ==
              0) {
            continue;
          }
          return PdfTextBox.fromJson(
            jsonDecode(utf8.decode(buffer.asTypedList(size.value)))
                as Map<String, dynamic>,
          );
        } catch (_) {
          continue;
        } finally {
          calloc.free(buffer);
        }
      }
      return null;
    } finally {
      calloc.free(key);
      calloc.free(size);
    }
  }

  void _upsertBox(Map<String, Object> data) {
    final before = _batch ? Uint8List(0) : _snapshot();
    final box = PdfTextBox.fromJson(
      Map<String, dynamic>.from(data['box']! as Map),
    );
    final bytes = data['pdf']! as Uint8List;
    final memory = calloc<ffi.Uint8>(bytes.length)
      ..asTypedList(bytes.length).setAll(0, bytes);
    final source = _api.FPDF_LoadMemDocument(
      memory.cast(),
      bytes.length,
      ffi.nullptr,
    );
    if (source == ffi.nullptr) {
      calloc.free(memory);
      throw StateError('Could not load prepared text.');
    }
    final page = _loadPage(data['page']! as int);
    pdfium.FPDF_XOBJECT xobject = ffi.nullptr;
    pdfium.FPDF_PAGEOBJECT form = ffi.nullptr;
    var inserted = false;
    try {
      final realWidth = box.rotation.isOdd ? box.height : box.width;
      final realHeight = box.rotation.isOdd ? box.width : box.height;
      if (box.left + realWidth > _api.FPDF_GetPageWidthF(page) + .1 ||
          box.bottom + realHeight > _api.FPDF_GetPageHeightF(page) + .1) {
        throw ArgumentError('The text box must fit inside the PDF page.');
      }
      xobject = _api.FPDF_NewXObjectFromPage(_document, source, 0);
      if (xobject == ffi.nullptr) {
        throw StateError('Could not import shaped text.');
      }
      form = _api.FPDF_NewFormObjectFromXObject(xobject);
      if (form == ffi.nullptr) throw StateError('Could not create text box.');
      switch (box.rotation) {
        case 1:
          _api.FPDFPageObj_Transform(
            form,
            0,
            -1,
            1,
            0,
            box.left,
            box.bottom + box.width,
          );
        case 2:
          _api.FPDFPageObj_Transform(
            form,
            -1,
            0,
            0,
            -1,
            box.left + box.width,
            box.bottom + box.height,
          );
        case 3:
          _api.FPDFPageObj_Transform(
            form,
            0,
            1,
            -1,
            0,
            box.left + box.height,
            box.bottom,
          );
        default:
          _api.FPDFPageObj_Transform(form, 1, 0, 0, 1, box.left, box.bottom);
      }
      final tag = 'PageflowTextBox'.toNativeUtf8();
      final key = 'PageflowBox'.toNativeUtf8();
      final encoded = utf8.encode(jsonEncode(box.toJson()));
      final blob = calloc<ffi.Uint8>(encoded.length)
        ..asTypedList(encoded.length).setAll(0, encoded);
      try {
        final mark = _api.FPDFPageObj_AddMark(form, tag.cast());
        if (mark == ffi.nullptr ||
            _api.FPDFPageObjMark_SetBlobParam(
                  _document,
                  form,
                  mark,
                  key.cast(),
                  blob.cast(),
                  encoded.length,
                ) ==
                0) {
          throw StateError('Could not save editable text-box metadata.');
        }
      } finally {
        calloc.free(tag);
        calloc.free(key);
        calloc.free(blob);
      }
      var index = data['index'] as int?;
      if (index != null) {
        // PDFium can regroup content streams during save. Persisted box IDs
        // identify edited boxes even when their object indices change.
        for (var i = 0; i < _api.FPDFPage_CountObjects(page); i++) {
          if (_boxOf(_api.FPDFPage_GetObject(page, i))?.id == box.id) {
            index = i;
            break;
          }
        }
      }
      if (index != null) {
        final old = _objectAt(page, index);
        if (_api.FPDFPage_RemoveObject(page, old) == 0) {
          throw StateError('Could not replace selected text.');
        }
        _api.FPDFPageObj_Destroy(old);
      }
      if (_api.FPDFPage_InsertObjectAtIndex(
            page,
            form,
            index ?? _api.FPDFPage_CountObjects(page),
          ) ==
          0) {
        throw StateError('Could not insert the text box.');
      }
      inserted = true;
      _generate(page);
      _commit(before);
    } finally {
      if (!inserted && form != ffi.nullptr) _api.FPDFPageObj_Destroy(form);
      if (xobject != ffi.nullptr) _api.FPDF_CloseXObject(xobject);
      _api.FPDF_ClosePage(page);
      _api.FPDF_CloseDocument(source);
      calloc.free(memory);
    }
  }

  Future<int> _replacePrepared(Map<String, Object> data) async {
    final before = _snapshot();
    var count = 0;
    _batch = true;
    try {
      final only = data['page'] as int?;
      for (var page = only ?? 1; page <= (only ?? pageCount); page++) {
        count += await _replaceTextMatches(
          page,
          data['find']! as String,
          data['replace']! as String,
        );
      }
      for (final box in data['boxes']! as List) {
        _upsertBox(Map<String, Object>.from(box as Map));
        count++;
      }
    } finally {
      _batch = false;
    }
    if (count > 0) _commit(before);
    return count;
  }

  Future<Uint8List> _scanSource(int number) async {
    final copy = _PdfiumSession._(_api, 1);
    try {
      await copy._loadBytes(_snapshot());
      final page = copy._loadPage(number);
      try {
        for (var i = _api.FPDFPage_CountObjects(page) - 1; i >= 0; i--) {
          final object = _api.FPDFPage_GetObject(page, i);
          if (copy._boxOf(object) == null) continue;
          if (_api.FPDFPage_RemoveObject(page, object) == 0) {
            throw StateError('Could not prepare scanned background.');
          }
          _api.FPDFPageObj_Destroy(object);
        }
        copy._generate(page);
      } finally {
        _api.FPDF_ClosePage(page);
      }
      return copy._saveBytes();
    } finally {
      await copy.dispose();
    }
  }

  Uint8List _exportBoxTemplate(int pageNumber, String id) {
    final bytes = _snapshot();
    final memory = calloc<ffi.Uint8>(bytes.length)
      ..asTypedList(bytes.length).setAll(0, bytes);
    final doc = _api.FPDF_LoadMemDocument(
      memory.cast(),
      bytes.length,
      ffi.nullptr,
    );
    if (doc == ffi.nullptr) {
      calloc.free(memory);
      throw StateError('Could not preserve a text box.');
    }
    final single = _api.FPDF_CreateNewDocument();
    final index = calloc<ffi.Int>()..value = pageNumber - 1;
    pdfium.FPDF_PAGE page = ffi.nullptr;
    try {
      if (single == ffi.nullptr ||
          _api.FPDF_ImportPagesByIndex(single, doc, index, 1, 0) == 0) {
        throw StateError('Could not preserve a text box.');
      }
      page = _api.FPDF_LoadPage(single, 0);
      PdfTextBox? kept;
      for (var i = _api.FPDFPage_CountObjects(page) - 1; i >= 0; i--) {
        final object = _api.FPDFPage_GetObject(page, i);
        final box = _boxOf(object);
        if (box?.id == id) {
          kept = box;
          final matrix = calloc<pdfium.FS_MATRIX>();
          try {
            matrix.ref
              ..a = 1
              ..b = 0
              ..c = 0
              ..d = 1
              ..e = 0
              ..f = 0;
            if (_api.FPDFPageObj_SetMatrix(object, matrix) == 0) {
              throw StateError('Could not preserve box placement.');
            }
          } finally {
            calloc.free(matrix);
          }
        } else {
          if (_api.FPDFPage_RemoveObject(page, object) == 0) {
            throw StateError('Could not preserve box content.');
          }
          _api.FPDFPageObj_Destroy(object);
        }
      }
      if (kept == null) throw StateError('The editable box was not found.');
      _api.FPDFPage_SetRotation(page, 0);
      _api.FPDFPage_SetMediaBox(page, 0, 0, kept.width, kept.height);
      _api.FPDFPage_SetCropBox(page, 0, 0, kept.width, kept.height);
      _generate(page);
      final temporary = _PdfiumSession._(_api, 1).._document = single;
      final output = temporary._saveBytes();
      temporary._document = ffi.nullptr;
      return output;
    } finally {
      if (page != ffi.nullptr) _api.FPDF_ClosePage(page);
      if (single != ffi.nullptr) _api.FPDF_CloseDocument(single);
      _api.FPDF_CloseDocument(doc);
      calloc.free(memory);
      calloc.free(index);
    }
  }

  void _scanPage(Map<String, Object> data) {
    final before = _snapshot();
    final number = data['page']! as int;
    if (number < 1 || number > pageCount) throw RangeError('Invalid PDF page.');
    final boxDocuments = <String, Uint8List>{};
    final originalPage = _loadPage(number);
    try {
      for (var i = 0; i < _api.FPDFPage_CountObjects(originalPage); i++) {
        final obj = _api.FPDFPage_GetObject(originalPage, i);
        final box = _boxOf(obj);
        if (box == null) continue;
        boxDocuments[box.id] = _exportBoxTemplate(number, box.id);
      }
    } finally {
      _api.FPDF_ClosePage(originalPage);
    }
    final preserved = _listObjects(number)
        .where((o) => o.textBox != null)
        .map((o) => o.textBox!)
        .toList();
    final bytes = data['background']! as Uint8List;
    final memory = calloc<ffi.Uint8>(bytes.length)
      ..asTypedList(bytes.length).setAll(0, bytes);
    final source = _api.FPDF_LoadMemDocument(
      memory.cast(),
      bytes.length,
      ffi.nullptr,
    );
    final indices = calloc<ffi.Int>()..value = 0;
    try {
      if (source == ffi.nullptr ||
          _api.FPDF_GetPageCount(source) != 1 ||
          _api.FPDF_ImportPagesByIndex(
                _document,
                source,
                indices,
                1,
                number - 1,
              ) ==
              0) {
        throw StateError('Could not prepare corrected scanned page.');
      }
      _api.FPDFPage_Delete(_document, number);
      final page = _loadPage(number);
      try {
        _api.FPDFPage_SetRotation(page, data['rotation'] as int? ?? 0);
      } finally {
        _api.FPDF_ClosePage(page);
      }
      _batch = true;
      try {
        for (final box in preserved) {
          final sourcePdf = boxDocuments[box.id];
          if (sourcePdf == null) {
            throw StateError('Missing preserved text-box data.');
          }
          _upsertBox({'page': number, 'box': box.toJson(), 'pdf': sourcePdf});
        }
        _upsertBox(data);
      } finally {
        _batch = false;
      }
      _commit(before);
    } finally {
      if (source != ffi.nullptr) _api.FPDF_CloseDocument(source);
      calloc.free(memory);
      calloc.free(indices);
    }
  }

  void _insertPdf(int beforePage, Uint8List bytes) {
    if (beforePage < 1 || beforePage > pageCount + 1) {
      throw RangeError('Invalid insert position.');
    }
    final before = _snapshot();
    final memory = calloc<ffi.Uint8>(bytes.length)
      ..asTypedList(bytes.length).setAll(0, bytes);
    final source = _api.FPDF_LoadMemDocument(
      memory.cast(),
      bytes.length,
      ffi.nullptr,
    );
    try {
      if (source == ffi.nullptr) {
        throw const FormatException('Could not open the PDF to insert.');
      }
      final count = _api.FPDF_GetPageCount(source);
      if (count < 1 || count + pageCount > 2000) {
        throw ArgumentError('Insert up to a total of 2000 pages.');
      }
      final indices = calloc<ffi.Int>(count)
        ..cast<ffi.Int32>()
            .asTypedList(count)
            .setAll(0, List.generate(count, (i) => i));
      try {
        if (_api.FPDF_ImportPagesByIndex(
              _document,
              source,
              indices,
              count,
              beforePage - 1,
            ) ==
            0) {
          throw StateError('Could not insert PDF pages.');
        }
      } finally {
        calloc.free(indices);
      }
      _pageCount = _api.FPDF_GetPageCount(_document);
      _commit(before);
    } finally {
      if (source != ffi.nullptr) _api.FPDF_CloseDocument(source);
      calloc.free(memory);
    }
  }

  List<Uint8List> _splitPages(List<List<int>> groups) {
    if (groups.isEmpty || groups.length > 100) {
      throw ArgumentError('Choose 1–100 output PDFs.');
    }
    if (groups.any(
      (g) =>
          g.isEmpty || g.length > 2000 || g.any((p) => p < 1 || p > pageCount),
    )) {
      throw ArgumentError('Invalid split page selection.');
    }
    final results = <Uint8List>[];
    for (final group in groups) {
      final output = _api.FPDF_CreateNewDocument();
      final indices = calloc<ffi.Int>(group.length)
        ..cast<ffi.Int32>()
            .asTypedList(group.length)
            .setAll(0, group.map((p) => p - 1));
      try {
        if (output == ffi.nullptr ||
            _api.FPDF_ImportPagesByIndex(
                  output,
                  _document,
                  indices,
                  group.length,
                  0,
                ) ==
                0) {
          throw StateError('Could not split the selected pages.');
        }
        final temp = _PdfiumSession._(_api, 1).._document = output;
        results.add(temp._saveBytes());
        temp._document = ffi.nullptr;
      } finally {
        if (output != ffi.nullptr) _api.FPDF_CloseDocument(output);
        calloc.free(indices);
      }
    }
    return results;
  }

  pdfium.FPDF_PAGE _loadPage(int oneBased) {
    if (oneBased < 1 || oneBased > pageCount) throw RangeError('Invalid page.');
    final page = _api.FPDF_LoadPage(_document, oneBased - 1);
    if (page == ffi.nullptr) throw StateError('Could not load PDF page.');
    return page;
  }

  pdfium.FPDF_PAGEOBJECT _objectAt(pdfium.FPDF_PAGE page, int index) {
    if (index < 0 || index >= _api.FPDFPage_CountObjects(page)) {
      throw RangeError('PDF object no longer exists.');
    }
    return _api.FPDFPage_GetObject(page, index);
  }

  void _generate(pdfium.FPDF_PAGE page) {
    if (_api.FPDFPage_GenerateContent(page) == 0) {
      throw StateError('Could not update the PDF page contents.');
    }
  }

  Uint8List _snapshot() => Uint8List.fromList(_saveBytes());

  void _commit(Uint8List before) {
    if (_batch) return;
    _currentBytes = _saveBytes();
    _undo.add(before);
    while (_undo.length > _historyLimit) {
      _undo.removeAt(0);
    }
    _redo.clear();
  }

  Uint8List _saveBytes({int flags = 0}) {
    final sink = _PdfiumSink();
    final callback =
        ffi.NativeCallable<
          ffi.Int Function(
            ffi.Pointer<pdfium.FPDF_FILEWRITE_>,
            ffi.Pointer<ffi.Void>,
            ffi.UnsignedLong,
          )
        >.isolateLocal((
          ffi.Pointer<pdfium.FPDF_FILEWRITE_> self,
          ffi.Pointer<ffi.Void> data,
          int size,
        ) {
          sink.add(
            Uint8List.fromList(data.cast<ffi.Uint8>().asTypedList(size)),
          );
          return 1;
        }, exceptionalReturn: 0);
    final writer = calloc<pdfium.FPDF_FILEWRITE>();
    try {
      writer.ref.version = 1;
      writer.ref.WriteBlock = callback.nativeFunction;
      if (_api.FPDF_SaveAsCopy(_document, writer, flags) == 0) {
        throw StateError('PDFium could not save this edit.');
      }
      final result = sink.takeBytes();
      _currentBytes = Uint8List.fromList(result);
      return result;
    } finally {
      calloc.free(writer);
      callback.close();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_document != ffi.nullptr) _api.FPDF_CloseDocument(_document);
    if (_documentMemory != ffi.nullptr) calloc.free(_documentMemory);
    _document = ffi.nullptr;
    _documentMemory = ffi.nullptr;
    _undo.clear();
    _redo.clear();
    _currentBytes = Uint8List(0);
  }
}

class PdfTapTarget {
  const PdfTapTarget(this.object, this.left, this.top, this.right, this.bottom);
  final PdfObjectInfo object;
  final double left, top, right, bottom;
}

class PdfObjectInfo {
  const PdfObjectInfo({
    required this.index,
    required this.type,
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
    this.textBox,
    this.text = '',
    this.fontSize = 18,
    this.color = 0xff111111,
  });

  final PdfTextBox? textBox;
  final String text;
  final double fontSize;
  final int color;
  bool get canEditText =>
      textBox != null || (type == pdfium.FPDF_PAGEOBJ_TEXT && text.isNotEmpty);
  PdfTextBox editableStyle() =>
      textBox ??
      PdfTextBox(
        id: 'box-${DateTime.now().microsecondsSinceEpoch}-${math.Random.secure().nextInt(0x7fffffff)}',
        text: text,
        size: fontSize.clamp(6, 144).toDouble(),
        color: color,
        left: left.clamp(0, double.infinity),
        bottom: math.max(0, top - 100),
        width: math.max(200, width),
        height: 100,
      );
  final int index;
  final int type;
  final double left;
  final double bottom;
  final double right;
  final double top;
  double get width => right - left;
  double get height => top - bottom;
  String get label => textBox != null
      ? 'Editable text box'
      : switch (type) {
          pdfium.FPDF_PAGEOBJ_TEXT => 'Text object',
          pdfium.FPDF_PAGEOBJ_IMAGE => 'Image object',
          _ => 'Vector object',
        };
}

class _PdfiumSink {
  final BytesBuilder _builder = BytesBuilder(copy: false);
  void add(Uint8List chunk) => _builder.add(chunk);
  Uint8List takeBytes() => _builder.takeBytes();
}
