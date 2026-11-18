// Cuts a long reply into blocks that [MarkdownBody] renders one GptMarkdown
// each, so a streamed reply only re-renders and repaints its last block.

import 'package:gpt_markdown/gpt_markdown.dart' show MarkdownDefinitions, MarkdownHtml, splitStreamSegments;

import 'math_syntax.dart' show pendingMathLanguage;

/// Splits prepared Markdown into blocks, keeping what it can between calls.
///
/// The cuts are a subset of gpt_markdown's own segment boundaries
/// ([splitStreamSegments]), where it already parses and lays out each piece on
/// its own; each block is a run of whole segments, and blocks are stacked with
/// the same gap the package puts between segments. So a reply looks the same
/// in one widget or in many. On top of that a cut is only made where it can't
/// change anything, and when in doubt there is none (a block just gets longer):
///
/// * not until the block is [minLength] long: few blocks, each about a screen;
/// * not inside a fence, block maths (`\[…\]`, `$$`), an HTML comment or
///   `<details>`, and not between the items of a list (a loose list too), nor
///   before indented text, which belongs to the block above;
/// * only between text, headings, lists and ordinary code blocks: a table,
///   quote, image, HTML or `dsh-ui` view may draw right to its edge, and each
///   block clips to its own box;
/// * never in a reply with link or footnote definitions: a reference in one
///   block would not find its definition in another.
class MarkdownBlockSplit {
  MarkdownBlockSplit({required this.html, required this.minLength});

  /// The HTML the reply is parsed with: an HTML block can span blank lines.
  final MarkdownHtml html;

  /// Shortest block; a reply shorter than this is one block.
  final int minLength;

  String _source = '';
  List<String> _result = const [''];
  List<_Segment> _segments = const [];

  /// [_source] up to its second-to-last segment: unchanged text keeps its
  /// segments.
  String _settled = '';

  List<int> _starts = const [];
  List<String> _blocks = const [];

  /// [source] in blocks; a single block is [source] itself.
  ///
  /// While a reply streams only its end changes: the segments before the last
  /// two are kept (the one before the last takes it in when it turns out to be
  /// indented under it), and the blocks made of them stay the same strings.
  List<String> update(String source) {
    if (identical(source, _source)) return _result;
    _source = source;
    if (source.length < minLength || source.contains('\r')) {
      _reset();
      return _result = [source];
    }
    var keep = 0;
    if (_segments.length >= 3 && source.startsWith(_settled)) keep = _segments.length - 2;
    final from = keep == 0 ? 0 : _segments[keep].start;
    final segments = _segments.sublist(0, keep);
    final tail = from == 0 ? source : source.substring(from);
    var at = 0;
    for (final text in splitStreamSegments(tail, html: html)) {
      final found = tail.indexOf(text, at);
      if (found < 0) {
        _reset();
        return _result = [source];
      }
      at = found + text.length;
      segments.add(_Segment(text, from + found, html));
    }
    _segments = segments;
    if (segments.isEmpty) {
      _reset();
      return _result = [source];
    }
    final open = segments.length >= 3 ? segments[segments.length - 2].start : 0;
    if (keep == 0 || open != from) _settled = source.substring(0, open);

    final starts = <int>[0];
    var run = _Run();
    var definitions = false;
    for (final segment in segments) {
      definitions = definitions || segment.definitions;
      if (run.started && segment.start - starts.last >= minLength && run.canCutBefore(segment)) {
        starts.add(segment.start);
        run = _Run();
      }
      run.add(segment);
    }
    if (definitions || starts.length < 2) {
      _starts = const [];
      _blocks = const [];
      return _result = [source];
    }
    final blocks = <String>[];
    for (var i = 0; i < starts.length; i++) {
      final start = starts[i];
      final end = i + 1 < starts.length ? starts[i + 1] : source.length;
      // Text before [from] is what the last call saw: a block there with the
      // same bounds is the same string.
      final same = i + 1 < starts.length && end <= from && i + 1 < _starts.length;
      blocks.add(same && _starts[i] == start && _starts[i + 1] == end ? _blocks[i] : source.substring(start, end));
    }
    _starts = starts;
    _blocks = blocks;
    return _result = blocks;
  }

  void _reset() {
    _segments = const [];
    _settled = '';
    _starts = const [];
    _blocks = const [];
  }
}

/// What a block made of whole segments has seen so far.
class _Run {
  var started = false;
  var content = false;
  var mathDepth = 0;
  var displayDollars = 0;
  var detailsDepth = 0;
  _Segment? last;

  void add(_Segment segment) {
    started = true;
    content = content || segment.content;
    mathDepth += segment.mathDepth;
    displayDollars += segment.displayDollars;
    detailsDepth += segment.detailsDepth;
    last = segment;
  }

  bool canCutBefore(_Segment next) {
    final end = last;
    return end != null &&
        content &&
        end.safeEnd &&
        next.safeStart &&
        mathDepth <= 0 &&
        displayDollars.isEven &&
        detailsDepth <= 0 &&
        !(next.opensList && end.hasList);
  }
}

/// One gpt_markdown segment, as far as cutting next to it goes.
class _Segment {
  _Segment(String text, this.start, MarkdownHtml html) {
    final lines = text.split('\n');
    String? fenceRun;
    var fenceUnsafe = false;
    var endsWithFence = false;
    var table = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final open = fenceRun;
      if (open != null) {
        final close = _fenceClose.firstMatch(line)?.group(1);
        if (close != null && close[0] == open[0] && close.length >= open.length) {
          fenceRun = null;
          endsWithFence = i == lines.length - 1;
        }
        continue;
      }
      final fence = _fenceOpen.firstMatch(line);
      if (fence != null) {
        fenceRun = fence.group(1);
        fenceUnsafe = _unsafeFences.contains(fence.group(2));
        if (i == 0 && fenceUnsafe) safeStart = false;
        continue;
      }
      if (_listLine.hasMatch(line)) hasList = true;
      if (line.contains('|') && _delimiterRow.hasMatch(line)) table = true;
      if (line.contains(r'\')) {
        mathDepth += r'\['.allMatches(line).length - r'\]'.allMatches(line).length;
      }
      if (line.contains(r'$$')) displayDollars += r'$$'.allMatches(line).length;
      if (line.contains('<')) {
        final lower = line.toLowerCase();
        detailsDepth += '<details'.allMatches(lower).length - '</details'.allMatches(lower).length;
      }
    }
    final first = lines.first;
    final head = first.codeUnitAt(0);
    content = head != _openBracket && head != _lessThan;
    opensList = _listLine.hasMatch(first);
    if (table || _edgeChars.contains(head) || _reachesEdge(first)) safeStart = false;
    if (fenceRun != null || table) {
      safeEnd = false;
    } else if (endsWithFence) {
      safeEnd = !fenceUnsafe;
    } else {
      final last = lines.last.trimLeft();
      safeEnd =
          last.isNotEmpty &&
          !_edgeChars.contains(last.codeUnitAt(0)) &&
          !_reachesEdge(last) &&
          !last.endsWith(r'\]') &&
          !last.contains(r'$$');
    }
    definitions = text.contains(']:') && !MarkdownDefinitions.collect(text, html: html).isEmpty;
  }

  /// Offset of the segment in the source.
  final int start;

  /// Renders something: a segment of only definitions or an HTML comment
  /// doesn't, and a block of only those would leave an empty gap.
  late final bool content;

  /// A block may start here: plain text, a heading, a list or a code block
  /// at the left margin.
  var safeStart = true;

  /// A block may end here: what it ends with draws nothing at its edge.
  late final bool safeEnd;

  late final bool opensList;
  var hasList = false;
  late final bool definitions;
  var mathDepth = 0;
  var displayDollars = 0;
  var detailsDepth = 0;

  /// An image, a formula or an inline HTML tag (`<mark>`'s fill, say) on the
  /// line: each can fill its line to the edge, or draw past it.
  static bool _reachesEdge(String line) =>
      line.contains('![') || line.contains(r'\(') || (line.contains('<') && _tag.hasMatch(line));

  static final _tag = RegExp('<[A-Za-z/!]');

  static const _openBracket = 0x5B;
  static const _lessThan = 0x3C;

  /// Line starts that can draw to the edge of their box (table, quote, HTML,
  /// image, link definition, maths) or that belong to the block above
  /// (indentation).
  static const _edgeChars = {0x20, 0x09, 0x7C, 0x3E, 0x3C, 0x21, 0x5B, 0x5C, 0x24};

  /// Fences drawn as something other than a code block (which keeps a margin).
  static const _unsafeFences = {'dsh-ui', pendingMathLanguage};

  static final _fenceOpen = RegExp(r'^[ \t]*(?:>[ \t]?)*[ \t]*(`{3,}|~{3,})[ \t]*([^`\s]*)');
  static final _fenceClose = RegExp(r'^[ \t]*(?:>[ \t]?)*[ \t]*(`{3,}|~{3,})[ \t]*$');
  static final _listLine = RegExp(r'^[ \t]*(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)');
  static final _delimiterRow = RegExp(r'^[ \t>]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$');
}
