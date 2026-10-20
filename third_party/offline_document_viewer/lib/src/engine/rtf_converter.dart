import 'dart:convert';
import 'dart:typed_data';

/// Converts Rich Text Format into HTML.
///
/// RTF is a control-word stream rather than a markup tree, so this is a small
/// state machine rather than a parser over a document model: groups push and
/// pop formatting, control words mutate it, and text is emitted with whatever
/// state is current.
///
/// Scope is deliberate. Character formatting, paragraphs, alignment, lists,
/// colours and fonts are handled — those carry the meaning of a document.
/// Embedded objects, drawings and absolute positioning are skipped rather
/// than approximated badly.
abstract final class RtfConverter {
  /// Converts [bytes] to an HTML fragment.
  ///
  /// Never throws: malformed input degrades to whatever text could be
  /// recovered, which is far more useful than an error page.
  static String toHtml(Uint8List bytes) {
    final _RtfReader reader = _RtfReader(latin1.decode(bytes, allowInvalid: true));
    return reader.run();
  }
}

/// Character-level formatting carried through a group.
class _Style {
  _Style({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.superscript = false,
    this.subscript = false,
    this.fontSizeHalfPoints = 24,
    this.colorIndex = 0,
  });

  bool bold;
  bool italic;
  bool underline;
  bool strike;
  bool superscript;
  bool subscript;
  int fontSizeHalfPoints;
  int colorIndex;

  _Style clone() => _Style(
        bold: bold,
        italic: italic,
        underline: underline,
        strike: strike,
        superscript: superscript,
        subscript: subscript,
        fontSizeHalfPoints: fontSizeHalfPoints,
        colorIndex: colorIndex,
      );

  /// Whether anything differs from the document default.
  bool get isPlain =>
      !bold &&
      !italic &&
      !underline &&
      !strike &&
      !superscript &&
      !subscript &&
      fontSizeHalfPoints == 24 &&
      colorIndex == 0;
}

class _RtfReader {
  _RtfReader(this._source);

  final String _source;
  int _index = 0;

  final List<_Style> _stack = <_Style>[_Style()];
  /// Index 0 is RTF's "auto" colour, created by the leading `;` in the
  /// colour table. Pre-seeding it would shift every later index by one.
  final List<String> _colors = <String>[];
  final StringBuffer _out = StringBuffer();
  final StringBuffer _paragraph = StringBuffer();

  String _alignment = 'left';
  int _indentTwips = 0;
  bool _inList = false;

  /// How many characters still have to be skipped after a `\u` escape.
  int _skipFallback = 0;

  /// How many fallback characters each `\u` escape is followed by.
  ///
  /// Set by `\ucN` and inherited by nested groups. Writers that emit real
  /// Unicode — TextEdit among them — use `\uc0`, meaning no fallback at all.
  /// Assuming a fallback of one there silently eats the next real character:
  /// "kalın" arrives as "kalı".
  int _fallbackCount = 1;

  /// Destinations whose contents are metadata, not body text.
  static const Set<String> _skippedDestinations = <String>{
    'fonttbl', 'stylesheet', 'info', 'pict', 'object', 'header', 'footer',
    'footnote', 'annotation', 'xmlnstbl', 'listtable', 'listoverridetable',
    'themedata', 'colorschememapping', 'latentstyles', 'datastore', 'generator',
  };

  _Style get _style => _stack.last;

  String run() {
    while (_index < _source.length) {
      final String ch = _source[_index];
      if (ch == '\\') {
        _readControl();
      } else if (ch == '{') {
        _index++;
        _flushRun();
        _stack.add(_style.clone());
      } else if (ch == '}') {
        _index++;
        _flushRun();
        if (_stack.length > 1) {
          _stack.removeLast();
        }
      } else if (ch == '\r' || ch == '\n') {
        _index++;
      } else {
        _index++;
        _emit(ch);
      }
    }
    _flushParagraph();
    if (_inList) {
      _out.write('</ul>');
    }
    return _out.toString();
  }

  void _readControl() {
    _index++; // consume the backslash
    if (_index >= _source.length) {
      return;
    }

    final String first = _source[_index];

    // A backslash followed by a line break is a paragraph mark. Cocoa and
    // TextEdit write breaks this way rather than as `\par`; reading it as an
    // empty control word silently merges the whole document into one block.
    if (first == '\r' || first == '\n') {
      _index++;
      if (_index < _source.length &&
          (_source[_index] == '\r' || _source[_index] == '\n') &&
          _source[_index] != first) {
        _index++;
      }
      _flushParagraph();
      return;
    }

    // Escaped literal, e.g. \{ \} \\
    if (first == '{' || first == '}' || first == '\\') {
      _index++;
      _emit(first);
      return;
    }

    // \'hh — a byte in the current code page.
    if (first == "'") {
      _index++;
      if (_index + 1 < _source.length) {
        final int? value =
            int.tryParse(_source.substring(_index, _index + 2), radix: 16);
        _index += 2;
        if (value != null) {
          if (_skipFallback > 0) {
            _skipFallback--;
          } else {
            // Windows-1252 covers the Latin range these files use.
            _emit(String.fromCharCode(_win1252(value)));
          }
        }
      }
      return;
    }

    // \* marks a destination that may be discarded wholesale.
    if (first == '*') {
      _index++;
      _skipGroup();
      return;
    }

    // Control word: letters, optional signed number, optional single space.
    final int start = _index;
    while (_index < _source.length && _isLetter(_source[_index])) {
      _index++;
    }
    final String word = _source.substring(start, _index);

    int? parameter;
    if (_index < _source.length &&
        (_source[_index] == '-' || _isDigit(_source[_index]))) {
      final int numStart = _index;
      if (_source[_index] == '-') {
        _index++;
      }
      while (_index < _source.length && _isDigit(_source[_index])) {
        _index++;
      }
      parameter = int.tryParse(_source.substring(numStart, _index));
    }
    if (_index < _source.length && _source[_index] == ' ') {
      _index++;
    }

    _applyControl(word, parameter);
  }

  void _applyControl(String word, int? parameter) {
    if (_skippedDestinations.contains(word)) {
      _skipGroup();
      return;
    }

    switch (word) {
      case 'par':
      case 'sect':
        _flushParagraph();

      case 'line':
        _paragraph.write('<br>');

      case 'tab':
        _paragraph.write('<span class="tab"></span>');

      case 'page':
        _flushParagraph();
        _out.write('<hr class="page-break">');

      case 'pard':
        _alignment = 'left';
        _indentTwips = 0;
        _closeList();

      case 'plain':
        _stack[_stack.length - 1] = _Style();

      case 'b':
        _style.bold = parameter != 0;
      case 'i':
        _style.italic = parameter != 0;
      case 'ul':
        _style.underline = parameter != 0;
      case 'ulnone':
        _style.underline = false;
      case 'strike':
        _style.strike = parameter != 0;
      case 'super':
        _style.superscript = parameter != 0;
      case 'sub':
        _style.subscript = parameter != 0;
      case 'nosupersub':
        _style
          ..superscript = false
          ..subscript = false;

      case 'fs':
        _style.fontSizeHalfPoints = parameter ?? 24;
      case 'cf':
        _style.colorIndex = parameter ?? 0;

      case 'ql':
        _alignment = 'left';
      case 'qr':
        _alignment = 'right';
      case 'qc':
        _alignment = 'center';
      case 'qj':
        _alignment = 'justify';

      case 'li':
        _indentTwips = parameter ?? 0;

      // A bullet inside a paragraph is how RTF marks list items; there is no
      // list structure in the format itself.
      case 'bullet':
        _openList();

      case 'u':
        if (parameter != null) {
          // Values above 32767 are written as negative signed 16-bit.
          final int code = parameter < 0 ? parameter + 65536 : parameter;
          _emit(String.fromCharCode(code));
          _skipFallback = _fallbackCount;
        }

      case 'uc':
        _fallbackCount = parameter ?? 1;

      case 'colortbl':
        _readColorTable();

      case 'emdash':
        _emit('—');
      case 'endash':
        _emit('–');
      case 'lquote':
        _emit('‘');
      case 'rquote':
        _emit('’');
      case 'ldblquote':
        _emit('“');
      case 'rdblquote':
        _emit('”');
      case 'tab_':
        break;
    }
  }

  /// Colour table entries look like `\red255\green0\blue0;`.
  void _readColorTable() {
    int red = 0;
    int green = 0;
    int blue = 0;
    while (_index < _source.length && _source[_index] != '}') {
      if (_source[_index] == '\\') {
        _index++;
        final int start = _index;
        while (_index < _source.length && _isLetter(_source[_index])) {
          _index++;
        }
        final String component = _source.substring(start, _index);
        final int numStart = _index;
        while (_index < _source.length && _isDigit(_source[_index])) {
          _index++;
        }
        final int value =
            int.tryParse(_source.substring(numStart, _index)) ?? 0;
        switch (component) {
          case 'red':
            red = value;
          case 'green':
            green = value;
          case 'blue':
            blue = value;
        }
      } else if (_source[_index] == ';') {
        _colors.add(
          '#${red.toRadixString(16).padLeft(2, '0')}'
          '${green.toRadixString(16).padLeft(2, '0')}'
          '${blue.toRadixString(16).padLeft(2, '0')}',
        );
        red = green = blue = 0;
        _index++;
      } else {
        _index++;
      }
    }
  }

  /// Consumes the current group and everything nested inside it.
  void _skipGroup() {
    int depth = 0;
    while (_index < _source.length) {
      final String ch = _source[_index];
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        if (depth == 0) {
          return;
        }
        depth--;
        if (depth == 0) {
          _index++;
          return;
        }
      }
      _index++;
    }
  }

  /// Text accumulates here until the style changes.
  ///
  /// Emitting per character would produce one wrapper per letter — correct,
  /// but unreadable markup that also breaks search highlighting into pieces.
  final StringBuffer _pending = StringBuffer();
  _Style? _pendingStyle;

  void _emit(String text) {
    if (_skipFallback > 0) {
      _skipFallback--;
      return;
    }
    final _Style current = _style;
    if (_pendingStyle != null && !_sameStyle(_pendingStyle!, current)) {
      _flushRun();
    }
    _pendingStyle = current.clone();
    _pending.write(text);
  }

  void _flushRun() {
    if (_pending.isEmpty) {
      _pendingStyle = null;
      return;
    }
    final String text = _escape(_pending.toString());
    _pending.clear();
    final _Style style = _pendingStyle ?? _Style();
    _pendingStyle = null;
    _paragraph.write(_wrapWith(style, text));
  }

  static bool _sameStyle(_Style a, _Style b) =>
      a.bold == b.bold &&
      a.italic == b.italic &&
      a.underline == b.underline &&
      a.strike == b.strike &&
      a.superscript == b.superscript &&
      a.subscript == b.subscript &&
      a.fontSizeHalfPoints == b.fontSizeHalfPoints &&
      a.colorIndex == b.colorIndex;

  /// Wraps text in the tags [style] calls for.
  String _wrapWith(_Style style, String text) {
    if (style.isPlain) {
      return text;
    }
    final StringBuffer open = StringBuffer();
    final StringBuffer close = StringBuffer();

    void tag(String name) {
      open.write('<$name>');
      close.write('</$name>');
    }

    if (style.bold) {
      tag('strong');
    }
    if (style.italic) {
      tag('em');
    }
    if (style.underline) {
      tag('u');
    }
    if (style.strike) {
      tag('s');
    }
    if (style.superscript) {
      tag('sup');
    }
    if (style.subscript) {
      tag('sub');
    }

    final List<String> styles = <String>[];
    if (style.fontSizeHalfPoints != 24) {
      styles.add('font-size:${style.fontSizeHalfPoints / 2}pt');
    }
    if (style.colorIndex > 0 && style.colorIndex < _colors.length) {
      final String color = _colors[style.colorIndex];
      if (color.isNotEmpty) {
        styles.add('color:$color');
      }
    }
    if (styles.isEmpty) {
      return '$open$text${_reverse(close.toString())}';
    }
    return '<span style="${styles.join(';')}">$open$text'
        '${_reverse(close.toString())}</span>';
  }

  /// Closing tags have to unwind in the opposite order to the opening ones.
  static String _reverse(String closings) {
    final List<String> tags = RegExp(r'</[a-z]+>')
        .allMatches(closings)
        .map((RegExpMatch m) => m.group(0)!)
        .toList()
        .reversed
        .toList();
    return tags.join();
  }

  void _openList() {
    if (!_inList) {
      _flushParagraph();
      _out.write('<ul>');
      _inList = true;
    }
  }

  void _closeList() {
    if (_inList) {
      _flushParagraph();
      _out.write('</ul>');
      _inList = false;
    }
  }

  void _flushParagraph() {
    _flushRun();
    final String content = _paragraph.toString().trim();
    _paragraph.clear();
    if (content.isEmpty) {
      return;
    }
    if (_inList) {
      _out.write('<li>$content</li>');
      return;
    }
    final List<String> styles = <String>[];
    if (_alignment != 'left') {
      styles.add('text-align:$_alignment');
    }
    if (_indentTwips > 0) {
      // 1440 twips to the inch; 96 CSS pixels to the inch.
      styles.add('margin-left:${(_indentTwips / 1440 * 96).round()}px');
    }
    final String attr = styles.isEmpty ? '' : ' style="${styles.join(';')}"';
    _out.write('<p$attr>$content</p>');
  }

  static String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static bool _isLetter(String ch) {
    final int code = ch.codeUnitAt(0);
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  }

  static bool _isDigit(String ch) {
    final int code = ch.codeUnitAt(0);
    return code >= 48 && code <= 57;
  }

  /// Windows-1252 differs from Latin-1 only in 0x80–0x9F, which is exactly
  /// where the typographic characters RTF files use tend to live.
  static int _win1252(int byte) {
    const Map<int, int> high = <int, int>{
      0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
      0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
      0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
      0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
      0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
      0x9E: 0x017E, 0x9F: 0x0178,
    };
    return high[byte] ?? byte;
  }
}
