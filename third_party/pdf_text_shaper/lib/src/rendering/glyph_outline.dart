import 'dart:ffi';

import 'package:harfbuzz_ffi/harfbuzz_ffi_bindings.dart' as hb;
import 'package:pdf/pdf.dart';

sealed class GlyphPathCommand {
  const GlyphPathCommand();

  void replay(
    PdfGraphics canvas, {
    required double originX,
    required double originY,
    required double scale,
  });
}

final class GlyphMoveTo extends GlyphPathCommand {
  const GlyphMoveTo(this.x, this.y);

  final double x;
  final double y;

  @override
  void replay(
    PdfGraphics canvas, {
    required double originX,
    required double originY,
    required double scale,
  }) {
    canvas.moveTo(originX + x * scale, originY + y * scale);
  }
}

final class GlyphLineTo extends GlyphPathCommand {
  const GlyphLineTo(this.x, this.y);

  final double x;
  final double y;

  @override
  void replay(
    PdfGraphics canvas, {
    required double originX,
    required double originY,
    required double scale,
  }) {
    canvas.lineTo(originX + x * scale, originY + y * scale);
  }
}

final class GlyphCubicTo extends GlyphPathCommand {
  const GlyphCubicTo(this.x1, this.y1, this.x2, this.y2, this.x3, this.y3);

  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final double x3;
  final double y3;

  @override
  void replay(
    PdfGraphics canvas, {
    required double originX,
    required double originY,
    required double scale,
  }) {
    canvas.curveTo(
      originX + x1 * scale,
      originY + y1 * scale,
      originX + x2 * scale,
      originY + y2 * scale,
      originX + x3 * scale,
      originY + y3 * scale,
    );
  }
}

final class GlyphClosePath extends GlyphPathCommand {
  const GlyphClosePath();

  @override
  void replay(
    PdfGraphics canvas, {
    required double originX,
    required double originY,
    required double scale,
  }) {
    canvas.closePath();
  }
}

final class GlyphOutline {
  const GlyphOutline(this.commands);

  final List<GlyphPathCommand> commands;

  bool get isEmpty => commands.isEmpty;
}

final class HarfBuzzGlyphOutlineExtractor {
  HarfBuzzGlyphOutlineExtractor() : _drawFuncs = hb.hb_draw_funcs_create() {
    if (_drawFuncs == nullptr) {
      throw StateError('HarfBuzz could not create glyph draw callbacks.');
    }

    final noDestroy = nullptr
        .cast<NativeFunction<hb.hb_destroy_func_tFunction>>();

    hb.hb_draw_funcs_set_move_to_func(
      _drawFuncs,
      _moveToPointer,
      nullptr,
      noDestroy,
    );
    hb.hb_draw_funcs_set_line_to_func(
      _drawFuncs,
      _lineToPointer,
      nullptr,
      noDestroy,
    );
    hb.hb_draw_funcs_set_quadratic_to_func(
      _drawFuncs,
      _quadraticToPointer,
      nullptr,
      noDestroy,
    );
    hb.hb_draw_funcs_set_cubic_to_func(
      _drawFuncs,
      _cubicToPointer,
      nullptr,
      noDestroy,
    );
    hb.hb_draw_funcs_set_close_path_func(
      _drawFuncs,
      _closePathPointer,
      nullptr,
      noDestroy,
    );
  }

  final Pointer<hb.hb_draw_funcs_t> _drawFuncs;
  final Map<int, GlyphOutline> _cache = <int, GlyphOutline>{};
  bool _disposed = false;

  static int _nextSession = 1;
  static final Map<int, List<GlyphPathCommand>> _sessions =
      <int, List<GlyphPathCommand>>{};

  GlyphOutline outline(Pointer<hb.hb_font_t> font, int glyphId) {
    if (_disposed) {
      throw StateError('Glyph outline extractor has been disposed.');
    }

    return _cache.putIfAbsent(glyphId, () {
      final session = _nextSession++;
      final commands = <GlyphPathCommand>[];
      _sessions[session] = commands;
      try {
        hb.hb_font_draw_glyph(
          font,
          glyphId,
          _drawFuncs,
          Pointer<Void>.fromAddress(session),
        );
        return GlyphOutline(List<GlyphPathCommand>.unmodifiable(commands));
      } finally {
        _sessions.remove(session);
      }
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cache.clear();
    hb.hb_draw_funcs_destroy(_drawFuncs);
  }

  static List<GlyphPathCommand>? _commands(Pointer<Void> drawData) =>
      _sessions[drawData.address];

  static void _moveTo(
    Pointer<hb.hb_draw_funcs_t> funcs,
    Pointer<Void> drawData,
    Pointer<hb.hb_draw_state_t> state,
    double x,
    double y,
    Pointer<Void> userData,
  ) {
    _commands(drawData)?.add(GlyphMoveTo(x, y));
  }

  static void _lineTo(
    Pointer<hb.hb_draw_funcs_t> funcs,
    Pointer<Void> drawData,
    Pointer<hb.hb_draw_state_t> state,
    double x,
    double y,
    Pointer<Void> userData,
  ) {
    _commands(drawData)?.add(GlyphLineTo(x, y));
  }

  static void _quadraticTo(
    Pointer<hb.hb_draw_funcs_t> funcs,
    Pointer<Void> drawData,
    Pointer<hb.hb_draw_state_t> state,
    double controlX,
    double controlY,
    double toX,
    double toY,
    Pointer<Void> userData,
  ) {
    final commands = _commands(drawData);
    if (commands == null) return;

    final fromX = state.ref.current_x;
    final fromY = state.ref.current_y;

    // Convert the TrueType quadratic segment to the cubic Bézier operation
    // exposed by PdfGraphics.
    final c1X = fromX + (2 / 3) * (controlX - fromX);
    final c1Y = fromY + (2 / 3) * (controlY - fromY);
    final c2X = toX + (2 / 3) * (controlX - toX);
    final c2Y = toY + (2 / 3) * (controlY - toY);

    commands.add(GlyphCubicTo(c1X, c1Y, c2X, c2Y, toX, toY));
  }

  static void _cubicTo(
    Pointer<hb.hb_draw_funcs_t> funcs,
    Pointer<Void> drawData,
    Pointer<hb.hb_draw_state_t> state,
    double control1X,
    double control1Y,
    double control2X,
    double control2Y,
    double toX,
    double toY,
    Pointer<Void> userData,
  ) {
    _commands(
      drawData,
    )?.add(GlyphCubicTo(control1X, control1Y, control2X, control2Y, toX, toY));
  }

  static void _closePath(
    Pointer<hb.hb_draw_funcs_t> funcs,
    Pointer<Void> drawData,
    Pointer<hb.hb_draw_state_t> state,
    Pointer<Void> userData,
  ) {
    _commands(drawData)?.add(const GlyphClosePath());
  }

  static final hb.hb_draw_move_to_func_t _moveToPointer =
      Pointer.fromFunction<hb.hb_draw_move_to_func_tFunction>(_moveTo);
  static final hb.hb_draw_line_to_func_t _lineToPointer =
      Pointer.fromFunction<hb.hb_draw_line_to_func_tFunction>(_lineTo);
  static final hb.hb_draw_quadratic_to_func_t _quadraticToPointer =
      Pointer.fromFunction<hb.hb_draw_quadratic_to_func_tFunction>(
        _quadraticTo,
      );
  static final hb.hb_draw_cubic_to_func_t _cubicToPointer =
      Pointer.fromFunction<hb.hb_draw_cubic_to_func_tFunction>(_cubicTo);
  static final hb.hb_draw_close_path_func_t _closePathPointer =
      Pointer.fromFunction<hb.hb_draw_close_path_func_tFunction>(_closePath);
}
