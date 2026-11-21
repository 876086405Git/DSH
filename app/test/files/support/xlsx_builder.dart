// A tiny XLSX writer for tests: the parts Excel writes (content types,
// relationships, workbook, shared strings, styles, sheets) zipped with
// deflate, so the phone's reader sees what a real workbook looks like.

import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

/// A percentage cell (style `0.00%`).
class Pct {
  const Pct(this.value);
  final double value;
}

/// An inline-string cell (`t="inlineStr"`).
class Inline {
  const Inline(this.text);
  final String text;
}

/// Separate text elements in an inline rich string.
class InlineRuns {
  const InlineRuns(this.runs);
  final List<String> runs;
}

/// A formula cell with its saved string result (`t="str"`).
class Formula {
  const Formula(this.formula, this.result);
  final String formula;
  final String result;
}

/// One sheet for [buildXlsx].
class TestSheet {
  const TestSheet(this.name, this.rows, {this.hidden = false, this.sparse = const {}});

  final String name;

  /// Cell values: String, num, bool, DateTime, [Pct], [Inline], [InlineRuns], [Formula],
  /// null (no cell).
  final List<List<Object?>> rows;
  final bool hidden;

  /// Extra cells by reference (`D9`), written after [rows].
  final Map<String, Object?> sparse;
}

String _esc(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

String _col(int i) {
  var n = i + 1;
  final out = <int>[];
  while (n > 0) {
    out.add(0x41 + (n - 1) % 26);
    n = (n - 1) ~/ 26;
  }
  return String.fromCharCodes(out.reversed);
}

/// The workbook as XLSX bytes. [richText] supplies separate runs for the
/// extra shared string; by default it has two runs and a phonetic hint.
Uint8List buildXlsx(List<TestSheet> sheets, {bool date1904 = false, bool stored = false, List<String>? richText}) {
  final shared = <String>[];
  int sharedIndex(String s) {
    final i = shared.indexOf(s);
    if (i >= 0) return i;
    shared.add(s);
    return shared.length - 1;
  }

  String cell(String ref, Object? value) {
    switch (value) {
      case null:
        return '';
      case String s:
        return '<c r="$ref" t="s"><v>${sharedIndex(s)}</v></c>';
      case bool b:
        return '<c r="$ref" t="b"><v>${b ? 1 : 0}</v></c>';
      case DateTime d:
        final epoch = date1904 ? DateTime.utc(1904) : DateTime.utc(1899, 12, 30);
        final serial = DateTime.utc(d.year, d.month, d.day, d.hour, d.minute).difference(epoch).inMinutes / 1440;
        final style = d.hour == 0 && d.minute == 0 ? 1 : 3;
        return '<c r="$ref" s="$style"><v>$serial</v></c>';
      case Pct p:
        return '<c r="$ref" s="2"><v>${p.value}</v></c>';
      case Inline i:
        return '<c r="$ref" t="inlineStr"><is><t>${_esc(i.text)}</t></is></c>';
      case InlineRuns i:
        return '<c r="$ref" t="inlineStr"><is>${[for (final run in i.runs) '<r><t>${_esc(run)}</t></r>'].join()}</is></c>';
      case Formula f:
        return '<c r="$ref" t="str"><f>${_esc(f.formula)}</f><v>${_esc(f.result)}</v></c>';
      case num n:
        return '<c r="$ref"><v>$n</v></c>';
    }
    return '';
  }

  final files = <String, String>{};
  final sheetXml = <String>[];
  for (final sheet in sheets) {
    final rows = StringBuffer();
    for (final (r, row) in sheet.rows.indexed) {
      rows.write('<row r="${r + 1}">');
      for (final (c, value) in row.indexed) {
        rows.write(cell('${_col(c)}${r + 1}', value));
      }
      rows.write('</row>');
    }
    for (final MapEntry(:key, :value) in sheet.sparse.entries) {
      final r = RegExp(r'\d+').firstMatch(key)!.group(0);
      rows.write('<row r="$r">${cell(key, value)}</row>');
    }
    sheetXml.add(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheetData>$rows</sheetData></worksheet>',
    );
  }
  final richIndex = shared.length;
  files['[Content_Types].xml'] =
      '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="xml" ContentType="application/xml"/></Types>';
  files['_rels/.rels'] =
      '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      '</Relationships>';
  files['xl/workbook.xml'] =
      '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<workbookPr${date1904 ? ' date1904="1"' : ''}/><sheets>'
      '${[for (final (i, s) in sheets.indexed) '<sheet name="${_esc(s.name)}" sheetId="${i + 1}"${s.hidden ? ' state="hidden"' : ''} r:id="rId${i + 1}"/>'].join()}'
      '</sheets></workbook>';
  files['xl/_rels/workbook.xml.rels'] =
      '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '${[for (var i = 0; i < sheets.length; i++) '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>'].join()}'
      '<Relationship Id="rId90" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>'
      '<Relationship Id="rId91" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="/xl/styles.xml"/>'
      '</Relationships>';
  files['xl/sharedStrings.xml'] =
      '<?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="${shared.length + 1}">'
      '${[for (final s in shared) '<si><t xml:space="preserve">${_esc(s)}</t></si>'].join()}'
      '${richText == null ? '<si><r><rPr><b/></rPr><t>富</t></r><r><t>文本</t></r><rPh sb="0" eb="1"><t>ふ</t></rPh></si>' : '<si>${[for (final run in richText) '<r><t>${_esc(run)}</t></r>'].join()}</si>'}'
      '</sst>';
  files['xl/styles.xml'] =
      '<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy-mm-dd hh:mm"/></numFmts>'
      '<cellStyleXfs count="1"><xf numFmtId="0"/></cellStyleXfs>'
      '<cellXfs count="4"><xf numFmtId="0"/><xf numFmtId="14" applyNumberFormat="1"/>'
      '<xf numFmtId="10" applyNumberFormat="1"/><xf numFmtId="164" applyNumberFormat="1"/></cellXfs>'
      '</styleSheet>';
  for (final (i, xml) in sheetXml.indexed) {
    files['xl/worksheets/sheet${i + 1}.xml'] = xml;
  }
  // The rich string is referenced from the first sheet's A99.
  files['xl/worksheets/sheet1.xml'] = files['xl/worksheets/sheet1.xml']!.replaceFirst(
    '</sheetData>',
    '<row r="99"><c r="A99" t="s"><v>$richIndex</v></c></row></sheetData>',
  );
  return _zip(files, stored: stored);
}

Uint8List _zip(Map<String, String> files, {required bool stored}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  for (final MapEntry(:key, :value) in files.entries) {
    final name = utf8.encode(key);
    final raw = utf8.encode(value);
    final data = stored ? raw : ZLibEncoder(raw: true).convert(raw);
    final offset = out.length;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(8, stored ? 0 : 8, Endian.little)
      ..setUint32(18, data.length, Endian.little)
      ..setUint32(22, raw.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(data);
    final entry = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(10, stored ? 0 : 8, Endian.little)
      ..setUint32(20, data.length, Endian.little)
      ..setUint32(24, raw.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(entry.buffer.asUint8List())
      ..add(name);
    count++;
  }
  final start = out.length;
  final directory = central.takeBytes();
  out.add(directory);
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, directory.length, Endian.little)
    ..setUint32(16, start, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.takeBytes();
}
