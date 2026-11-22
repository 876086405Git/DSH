// Table headers set in bold, the way GitHub and the chat apps show them.
// gpt_markdown hands the header style to its cells as an inherited default,
// which the reply's explicit body weight overrides, so the header cells are
// marked up as bold before parsing instead.

/// [source] with the header cells of every pipe table wrapped in `**…**`.
///
/// Code fences are skipped; a cell that is empty or already carries
/// emphasis markers is left as written.
String boldTableHeaders(String source) {
  if (!source.contains('|') || !source.contains('-')) return source;
  final lines = source.split('\n');
  String? fence;
  var changed = false;
  for (var i = 0; i + 1 < lines.length; i++) {
    final line = lines[i];
    final marker = _fence.firstMatch(line)?.group(1);
    if (fence != null) {
      final close = _fenceClose.firstMatch(line)?.group(1);
      if (close != null && close[0] == fence[0] && close.length >= fence.length) fence = null;
      continue;
    }
    if (marker != null) {
      fence = marker;
      continue;
    }
    if (!line.contains('|') || !_isDelimiterRow(lines[i + 1], line)) continue;
    final bolded = _boldRow(line);
    if (bolded != line) {
      lines[i] = bolded;
      changed = true;
    }
    i += 1;
  }
  return changed ? lines.join('\n') : source;
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
  if (!source.contains('|') || !source.contains('-')) return source;
  final lines = source.split('\n');
  final out = <String>[];
  String? fence;
  var changed = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final marker = _fence.firstMatch(line)?.group(1);
    if (fence != null) {
      final close = _fenceClose.firstMatch(line)?.group(1);
      if (close != null && close[0] == fence[0] && close.length >= fence.length) fence = null;
      out.add(line);
      continue;
    }
    if (marker != null) {
      fence = marker;
      out.add(line);
      continue;
    }
    if (i + 1 < lines.length &&
        line.contains('|') &&
        _isDelimiterRow(lines[i + 1], line) &&
        _needsBreakAbove(out.isEmpty ? null : out.last, line)) {
      out.add(_quotePrefix(line));
      changed = true;
    }
    out.add(line);
  }
  return changed ? out.join('\n') : source;
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
