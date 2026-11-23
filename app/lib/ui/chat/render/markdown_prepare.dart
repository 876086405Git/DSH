/// Reuses preparation before a shared neutral boundary in an appended reply.
/// The callback is the unchanged bare-view, maths and table preparation chain.
/// Its options must stay fixed for this instance; tail repair runs afterwards
/// on the complete result, since it can trim whitespace before the tail.
class StreamingMarkdownPreparation {
  StreamingMarkdownPreparation(this._prepare);

  final String Function(String) _prepare;
  String _raw = '';
  String _prepared = '';
  int _rawCut = 0;
  int _outputCut = 0;
  int _lineStart = 0;
  String? _fence;
  bool _afterBlank = true;
  bool _pinned = false;
  bool _prefixSame = true;

  String prepare(String raw) {
    if (!raw.startsWith(_raw)) {
      _raw = _prepared = '';
      _rawCut = _outputCut = _lineStart = 0;
      _fence = null;
      _afterBlank = _prefixSame = true;
      _pinned = false;
    }
    final oldRawCut = _rawCut;
    final oldOutputCut = _outputCut;
    _scan(raw, _raw.length);
    var newlyPrepared = '';
    if (_rawCut > oldRawCut) {
      final sealed = raw.substring(oldRawCut, _rawCut);
      newlyPrepared = _prepare(sealed);
      _prefixSame = _prefixSame && identical(sealed, newlyPrepared);
      _outputCut += newlyPrepared.length;
    }
    // All complete lines are still inside the same trusted fence. Even if
    // the unfinished last line is a closer, no following line can change.
    final literalFence = !_pinned && _fence != null;
    if (_prefixSame && literalFence) {
      _raw = _prepared = raw;
      return raw;
    }
    final tail = raw.substring(_rawCut);
    final preparedTail = literalFence ? tail : _prepare(tail);
    final String result;
    if (_prefixSame && identical(tail, preparedTail)) {
      // Plain replies still return the caller's original String, with no
      // whole-reply copy just to replace an unchanged suffix.
      result = raw;
    } else {
      result = _prepared.replaceRange(oldOutputCut, _prepared.length, newlyPrepared + preparedTail);
    }
    _raw = raw;
    _prepared = result;
    return result;
  }

  void _scan(String raw, int from) {
    if (_pinned) return;
    for (var end = raw.indexOf('\n', from); end != -1; end = raw.indexOf('\n', _lineStart)) {
      final line = raw.substring(_lineStart, end);
      final fence = _fence;
      if (fence != null) {
        // Every parser's closer contains this run. Other placements, such
        // as quoted or Unicode-padded closers, can close only some parsers.
        if (line.contains(fence)) {
          if (line.codeUnits.every((c) => c == fence.codeUnitAt(0))) {
            _fence = null;
          } else {
            _pinned = true;
          }
        }
        _afterBlank = false;
      } else if (line.isEmpty) {
        // A real double LF ends inline maths and code spans in every parser.
        if (_lineStart > 0) _rawCut = end + 1;
        _afterBlank = true;
      } else {
        final marker = _possibleFence.firstMatch(line)?.group(1);
        if (marker != null) {
          // Without the preceding blank, an inline span can consume the
          // next line's opening fence before the maths scanner sees it.
          if (_afterBlank && line.startsWith(marker) && line.indexOf('`', marker.length) < 0) {
            _fence = marker;
          } else {
            _pinned = true;
          }
        } else if (line.trimLeft().startsWith('{') || line.contains(r'$$') || line.contains(r'\[')) {
          // These constructs can still be rewritten across blank lines.
          // Keep their entire suffix as input to the original preparation.
          _pinned = true;
        }
        _afterBlank = false;
      }
      _lineStart = end + 1;
      if (_pinned) return;
    }
  }

  // A superset of all three parsers' openers; Dart trim also accepts NEL.
  static final _possibleFence = RegExp(r'^[\s\u0085>]*(`{3,}|~{3,})');
}
