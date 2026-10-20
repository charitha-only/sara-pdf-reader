import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../font/shaped_font.dart';
import '../model/shaped_run.dart';
import '../model/text_direction.dart';
import '../model/text_style.dart';
import '../script/harfbuzz_unicode_properties.dart';
import '../shaping/harfbuzz_shaper.dart';

class ShapedText extends pw.Widget with pw.SpanningWidget {
  ShapedText(this.text, {required this.style, this.language, this.maxLines})
    : assert(maxLines == null || maxLines > 0, 'maxLines must be positive.');

  final String text;
  final ShapedTextStyle style;
  final String? language;
  final int? maxLines;

  final HarfBuzzShaper _shaper = const HarfBuzzShaper();
  final _ShapedTextContext _context = _ShapedTextContext();

  List<_LayoutLine> _allLines = const <_LayoutLine>[];
  List<_LayoutLine> _pageLines = const <_LayoutLine>[];
  double _lineHeight = 0;
  double _ascent = 0;

  @override
  bool get canSpan => true;

  @override
  bool get hasMoreWidgets => _context.lineEnd < _allLines.length;

  @override
  pw.WidgetContext saveContext() => _context;

  @override
  void restoreContext(covariant _ShapedTextContext context) {
    _context.lineStart = context.lineEnd;
    _context.lineEnd = context.lineEnd;
  }

  @override
  void layout(
    pw.Context context,
    pw.BoxConstraints constraints, {
    bool parentUsesSize = false,
  }) {
    final widthLimit = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : double.infinity;

    final naturalLineHeight = style.fonts
        .map((font) => font.metrics.lineHeightFor(style.fontSize))
        .reduce((a, b) => math.max(a, b));
    _lineHeight = naturalLineHeight * (style.lineHeight ?? 1);
    _ascent = style.fonts
        .map((font) => font.metrics.ascentFor(style.fontSize))
        .reduce((a, b) => math.max(a, b));

    final lines = <_LayoutLine>[];
    for (final paragraph in text.split('\n')) {
      if (paragraph.isEmpty) {
        lines.add(const _LayoutLine.empty());
      } else {
        lines.addAll(_wrapParagraph(paragraph, widthLimit));
      }

      if (maxLines != null && lines.length >= maxLines!) break;
    }

    _allLines = maxLines == null
        ? List<_LayoutLine>.unmodifiable(lines)
        : List<_LayoutLine>.unmodifiable(lines.take(maxLines!));

    final start = math.min(_context.lineStart, _allLines.length);
    final end = constraints.hasBoundedHeight
        ? math.min(
            _allLines.length,
            start + math.max(0, (constraints.maxHeight / _lineHeight).floor()),
          )
        : _allLines.length;

    _context.lineEnd = end.toInt();
    _pageLines = List<_LayoutLine>.unmodifiable(
      _allLines.sublist(start, end.toInt()),
    );

    final naturalWidth = _pageLines.fold<double>(
      0,
      (current, line) => math.max(current, line.width),
    );

    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.constrainWidth(naturalWidth);
    final height = constraints.constrainHeight(_lineHeight * _pageLines.length);

    box = PdfRect(0, 0, width, height);
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    final bounds = box;
    if (bounds == null || _pageLines.isEmpty) return;

    final canvas = context.canvas;
    canvas.saveContext();
    try {
      canvas.setFillColor(style.color);

      for (var lineIndex = 0; lineIndex < _pageLines.length; lineIndex++) {
        final line = _pageLines[lineIndex];
        final baseline =
            bounds.y + bounds.height - _ascent - lineIndex * _lineHeight;
        final lineX = bounds.x + _alignedOffset(bounds.width, line.width);

        var runX = lineX;
        for (final run in line.runs) {
          _paintRun(canvas, run, runX, baseline);

          if (style.preserveUnicodeText && run.sourceText.isNotEmpty) {
            final pdfFont = run.font.pdfFont.getFont(context);
            canvas.drawString(
              pdfFont,
              style.fontSize,
              run.sourceText,
              runX,
              baseline,
              mode: PdfTextRenderingMode.invisible,
            );
          }

          runX += _runWidth(run);
        }
      }
    } finally {
      canvas.restoreContext();
    }
  }

  List<_LayoutLine> _wrapParagraph(String paragraph, double widthLimit) {
    if (!widthLimit.isFinite) {
      return <_LayoutLine>[_shapeLine(paragraph)];
    }

    final tokens = _tokens(paragraph);
    final result = <_LayoutLine>[];
    var current = '';

    for (final token in tokens) {
      if (current.isEmpty) {
        final first = _shapeLine(token);
        if (first.width <= widthLimit || token.trim().isEmpty) {
          current = token;
        } else {
          final split = _splitOversizedToken(token, widthLimit);
          result.addAll(split.lines);
          current = split.remainder;
        }
        continue;
      }

      final candidate = current + token;
      if (_shapeLine(candidate).width <= widthLimit) {
        current = candidate;
        continue;
      }

      final completed = current.trimRight();
      if (completed.isNotEmpty) result.add(_shapeLine(completed));

      current = token.trimLeft();
      if (current.isNotEmpty && _shapeLine(current).width > widthLimit) {
        final split = _splitOversizedToken(current, widthLimit);
        result.addAll(split.lines);
        current = split.remainder;
      }
    }

    final completed = current.trimRight();
    if (completed.isNotEmpty || result.isEmpty) {
      result.add(_shapeLine(completed));
    }

    return result;
  }

  _TokenSplit _splitOversizedToken(String token, double widthLimit) {
    final lines = <_LayoutLine>[];
    var current = '';

    for (final character in token.characters) {
      final candidate = current + character;
      if (current.isEmpty || _shapeLine(candidate).width <= widthLimit) {
        current = candidate;
      } else {
        lines.add(_shapeLine(current));
        current = character;
      }
    }

    return _TokenSplit(lines: lines, remainder: current);
  }

  _LayoutLine _shapeLine(String source) {
    if (source.isEmpty) return const _LayoutLine.empty();

    final direction = _resolveDirection(source);
    final sourceRuns = _segment(source);
    final shaped = sourceRuns
        .map(
          (run) => _shaper.shape(
            run.text,
            font: run.font,
            direction: run.isRightToLeft
                ? ShapedTextDirection.rightToLeft
                : ShapedTextDirection.leftToRight,
            language: language,
          ),
        )
        .toList(growable: false);

    final visualRuns = direction == ShapedTextDirection.rightToLeft
        ? shaped.reversed.toList(growable: false)
        : shaped;

    final width = visualRuns.fold<double>(
      0,
      (sum, run) => sum + _runWidth(run),
    );

    return _LayoutLine(runs: visualRuns, width: width);
  }

  List<_SourceRun> _segment(String source) {
    final fonts = style.fonts;
    final result = <_SourceRun>[];

    StringBuffer? buffer;
    ShapedFont? currentFont;
    int? currentScriptTag;
    bool currentIsRightToLeft = false;
    int? inheritedScriptTag;
    bool inheritedIsRightToLeft = false;

    void flush() {
      final value = buffer?.toString() ?? '';
      if (value.isNotEmpty && currentFont != null) {
        result.add(
          _SourceRun(
            text: value,
            font: currentFont!,
            isRightToLeft: currentIsRightToLeft,
          ),
        );
      }
      buffer = null;
      currentFont = null;
      currentScriptTag = null;
      currentIsRightToLeft = false;
    }

    for (final rune in source.runes) {
      final raw = HarfBuzzUnicodeProperties.ofRune(rune);
      final effectiveTag = raw.isCommon || raw.isInherited
          ? inheritedScriptTag ?? raw.tag
          : raw.tag;
      final effectiveRtl = raw.isCommon || raw.isInherited
          ? inheritedIsRightToLeft
          : raw.isRightToLeft;

      if (raw.isStrong) {
        inheritedScriptTag = raw.tag;
        inheritedIsRightToLeft = raw.isRightToLeft;
      }

      final selectedFont =
          (raw.isCommon || raw.isInherited) &&
              currentFont != null &&
              (_isWhitespace(rune) || currentFont!.supportsRune(rune))
          ? currentFont!
          : _fontForRune(fonts, rune);

      final shouldSplit =
          buffer != null &&
          (currentFont != selectedFont ||
              (currentScriptTag != null &&
                  effectiveTag != currentScriptTag &&
                  raw.isStrong));

      if (shouldSplit) flush();

      buffer ??= StringBuffer();
      currentFont = selectedFont;
      currentScriptTag ??= effectiveTag;
      currentIsRightToLeft = effectiveRtl;
      buffer?.writeCharCode(rune);
    }

    flush();
    return result;
  }

  ShapedFont _fontForRune(List<ShapedFont> fonts, int rune) {
    if (_isWhitespace(rune)) {
      return fonts.first;
    }

    for (final font in fonts) {
      if (font.supportsRune(rune)) {
        return font;
      }
    }

    final code = rune.toRadixString(16).toUpperCase().padLeft(4, '0');

    final character = String.fromCharCode(rune);

    throw StateError(
      'No configured font supports "$character" (U+$code). '
      'Fonts checked: ${fonts.map((font) => font.name).join(', ')}. '
      'Add a font containing this glyph to fallbackFonts.',
    );
  }

  ShapedTextDirection _resolveDirection(String source) {
    if (style.direction != ShapedTextDirection.auto) {
      return style.direction;
    }

    return HarfBuzzUnicodeProperties.firstStrongIsRightToLeft(source)
        ? ShapedTextDirection.rightToLeft
        : ShapedTextDirection.leftToRight;
  }

  void _paintRun(
    PdfGraphics canvas,
    ShapedRun run,
    double originX,
    double baseline,
  ) {
    final scale = style.fontSize / run.font.metrics.unitsPerEm;
    final signedAdvance = run.signedAdvance;
    var cursor = signedAdvance < 0 ? run.advance.toDouble() : 0.0;

    for (final glyph in run.glyphs) {
      final glyphOriginX = originX + (cursor + glyph.xOffset) * scale;
      final glyphOriginY = baseline + glyph.yOffset * scale;

      run.font.paintGlyph(
        canvas,
        glyph.glyphId,
        originX: glyphOriginX,
        originY: glyphOriginY,
        scale: scale,
      );

      cursor += glyph.xAdvance;
    }
  }

  double _runWidth(ShapedRun run) =>
      run.advance * (style.fontSize / run.font.metrics.unitsPerEm);

  double _alignedOffset(double available, double lineWidth) {
    return switch (style.align) {
      ShapedTextAlign.start => _effectiveRtl ? available - lineWidth : 0,
      ShapedTextAlign.center => (available - lineWidth) / 2,
      ShapedTextAlign.end => _effectiveRtl ? 0 : available - lineWidth,
    };
  }

  bool get _effectiveRtl =>
      style.direction == ShapedTextDirection.rightToLeft ||
      (style.direction == ShapedTextDirection.auto &&
          HarfBuzzUnicodeProperties.firstStrongIsRightToLeft(text));

  static List<String> _tokens(String source) {
    final matches = RegExp(r'\s+|\S+').allMatches(source);
    if (matches.isEmpty) return <String>[source];
    return matches.map((match) => match.group(0)!).toList(growable: false);
  }

  static bool _isWhitespace(int rune) =>
      rune == 0x09 ||
      rune == 0x0A ||
      rune == 0x0D ||
      rune == 0x20 ||
      rune == 0x00A0;
}

final class _ShapedTextContext extends pw.WidgetContext {
  int lineStart = 0;
  int lineEnd = 0;

  @override
  void apply(covariant _ShapedTextContext other) {
    lineStart = other.lineStart;
    lineEnd = other.lineEnd;
  }

  @override
  pw.WidgetContext clone() {
    return _ShapedTextContext()
      ..lineStart = lineStart
      ..lineEnd = lineEnd;
  }
}

final class _SourceRun {
  const _SourceRun({
    required this.text,
    required this.font,
    required this.isRightToLeft,
  });

  final String text;
  final ShapedFont font;
  final bool isRightToLeft;
}

final class _LayoutLine {
  const _LayoutLine({required this.runs, required this.width});

  const _LayoutLine.empty() : runs = const <ShapedRun>[], width = 0;

  final List<ShapedRun> runs;
  final double width;
}

final class _TokenSplit {
  const _TokenSplit({required this.lines, required this.remainder});

  final List<_LayoutLine> lines;
  final String remainder;
}
