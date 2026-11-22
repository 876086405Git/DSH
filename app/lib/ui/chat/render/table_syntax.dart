// Table headers set in bold, the way GitHub and the chat apps show them.
// gpt_markdown hands the header style to its cells as an inherited default,
// which the reply's explicit body weight overrides, so the header cells are
// marked up as bold before parsing instead.

/// Separate pipe tables from the preceding paragraph, then bold their headers.
String prepareTables(String source) {
  if (!_mayHaveTable(source)) return source;
  final lines = source.split('\n');
  final headers = _headerRows(lines).toList();
  if (headers.isEmpty) return source;
  final breaks = _breaksBeforeHeaders(lines, headers);
  final bolded = _boldHeaders(lines, headers, breaks);
  _insertBreaks(lines, breaks);
  return bolded || breaks.isNotEmpty ? lines.join('\n') : source;
}

bool _mayHaveTable(String source) => source.contains('|') && source.contains('-');

/// [source] with the header cells of every pipe table wrapped in `**…**`.
///
/// Code fences are skipped; a cell that is empty or already carries
/// emphasis markers is left as written.
String boldTableHeaders(String source) {
  if (!_mayHaveTable(source)) return source;
  final lines = source.split('\n');
  return _boldHeaders(lines, _headerRows(lines), const {}) ? lines.join('\n') : source;
}

Iterable<int> _headerRows(List<String> lines) sync* {
  String? fence;
  for (var i = 0; i + 1 < lines.length; i++) {
    final line = lines[i];
    if (fence != null) {
      final close = _fenceClose.firstMatch(line)?.group(1);
      if (close != null && close[0] == fence[0] && close.length >= fence.length) fence = null;
      continue;
    }
    final marker = _fence.firstMatch(line)?.group(1);
    if (marker != null) {
      fence = marker;
      continue;
    }
    if (line.contains('|') && _isDelimiterRow(lines[i + 1], line)) yield i;
  }
}

bool _boldHeaders(List<String> lines, Iterable<int> headers, Set<int> breaks) {
  var changed = false;
  var delimiter = -1;
  for (final i in headers) {
    // A new blank can separate two originally adjacent rows. A delimiter
    // consumed by an accepted header cannot itself head another table.
    if (i == delimiter || breaks.contains(i + 1)) continue;
    delimiter = i + 1;
    final bolded = _boldRow(lines[i]);
    if (bolded != lines[i]) {
      lines[i] = bolded;
      changed = true;
    }
  }
  return changed;
}

final _fence = RegExp(r'^[ \t]*(?:>[ \t]?)*[ \t]*(`{3,}|~{3,})');
final _fenceClose = RegExp(r'^[ \t]*(?:>[ \t]?)*[ \t]*(`{3,}|~{3,})[ \t]*$');
final _delimiterCell = RegExp(r'^\s*:?-+:?\s*$');
final _pipe = RegExp(r'(?<!\\)\|');

String _unquoted(String line) => line.trim().replaceFirst(RegExp(r'^(?:>[ \t]?)*'), '').trim();

/// A GFM delimiter row with as many cells as the header (`a | b` over `---`
/// is a heading, not a table).
bool _isDelimiterRow(String line, String header) {
  final t = _unquoted(line);
  if (!t.contains('-')) return false;
  final cells = _cellsOf(t);
  return cells.length == _cellsOf(_unquoted(header)).length && cells.every(_delimiterCell.hasMatch);
}

List<String> _cellsOf(String row) {
  var t = row;
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|') && !t.endsWith(r'\|')) t = t.substring(0, t.length - 1);
  return t.split(_pipe);
}

/// [source] with a blank line inserted before a pipe table that is written
/// flush against the paragraph above it.
///
/// A table may not interrupt a paragraph: a header row written straight under
/// a text line is read as one more paragraph line, so the pipes show as
/// literal text (`② 按症状查的清单` followed by `| 症状 | … |`). The blank line
/// ends the paragraph first, and the table is recognised.
///
/// Only a table at the left margin, or inside a `>` quote, is moved: one
/// indented under a list item keeps its place, and fenced code is skipped.
String blankLineBeforeTables(String source) {
  if (!_mayHaveTable(source)) return source;
  final lines = source.split('\n');
  final breaks = _breaksBeforeHeaders(lines, _headerRows(lines));
  if (breaks.isEmpty) return source;
  _insertBreaks(lines, breaks);
  return lines.join('\n');
}

Set<int> _breaksBeforeHeaders(List<String> lines, Iterable<int> headers) => {
  for (final i in headers)
    if (i > 0 && _needsBreakAbove(lines[i - 1], lines[i])) i,
};

void _insertBreaks(List<String> lines, Set<int> breaks) {
  for (final i in breaks) {
    final line = lines[i];
    lines[i] = '${_quotePrefix(line)}\n$line';
  }
}

/// Whether the table header [line] is glued to the paragraph line above it.
bool _needsBreakAbove(String? previous, String line) {
  if (previous == null || previous.trim().isEmpty) return false;
  // Indented: the table belongs to the list item above it.
  if (line.startsWith(' ') || line.startsWith('\t')) return false;
  final quoted = _quotePrefix(line).isNotEmpty;
  // A quote block cannot be opened by a blank line from outside it.
  if (quoted && _quotePrefix(previous).isEmpty) return false;
  final body = _unquoted(previous).trimRight();
  if (body.isEmpty) return false;
  // These lines already end a block, so the table starts one on its own.
  return !_blockLine.hasMatch(body);
}

/// The `>` markers a blank line inside the same quote carries: `>` for
/// `> | a |`, so the table stays in the quote.
String _quotePrefix(String line) =>
    RegExp(r'^[ \t]*(?:>[ \t]?)+').firstMatch(line)?.group(0)?.trimRight() ?? '';

final _blockLine = RegExp(
  r'^(?:#{1,6}(?:[ \t]|$)'
  r'|(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)'
  r'|(?:-{3,}|\*{3,}|_{3,})[ \t]*$'
  r'|(?:`{3,}|~{3,}))',
);

/// The header row with each cell's text in `**…**`, keeping the row's quote
/// prefix, its pipes and the spaces around each cell.
String _boldRow(String line) {
  final prefix = RegExp(r'^[ \t]*(?:>[ \t]?)*').firstMatch(line)!.group(0)!;
  final body = line.substring(prefix.length);
  final parts = body.split(_pipe);
  for (var i = 0; i < parts.length; i++) {
    final cell = parts[i];
    final text = cell.trim();
    // The empty parts outside the leading / trailing pipe, and cells that
    // already have emphasis, stay as they are.
    if (text.isEmpty || text.contains('*') || text.contains('_')) continue;
    final start = cell.indexOf(text);
    parts[i] = '${cell.substring(0, start)}**$text**${cell.substring(start + text.length)}';
  }
  return prefix + parts.join('|');
}
