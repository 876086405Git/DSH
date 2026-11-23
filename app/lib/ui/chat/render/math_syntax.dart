// Turns the maths delimiters models write into the ones gpt_markdown parses,
// without mistaking prices for formulas.
//
// The rules follow remark-math / Pandoc (`tex_math_dollars`), which mainstream
// renderers converge on:
//
// * `$…$` is inline maths when the opening `$` is followed by a non-space,
//   the closing `$` is preceded by a non-space and not followed by a digit,
//   and both are on one line — so `$5 and $10`, `$5-$10`, `5$ 和 10$` stay
//   prose;
// * `$$…$$` is display maths and may span lines;
// * `\(…\)` and `\[…\]` are passed through (gpt_markdown parses them itself);
// * nothing inside code (fences or code spans) is touched, and `\$` is a
//   literal dollar.

import 'package:flutter/foundation.dart';

/// Info string of the fence that stands in for a display formula still
/// streaming in (its closing `$$` / `\]` has not arrived): the code builder
/// shows its source, muted, until the formula can be drawn whole.
const pendingMathLanguage = 'dsh-math-pending';

/// [source] with `$$…$$` rewritten to `\[…\]` and `$…$` to `\(…\)`.
///
/// When [streaming], a display formula left open at the end (`$$` or `\[`
/// without its closer) becomes a [pendingMathLanguage] fence holding its
/// source, so the half-written formula never flashes as an error or as
/// Markdown-mangled prose.
String normalizeMath(String source, {bool streaming = false}) {
  final dollar = source.lastIndexOf(r'$');
  final bracket = streaming ? source.lastIndexOf(r'\[') : -1;
  // One `$` pairs with nothing; a streaming `\[` may still need its pending fence.
  if (bracket < 0 && (dollar < 0 || source.indexOf(r'$') == dollar)) return source;
  return _MathScanner(source, streaming).run(bracket > dollar ? bracket : dollar);
}

/// Whether the `$` at [open] starts inline maths, and where its closing `$`
/// is (-1 when it is prose).
@visibleForTesting
int inlineDollarCloser(String text, int open) {
  final n = text.length;
  if (open + 1 >= n) return -1;
  if (open > 0 && text.codeUnitAt(open - 1) == _dollar) return -1;
  final first = text.codeUnitAt(open + 1);
  if (first == _dollar || _isSpace(first)) return -1;
  var k = open + 1;
  while (k < n) {
    final c = text.codeUnitAt(k);
    // One line only; and a backtick means the `$` belongs to code nearby.
    if (c == _newline || c == _backtick) return -1;
    if (c == _backslash && k + 1 < n) {
      k += 2;
      continue;
    }
    if (c == _dollar) break;
    k += 1;
  }
  if (k >= n) return -1;
  // Half of a `$$`.
  if (k + 1 < n && text.codeUnitAt(k + 1) == _dollar) return -1;
  // `$5 and $10`: the closer hugs the text before it, never a space.
  if (_isSpace(text.codeUnitAt(k - 1))) return -1;
  // `$5-$10`, `$5，$10`: a closer followed by a digit is the next price.
  if (k + 1 < n && _isDigit(text.codeUnitAt(k + 1))) return -1;
  final body = text.substring(open + 1, k);
  if (_readsAsPrices(body)) return -1;
  return k;
}

/// `5 and 10` between two dollars (`$5 and 10$`): an amount followed by words
/// and nothing a formula would contain.
bool _readsAsPrices(String body) {
  if (body.isEmpty || !_isDigit(body.codeUnitAt(0))) return false;
  if (!body.contains(RegExp(r'\s'))) return false;
  return !body.contains(RegExp(r'[\\^_{}=+<>]'));
}

class _MathScanner {
  _MathScanner(this.text, this.streaming);

  final String text;
  final bool streaming;
  final _out = StringBuffer();

  int get _n => text.length;

  String run(int lastOpener) {
    var i = 0;
    // Keep unchanged spans in the source until a delimiter really changes.
    var copiedTo = 0;
    var lineStart = 0;
    var atLineStart = true;
    _Fence? fence;
    var paragraphEnd = -1;
    while (i <= lastOpener) {
      if (atLineStart) {
        atLineStart = false;
        lineStart = i;
        final lineEnd = _lineEnd(i);
        final line = text.substring(i, lineEnd);
        final open = fence;
        if (open != null) {
          if (open.closedBy(line)) fence = null;
          i = lineEnd < _n ? lineEnd + 1 : _n;
          atLineStart = true;
          continue;
        }
        final opens = _Fence.open(line);
        if (opens != null) {
          fence = opens;
          i = lineEnd < _n ? lineEnd + 1 : _n;
          atLineStart = true;
          continue;
        }
      }
      final c = text.codeUnitAt(i);
      if (c == _newline) {
        i += 1;
        atLineStart = true;
        continue;
      }
      if (c == _backtick) {
        if (i > paragraphEnd) paragraphEnd = _paragraphEnd(i);
        final end = _codeSpanEnd(i, paragraphEnd);
        i = end;
        continue;
      }
      if (c == _backslash && i + 1 < _n) {
        final next = text.codeUnitAt(i + 1);
        if (next == _openBracket && streaming && !text.contains(r'\]', i + 2)) {
          _out.write(text.substring(copiedTo, i));
          _pending(i, 2, lineStart);
          return _out.toString();
        }
        i += 2;
        if (next == _newline) atLineStart = true;
        continue;
      }
      if (c == _dollar) {
        if (i + 1 < _n && text.codeUnitAt(i + 1) == _dollar) {
          final end = _displayCloser(i + 2);
          if (end != -1) {
            _out
              ..write(text.substring(copiedTo, i))
              ..write(r'\[')
              ..write(text.substring(i + 2, end))
              ..write(r'\]');
            i = end + 2;
            copiedTo = i;
            continue;
          }
          if (streaming && _hasDisplayBody(i + 2)) {
            _out.write(text.substring(copiedTo, i));
            _pending(i, 2, lineStart);
            return _out.toString();
          }
          i += 2;
          continue;
        }
        final end = inlineDollarCloser(text, i);
        if (end != -1) {
          _out
            ..write(text.substring(copiedTo, i))
            ..write(r'\(')
            ..write(text.substring(i + 1, end))
            ..write(r'\)');
          i = end + 1;
          copiedTo = i;
          continue;
        }
      }
      i += 1;
    }
    if (copiedTo == 0) return text;
    _out.write(text.substring(copiedTo));
    return _out.toString();
  }

  int _lineEnd(int from) {
    final end = text.indexOf('\n', from);
    return end == -1 ? _n : end;
  }

  /// The closing `$$` of a display formula whose body starts at [from], or
  /// -1. The formula does not run into a code fence.
  int _displayCloser(int from) {
    var end = text.indexOf(r'$$', from);
    while (end > 0 && text.codeUnitAt(end - 1) == _backslash) {
      end = text.indexOf(r'$$', end + 2);
    }
    if (end == -1) return -1;
    final body = text.substring(from, end);
    if (body.trim().isEmpty) return -1;
    for (final line in body.split('\n').skip(1)) {
      if (_Fence.open(line) != null) return -1;
    }
    return end;
  }

  /// Whether an open `$$` at the end has anything but blanks after it — a
  /// bare `$$` (or `$$$` of a price) is not worth a pending block yet.
  bool _hasDisplayBody(int from) => text.substring(from).trim().isNotEmpty;

  /// Where the paragraph holding [i] ends (a blank line, or the text's end).
  int _paragraphEnd(int i) {
    final blank = _blankLine.allMatches(text, i).firstOrNull;
    return blank == null ? _n : blank.start;
  }

  static final _blankLine = RegExp(r'\n[ \t>]*\n');

  /// End of the code span opening at [i] (past its closing backticks), or of
  /// the backtick run itself when nothing closes it before [limit].
  int _codeSpanEnd(int i, int limit) {
    var run = 0;
    while (i + run < _n && text.codeUnitAt(i + run) == _backtick) {
      run += 1;
    }
    var k = i + run;
    while (k < limit) {
      final close = text.indexOf('`', k);
      if (close == -1 || close >= limit) break;
      var len = 0;
      while (close + len < _n && text.codeUnitAt(close + len) == _backtick) {
        len += 1;
      }
      if (len == run) return close + len;
      k = close + len;
    }
    return i + run;
  }

  /// The rest of the text, from the opener at [at] ([length] code units), as
  /// a [pendingMathLanguage] fence. The fence repeats the line's quote /
  /// indent prefix so it stays inside the block the formula was in.
  void _pending(int at, int length, int lineStart) {
    var prefixEnd = lineStart;
    while (prefixEnd < at && _isPrefixChar(text.codeUnitAt(prefixEnd))) {
      prefixEnd += 1;
    }
    final prefix = text.substring(lineStart, prefixEnd);
    final rest = text.substring(at + length);
    final fence = '`' * _fenceLength(rest);
    if (prefixEnd < at) _out.write('\n$prefix');
    _out
      ..write(fence)
      ..write(pendingMathLanguage)
      ..write('\n');
    final firstEnd = rest.indexOf('\n');
    final first = firstEnd == -1 ? rest : rest.substring(0, firstEnd);
    final after = firstEnd == -1 ? '' : rest.substring(firstEnd + 1);
    if (first.trim().isNotEmpty) {
      _out.write('$prefix${first.trimLeft()}');
      if (firstEnd != -1) _out.write('\n$after');
    } else {
      _out.write(after);
    }
  }

  /// A fence longer than any backtick run at the start of a line in [body].
  static int _fenceLength(String body) {
    var longest = 0;
    for (final match in RegExp(r'^[ \t>]*(`+)', multiLine: true).allMatches(body)) {
      if (match.group(1)!.length > longest) longest = match.group(1)!.length;
    }
    return longest < 3 ? 3 : longest + 1;
  }
}

/// An open code fence: its character, run length and quote depth.
class _Fence {
  const _Fence(this.char, this.length);

  final int char;
  final int length;

  static final _opener = RegExp(r'^[ \t]*(?:>[ \t]?)*[ \t]*(`{3,}|~{3,})');

  /// The fence [line] opens, if it opens one.
  static _Fence? open(String line) {
    final match = _opener.firstMatch(line);
    if (match == null) return null;
    final run = match.group(1)!;
    // A backtick fence's info string cannot contain backticks.
    if (run.codeUnitAt(0) == _backtick && line.indexOf('`', match.end) != -1) {
      return null;
    }
    return _Fence(run.codeUnitAt(0), run.length);
  }

  bool closedBy(String line) {
    final match = RegExp(r'^[ \t]*(?:>[ \t]?)*[ \t]*(`+|~+)[ \t]*$').firstMatch(line);
    if (match == null) return false;
    final run = match.group(1)!;
    return run.codeUnitAt(0) == char && run.length >= length;
  }
}

const _dollar = 0x24;
const _backslash = 0x5C;
const _backtick = 0x60;
const _newline = 0x0A;
const _openBracket = 0x5B;

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 || c == 0x3000;

bool _isPrefixChar(int c) => c == 0x20 || c == 0x09 || c == 0x3E /* > */;
