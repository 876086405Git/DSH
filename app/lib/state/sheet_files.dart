// Reading CSV / TSV text and XLSX workbooks into plain string grids for the
// phone's table preview. The official preview parses them in the browser too
// (PapaParse, ExcelJS) instead of asking the Host's Office converter; this
// keeps to what a table preview needs — saved values, shared / inline / rich
// strings, number and date formats, sheet names — and no package beyond
// `dart:io`'s inflater.

import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

/// One sheet: [rows] of cell text, ragged rows padded to [columns].
class SheetGrid {
  const SheetGrid({required this.name, required this.rows, this.truncated = false});

  final String name;
  final List<List<String>> rows;

  /// Rows past the preview's limit were left out.
  final bool truncated;

  int get columns => rows.fold(0, (widest, row) => row.length > widest ? row.length : widest);
  bool get isEmpty => rows.every((row) => row.every((cell) => cell.isEmpty));
}

/// Why a sheet could not be read.
class SheetFormatException implements Exception {
  const SheetFormatException(this.message);
  final String message;

  @override
  String toString() => 'SheetFormatException: $message';
}

// ── CSV / TSV ───────────────────────────────────────────────────────────────

/// Text of a delimited file: UTF-8 (BOM dropped) or BOM-marked UTF-16.
String decodeTableText(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return _utf16(bytes.sublist(2), little: true);
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return _utf16(bytes.sublist(2), little: false);
  final start = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? 3 : 0;
  return utf8.decode(bytes.sublist(start), allowMalformed: true);
}

String _utf16(Uint8List bytes, {required bool little}) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}

/// RFC 4180 rows: quoted fields may hold the delimiter, `""` and line
/// breaks; rows may differ in length; values stay literal strings. A quote
/// left open is a [SheetFormatException] unless [partial] (the text was cut
/// at a byte limit: the unfinished last row is dropped instead).
SheetGrid parseDelimited(String text, {String delimiter = ',', int maxRows = 5000, bool partial = false}) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var fieldStarted = false;
  var truncated = false;
  final d = delimiter.codeUnitAt(0);
  var i = 0;
  final n = text.length;

  void endField() {
    row.add(field.toString());
    field.clear();
    fieldStarted = false;
  }

  bool endRow() {
    endField();
    rows.add(row);
    row = <String>[];
    if (rows.length >= maxRows) {
      truncated = true;
      return false;
    }
    return true;
  }

  while (i < n) {
    final c = text.codeUnitAt(i);
    if (quoted) {
      if (c == 0x22) {
        if (i + 1 < n && text.codeUnitAt(i + 1) == 0x22) {
          field.writeCharCode(0x22);
          i += 2;
          continue;
        }
        quoted = false;
        i++;
        continue;
      }
      field.writeCharCode(c);
      i++;
      continue;
    }
    if (c == 0x22 && !fieldStarted && field.isEmpty) {
      quoted = true;
      fieldStarted = true;
      i++;
      continue;
    }
    if (c == d) {
      endField();
      i++;
      continue;
    }
    if (c == 0x0D || c == 0x0A) {
      if (c == 0x0D && i + 1 < n && text.codeUnitAt(i + 1) == 0x0A) i++;
      i++;
      if (!endRow()) break;
      continue;
    }
    field.writeCharCode(c);
    fieldStarted = true;
    i++;
  }
  if (!truncated) {
    if (quoted) {
      if (!partial) throw const SheetFormatException('unterminated quoted field');
      // Cut inside a quoted field: the half row goes.
    } else if (field.isNotEmpty || row.isNotEmpty || fieldStarted) {
      if (partial) {
        // The last line may be cut short; keep only whole rows.
      } else {
        endRow();
      }
    }
  }
  return SheetGrid(name: '', rows: rows, truncated: truncated || partial);
}

// ── XLSX ────────────────────────────────────────────────────────────────────

/// Reads an XLSX workbook's visible sheets (saved values, not recalculated).
/// [maxCells] bounds the returned rectangles, including empty cells, across
/// the whole workbook; [maxRows] bounds each sheet.
List<SheetGrid> parseXlsx(Uint8List bytes, {int maxCells = 250000, int maxRows = 5000}) {
  final zip = _Zip(bytes);
  String? part(String name) {
    final data = zip.read(name);
    return data == null ? null : utf8.decode(data, allowMalformed: true);
  }

  final rootRels = _relationships(part('_rels/.rels'), '');
  final workbookPath =
      rootRels.values.where((r) => r.type.endsWith('/officeDocument')).map((r) => r.target).firstOrNull ??
      'xl/workbook.xml';
  final workbookXml = part(workbookPath);
  if (workbookXml == null) throw const SheetFormatException('no workbook');
  final base = workbookPath.contains('/') ? workbookPath.substring(0, workbookPath.lastIndexOf('/') + 1) : '';
  final rels = _relationships(part('${base}_rels/${workbookPath.substring(base.length)}.rels'), base);

  String? relPart(String typeSuffix) =>
      rels.values.where((r) => r.type.endsWith(typeSuffix)).map((r) => r.target).firstOrNull;

  final shared = _sharedStrings(part(relPart('/sharedStrings') ?? '${base}sharedStrings.xml'));
  final styles = _Styles.parse(part(relPart('/styles') ?? '${base}styles.xml'));

  var date1904 = false;
  final sheets = <({String name, String target})>[];
  for (final tag in _Xml(workbookXml).tags()) {
    if (tag.name == 'workbookPr') {
      final v = tag.attrs['date1904'];
      date1904 = v == '1' || v == 'true';
    } else if (tag.name == 'sheet' && !tag.closing) {
      final state = tag.attrs['state'];
      if (state == 'hidden' || state == 'veryHidden') continue;
      final id = tag.attrs['id'];
      final target = id == null ? null : rels[id]?.target;
      if (target != null) sheets.add((name: tag.attrs['name'] ?? '', target: target));
    }
  }

  final grids = <SheetGrid>[];
  var budget = maxCells;
  for (final sheet in sheets) {
    final xml = part(sheet.target);
    if (xml == null) continue;
    final grid = _sheet(sheet.name, xml, shared, styles, date1904, maxRows, budget);
    budget -= grid.rows.length * grid.columns;
    grids.add(grid);
    if (budget <= 0) break;
  }
  if (grids.isEmpty) throw const SheetFormatException('no sheets');
  return grids;
}

SheetGrid _sheet(
  String name,
  String xml,
  List<String> shared,
  _Styles styles,
  bool date1904,
  int maxRows,
  int maxCells,
) {
  final cells = <int, Map<int, String>>{};
  var truncated = false;
  var count = 0;
  int? row;
  var nextRow = 0;
  var nextCol = 0;
  int? col;
  String? type;
  int? style;
  String? value;
  StringBuffer? inline;
  StringBuffer? inlineText;
  var inValue = false;
  var inInline = false;
  var inPhonetic = false;

  void flush() {
    final r = row;
    final c = col;
    if (r == null || c == null) return;
    final text = _cellText(type, value, inline?.toString(), style, shared, styles, date1904);
    if (text.isNotEmpty) {
      (cells[r] ??= {})[c] = text;
      count++;
    }
  }

  final parser = _Xml(xml);
  loop:
  for (final token in parser.tokens()) {
    switch (token) {
      case _Tag(name: 'row', closing: false, :final attrs):
        final r = int.tryParse(attrs['r'] ?? '');
        row = r == null ? nextRow : r - 1;
        nextRow = row + 1;
        nextCol = 0;
        if (row >= maxRows) {
          truncated = true;
          break loop;
        }
      case _Tag(name: 'c', closing: false, :final attrs, :final selfClosing):
        col = _column(attrs['r']) ?? nextCol;
        nextCol = col + 1;
        if (attrs['r'] case final ref?) {
          final rr = _rowOf(ref);
          if (rr != null) row = rr;
        }
        type = attrs['t'];
        style = int.tryParse(attrs['s'] ?? '');
        value = null;
        inline = null;
        if (selfClosing) {
          flush();
          col = null;
        }
      case _Tag(name: 'c', closing: true):
        flush();
        col = null;
        if (count >= maxCells) {
          truncated = true;
          break loop;
        }
      case _Tag(name: 'v', closing: false, :final selfClosing):
        inValue = !selfClosing;
        value = '';
      case _Tag(name: 'v', closing: true):
        inValue = false;
      case _Tag(name: 'is', closing: false):
        inInline = true;
        inline = StringBuffer();
      case _Tag(name: 'is', closing: true):
        inInline = false;
      case _Tag(name: 't', closing: false, :final selfClosing) when inInline:
        inlineText = selfClosing || inPhonetic ? null : StringBuffer();
      case _Tag(name: 't', closing: true) when inInline:
        if (inlineText != null) {
          inline?.write(_xstring(inlineText.toString()));
          inlineText = null;
        }
      case _Tag(name: 'rPh', closing: false, :final selfClosing):
        inPhonetic = !selfClosing;
      case _Tag(name: 'rPh', closing: true):
        inPhonetic = false;
      case _Text(:final text):
        if (inValue) {
          value = (value ?? '') + text;
        } else if (inInline && !inPhonetic) {
          inlineText?.write(text);
        }
      default:
        break;
    }
  }

  if (cells.isEmpty) return SheetGrid(name: name, rows: const [], truncated: truncated);
  final lastRow = cells.keys.reduce((a, b) => a > b ? a : b);
  var lastCol = 0;
  var rowCount = 0;
  for (var r = 0; r <= lastRow; r++) {
    var widest = lastCol;
    for (final c in cells[r]?.keys ?? const <int>[]) {
      if (c > widest) widest = c;
    }
    // A row that would overflow the budget ends the sheet without widening it.
    if ((r + 1) * (widest + 1) > maxCells) {
      truncated = true;
      break;
    }
    lastCol = widest;
    rowCount = r + 1;
  }
  final rows = [
    for (var r = 0; r < rowCount; r++) [for (var c = 0; c <= lastCol; c++) cells[r]?[c] ?? ''],
  ];
  return SheetGrid(name: name, rows: rows, truncated: truncated);
}

String _cellText(
  String? type,
  String? value,
  String? inline,
  int? style,
  List<String> shared,
  _Styles styles,
  bool date1904,
) {
  switch (type) {
    case 's':
      final i = int.tryParse(value ?? '');
      return i != null && i >= 0 && i < shared.length ? shared[i] : '';
    case 'inlineStr':
      return inline ?? _xstring(value ?? '');
    case 'b':
      return value == '1'
          ? 'TRUE'
          : value == '0'
          ? 'FALSE'
          : value ?? '';
    case 'str':
      return _xstring(value ?? '');
    case 'e':
      return value ?? '';
  }
  final raw = value;
  if (raw == null || raw.isEmpty) return inline ?? '';
  final number = double.tryParse(raw);
  if (number == null) return raw;
  return formatSheetNumber(number, styles.formatOf(style), date1904: date1904);
}

// ST_Xstring belongs to each text element. Decode once before joining rich
// runs: _x005F_x0041_ is literal _x0041_, not A; separate runs must not create
// a new escape by concatenation. XML attributes/entities are unchanged.
String _xstring(String value) => value.replaceAllMapped(
  RegExp(r'_x([0-9a-fA-F]{4})_'),
  (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
);

/// A saved number as its cell's number format shows it (the common cases:
/// dates and times, percentages, fixed decimals, thousands separators).
String formatSheetNumber(double value, String? format, {bool date1904 = false}) {
  final code = format ?? 'General';
  final kind = _formatKind(code);
  switch (kind) {
    case _NumberKind.date || _NumberKind.dateTime || _NumberKind.time:
      final epoch = date1904 ? DateTime.utc(1904) : DateTime.utc(1899, 12, 30);
      final ms = (value * Duration.millisecondsPerDay).round();
      final at = epoch.add(Duration(milliseconds: ms));
      String two(int v) => v.toString().padLeft(2, '0');
      final date = '${at.year}-${two(at.month)}-${two(at.day)}';
      final seconds = RegExp('s', caseSensitive: false).hasMatch(_stripLiterals(code));
      final time = seconds
          ? '${two(at.hour)}:${two(at.minute)}:${two(at.second)}'
          : '${two(at.hour)}:${two(at.minute)}';
      return switch (kind) {
        _NumberKind.date => date,
        _NumberKind.time => time,
        _ => '$date $time',
      };
    case _NumberKind.percent:
      return '${_fixed(value * 100, _decimals(code), grouped: false)}%';
    case _NumberKind.fixed:
      return _fixed(value, _decimals(code), grouped: code.contains(','));
    case _NumberKind.general:
      return _general(value);
  }
}

enum _NumberKind { general, fixed, percent, date, time, dateTime }

String _stripLiterals(String code) =>
    code.replaceAll(RegExp(r'"[^"]*"'), '').replaceAll(RegExp(r'\[[^\]]*\]'), '').replaceAll(RegExp(r'\\.'), '');

_NumberKind _formatKind(String code) {
  if (code == 'General' || code == '@' || code.isEmpty) return _NumberKind.general;
  final bare = _stripLiterals(code.split(';').first);
  final hasDate = RegExp('[dy]', caseSensitive: false).hasMatch(bare) || RegExp('m{3,}').hasMatch(bare);
  final hasTime = RegExp('[hs]', caseSensitive: false).hasMatch(bare);
  if (hasDate && hasTime) return _NumberKind.dateTime;
  if (hasDate) return _NumberKind.date;
  if (hasTime) return _NumberKind.time;
  if (bare.contains('%')) return _NumberKind.percent;
  if (bare.contains('0') || bare.contains('#')) return _NumberKind.fixed;
  return _NumberKind.general;
}

int _decimals(String code) {
  final bare = _stripLiterals(code.split(';').first);
  final dot = bare.indexOf('.');
  if (dot < 0) return 0;
  var n = 0;
  for (var i = dot + 1; i < bare.length && (bare[i] == '0' || bare[i] == '#'); i++) {
    n++;
  }
  return n;
}

String _fixed(double value, int decimals, {required bool grouped}) {
  final text = value.toStringAsFixed(decimals);
  if (!grouped) return text;
  final negative = text.startsWith('-');
  final body = negative ? text.substring(1) : text;
  final dot = body.indexOf('.');
  final whole = dot < 0 ? body : body.substring(0, dot);
  final rest = dot < 0 ? '' : body.substring(dot);
  final out = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) out.write(',');
    out.write(whole[i]);
  }
  return '${negative ? '-' : ''}$out$rest';
}

/// Excel's General: integers plainly, others to 10 significant digits.
String _general(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e15) return value.toInt().toString();
  var text = value.toStringAsPrecision(10);
  if (text.contains('e')) return text;
  if (text.contains('.')) text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  return text;
}

/// `B12` → 1 (zero-based column).
int? _column(String? ref) {
  if (ref == null) return null;
  var col = 0;
  var any = false;
  for (final unit in ref.toUpperCase().codeUnits) {
    if (unit < 0x41 || unit > 0x5A) break;
    col = col * 26 + (unit - 0x40);
    any = true;
  }
  return any ? col - 1 : null;
}

/// `B12` → 11 (zero-based row).
int? _rowOf(String ref) {
  final digits = RegExp(r'\d+').firstMatch(ref)?.group(0);
  final n = digits == null ? null : int.tryParse(digits);
  return n == null ? null : n - 1;
}

/// Shared strings: each `<si>`'s text (rich runs joined, phonetic hints
/// left out).
List<String> _sharedStrings(String? xml) {
  if (xml == null) return const [];
  final out = <String>[];
  StringBuffer? current;
  StringBuffer? textRun;
  var phonetic = false;
  for (final token in _Xml(xml).tokens()) {
    switch (token) {
      case _Tag(name: 'si', closing: false, :final selfClosing):
        if (selfClosing) {
          out.add('');
        } else {
          current = StringBuffer();
        }
      case _Tag(name: 'si', closing: true):
        out.add(current?.toString() ?? '');
        current = null;
      case _Tag(name: 'rPh', closing: false, :final selfClosing):
        phonetic = !selfClosing;
      case _Tag(name: 'rPh', closing: true):
        phonetic = false;
      case _Tag(name: 't', closing: false, :final selfClosing):
        textRun = selfClosing || phonetic ? null : StringBuffer();
      case _Tag(name: 't', closing: true):
        if (textRun != null) {
          current?.write(_xstring(textRun.toString()));
          textRun = null;
        }
      case _Text(:final text):
        textRun?.write(text);
      default:
        break;
    }
  }
  return out;
}

/// Number formats by cell style index.
class _Styles {
  _Styles(this._formats);

  final List<String?> _formats;

  String? formatOf(int? style) => style == null || style < 0 || style >= _formats.length ? null : _formats[style];

  static const _builtIn = <int, String>{
    0: 'General',
    1: '0',
    2: '0.00',
    3: '#,##0',
    4: '#,##0.00',
    9: '0%',
    10: '0.00%',
    11: '0.00E+00',
    14: 'yyyy-mm-dd',
    15: 'd-mmm-yy',
    16: 'd-mmm',
    17: 'mmm-yy',
    18: 'h:mm AM/PM',
    19: 'h:mm:ss AM/PM',
    20: 'h:mm',
    21: 'h:mm:ss',
    22: 'yyyy-mm-dd h:mm',
    37: '#,##0 ;(#,##0)',
    38: '#,##0 ;[Red](#,##0)',
    39: '#,##0.00;(#,##0.00)',
    40: '#,##0.00;[Red](#,##0.00)',
    45: 'mm:ss',
    46: '[h]:mm:ss',
    47: 'mmss.0',
    48: '##0.0E+0',
    49: '@',
  };

  static _Styles parse(String? xml) {
    if (xml == null) return _Styles(const []);
    final custom = <int, String>{};
    final formats = <String?>[];
    var inXfs = false;
    for (final tag in _Xml(xml).tags()) {
      switch (tag.name) {
        case 'numFmt' when !tag.closing:
          final id = int.tryParse(tag.attrs['numFmtId'] ?? '');
          final code = tag.attrs['formatCode'];
          if (id != null && code != null) custom[id] = code;
        case 'cellXfs':
          inXfs = !tag.closing && !tag.selfClosing;
        case 'xf' when inXfs && !tag.closing:
          final id = int.tryParse(tag.attrs['numFmtId'] ?? '0') ?? 0;
          formats.add(
            custom[id] ?? _builtIn[id] ?? (id >= 27 && id <= 36 || id >= 50 && id <= 58 ? 'yyyy-mm-dd' : null),
          );
      }
    }
    return _Styles(formats);
  }
}

class _Rel {
  const _Rel(this.type, this.target);
  final String type;
  final String target;
}

/// A `.rels` part: id → (type, target resolved against [base]).
Map<String, _Rel> _relationships(String? xml, String base) {
  if (xml == null) return const {};
  final out = <String, _Rel>{};
  for (final tag in _Xml(xml).tags()) {
    if (tag.name != 'Relationship' || tag.closing) continue;
    final id = tag.attrs['Id'];
    final target = tag.attrs['Target'];
    if (id == null || target == null || tag.attrs['TargetMode'] == 'External') continue;
    out[id] = _Rel(tag.attrs['Type'] ?? '', _resolve(base, target));
  }
  return out;
}

String _resolve(String base, String target) {
  final joined = target.startsWith('/') ? target.substring(1) : '$base$target';
  final parts = <String>[];
  for (final segment in joined.split('/')) {
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else if (segment.isNotEmpty && segment != '.') {
      parts.add(segment);
    }
  }
  return parts.join('/');
}

// ── Minimal XML tokens ──────────────────────────────────────────────────────

sealed class _Token {
  const _Token();
}

class _Tag extends _Token {
  const _Tag(this.name, this.attrs, {this.closing = false, this.selfClosing = false});

  /// Local name (namespace prefix dropped).
  final String name;
  final Map<String, String> attrs;
  final bool closing;
  final bool selfClosing;
}

class _Text extends _Token {
  const _Text(this.text);
  final String text;
}

/// Just enough XML for OOXML parts: elements, attributes, text, entities,
/// CDATA; comments, declarations and processing instructions skipped.
class _Xml {
  _Xml(this.source);

  final String source;

  Iterable<_Tag> tags() => tokens().whereType<_Tag>();

  Iterable<_Token> tokens() sync* {
    final s = source;
    var i = 0;
    final n = s.length;
    while (i < n) {
      final lt = s.indexOf('<', i);
      if (lt < 0) {
        if (i < n) yield _Text(_entities(s.substring(i)));
        return;
      }
      if (lt > i) yield _Text(_entities(s.substring(i, lt)));
      if (s.startsWith('<!--', lt)) {
        final end = s.indexOf('-->', lt + 4);
        i = end < 0 ? n : end + 3;
        continue;
      }
      if (s.startsWith('<![CDATA[', lt)) {
        final end = s.indexOf(']]>', lt + 9);
        yield _Text(s.substring(lt + 9, end < 0 ? n : end));
        i = end < 0 ? n : end + 3;
        continue;
      }
      if (s.startsWith('<?', lt) || s.startsWith('<!', lt)) {
        final end = s.indexOf('>', lt);
        i = end < 0 ? n : end + 1;
        continue;
      }
      final end = _tagEnd(s, lt);
      if (end < 0) return;
      yield _parseTag(s.substring(lt + 1, end));
      i = end + 1;
    }
  }

  /// The `>` closing the tag at [start], skipping quoted attribute values.
  static int _tagEnd(String s, int start) {
    String? quote;
    for (var i = start + 1; i < s.length; i++) {
      final c = s[i];
      if (quote != null) {
        if (c == quote) quote = null;
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (c == '>') {
        return i;
      }
    }
    return -1;
  }

  static final _attr = RegExp(r'''([^\s=/]+)\s*=\s*("([^"]*)"|'([^']*)')''');

  static _Tag _parseTag(String inner) {
    var body = inner.trim();
    final closing = body.startsWith('/');
    if (closing) body = body.substring(1).trim();
    final selfClosing = body.endsWith('/');
    if (selfClosing) body = body.substring(0, body.length - 1).trim();
    final space = body.indexOf(RegExp(r'\s'));
    var name = space < 0 ? body : body.substring(0, space);
    final colon = name.indexOf(':');
    if (colon >= 0) name = name.substring(colon + 1);
    final attrs = <String, String>{};
    if (space >= 0) {
      for (final m in _attr.allMatches(body.substring(space))) {
        var key = m.group(1)!;
        final keyColon = key.indexOf(':');
        if (keyColon >= 0 && !key.startsWith('xmlns')) key = key.substring(keyColon + 1);
        attrs[key] = _entities(m.group(3) ?? m.group(4) ?? '');
      }
    }
    return _Tag(name, attrs, closing: closing, selfClosing: selfClosing);
  }

  static final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#\d+|lt|gt|amp|quot|apos);');

  static String _entities(String text) {
    if (!text.contains('&')) return text;
    return text.replaceAllMapped(_entity, (m) {
      final e = m.group(1)!;
      return switch (e) {
        'lt' => '<',
        'gt' => '>',
        'amp' => '&',
        'quot' => '"',
        'apos' => "'",
        _ when e.startsWith('#x') => String.fromCharCode(int.parse(e.substring(2), radix: 16)),
        _ => String.fromCharCode(int.parse(e.substring(1))),
      };
    });
  }
}

// ── ZIP (stored and deflated entries, no ZIP64) ─────────────────────────────

class _Zip {
  _Zip(this.bytes) {
    final data = ByteData.sublistView(bytes);
    var eocd = -1;
    final floor = bytes.length - 22 - 0xFFFF;
    for (var i = bytes.length - 22; i >= 0 && i >= floor; i--) {
      if (data.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const SheetFormatException('not a zip archive');
    final count = data.getUint16(eocd + 10, Endian.little);
    var at = data.getUint32(eocd + 16, Endian.little);
    for (var k = 0; k < count; k++) {
      if (at + 46 > bytes.length || data.getUint32(at, Endian.little) != 0x02014b50) {
        throw const SheetFormatException('broken zip directory');
      }
      final method = data.getUint16(at + 10, Endian.little);
      final compressed = data.getUint32(at + 20, Endian.little);
      final size = data.getUint32(at + 24, Endian.little);
      final nameLength = data.getUint16(at + 28, Endian.little);
      final extraLength = data.getUint16(at + 30, Endian.little);
      final commentLength = data.getUint16(at + 32, Endian.little);
      final local = data.getUint32(at + 42, Endian.little);
      final name = utf8.decode(bytes.sublist(at + 46, at + 46 + nameLength), allowMalformed: true);
      _entries[name.toLowerCase()] = (method: method, compressed: compressed, size: size, local: local);
      at += 46 + nameLength + extraLength + commentLength;
    }
  }

  final Uint8List bytes;
  final Map<String, ({int method, int compressed, int size, int local})> _entries = {};

  /// Entry [name] (case-insensitive, no leading `/`); null when missing.
  Uint8List? read(String name) {
    final entry = _entries[(name.startsWith('/') ? name.substring(1) : name).toLowerCase()];
    if (entry == null) return null;
    final data = ByteData.sublistView(bytes);
    final at = entry.local;
    if (at + 30 > bytes.length || data.getUint32(at, Endian.little) != 0x04034b50) {
      throw const SheetFormatException('broken zip entry');
    }
    final start = at + 30 + data.getUint16(at + 26, Endian.little) + data.getUint16(at + 28, Endian.little);
    final end = start + entry.compressed;
    if (end > bytes.length) throw const SheetFormatException('truncated zip entry');
    final raw = Uint8List.sublistView(bytes, start, end);
    return switch (entry.method) {
      0 => raw,
      8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(raw)),
      _ => throw const SheetFormatException('unsupported zip compression'),
    };
  }
}
