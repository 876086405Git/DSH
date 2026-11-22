// CSV / TSV and XLSX reading for the table preview.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/state/sheet_files.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/xlsx_builder.dart';

void main() {
  group('delimited text', () {
    test('quotes, escaped quotes, line breaks, ragged rows', () {
      final grid = parseDelimited(
        'name,note,qty\r\n'
        '"Smith, J","said ""hi""",3\r\n'
        '"multi\nline",,\n'
        'short\n'
        ',"",007\n',
      );
      expect(grid.rows, [
        ['name', 'note', 'qty'],
        ['Smith, J', 'said "hi"', '3'],
        ['multi\nline', '', ''],
        ['short'],
        ['', '', '007'],
      ]);
      expect(grid.columns, 3);
      expect(grid.truncated, isFalse);
    });

    test('a last line without a break still counts', () {
      expect(parseDelimited('a,b\n1,2').rows, [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });

    test('tabs', () {
      expect(parseDelimited('a\tb\n1\t2\n', delimiter: '\t').rows, [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });

    test('an open quote is an error, unless the text was cut short', () {
      expect(() => parseDelimited('a,"b\nc\n'), throwsA(isA<SheetFormatException>()));
      final cut = parseDelimited('a,b\n1,2\n3,"long', partial: true);
      expect(cut.rows, [
        ['a', 'b'],
        ['1', '2'],
      ]);
      expect(cut.truncated, isTrue);
      // A cut row without quotes goes too: it may be missing cells.
      expect(parseDelimited('a,b\n1,2\n3,4', partial: true).rows.length, 2);
    });

    test('row limit', () {
      final text = List.generate(30, (i) => '$i,x').join('\n');
      final grid = parseDelimited(text, maxRows: 10);
      expect(grid.rows.length, 10);
      expect(grid.truncated, isTrue);
    });

    test('BOMs and UTF-16', () {
      final utf8Bom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('地区,值')]);
      expect(decodeTableText(utf8Bom), '地区,值');
      final units = '地区,1'.codeUnits;
      final le = Uint8List.fromList([
        0xFF,
        0xFE,
        for (final u in units) ...[u & 0xFF, u >> 8],
      ]);
      expect(decodeTableText(le), '地区,1');
      final be = Uint8List.fromList([
        0xFE,
        0xFF,
        for (final u in units) ...[u >> 8, u & 0xFF],
      ]);
      expect(decodeTableText(be), '地区,1');
    });
  });

  group('xlsx', () {
    test('ST_Xstring text cells decode once without changing XML attributes or literal escapes', () {
      final grids = parseXlsx(
        buildXlsx(
          [
            const TestSheet('原_x0041_', [
              ['前_x000D_后', Inline('_x005F_x0041_'), Formula('1+1', '_x0041_')],
              ['_xD83D__xDE80_', Inline('行_x000A_二'), '_x005f_x000D_'],
              ['&amp;_x005F_x0041_', Inline('_x004G_'), '=HYPERLINK("x","y")'],
              [
                InlineRuns(['_x00', '41_', '_x000D_']),
              ],
            ]),
          ],
          richText: const ['_x00', '41_', '_x000D_'],
        ),
      );
      expect(grids.single.name, '原_x0041_');
      expect(grids.single.rows.take(3), [
        ['前\r后', '_x0041_', 'A'],
        ['🚀', '行\n二', '_x000D_'],
        ['&amp;_x0041_', '_x004G_', '=HYPERLINK("x","y")'],
      ]);
      expect(grids.single.rows[3][0], '_x0041_\r');
      expect(grids.single.rows[98][0], '_x0041_\r');
    });

    final book = buildXlsx([
      TestSheet(
        '销售',
        [
          ['地区', '一月', '增长', '日期', '已核对'],
          ['华东', 120, const Pct(0.256), DateTime(2026, 10, 24), true],
          ['华南', 98.5, const Pct(-0.031), DateTime(2026, 1, 2, 9, 30), false],
          [const Inline('内联'), 1234567, 0.1 + 0.2, null, const Formula('A1&"!"', '地区!')],
        ],
        sparse: {'F7': '远处'},
      ),
      const TestSheet('隐藏', [
        ['x'],
      ], hidden: true),
      const TestSheet('备注', [
        ['只有一格'],
      ]),
    ]);

    test('visible sheets, shared / inline / rich strings, formats', () {
      final sheets = parseXlsx(book);
      expect(sheets.map((s) => s.name), ['销售', '备注']);
      final rows = sheets.first.rows;
      expect(rows[0], ['地区', '一月', '增长', '日期', '已核对', '']);
      expect(rows[1], ['华东', '120', '25.60%', '2026-10-24', 'TRUE', '']);
      expect(rows[2], ['华南', '98.5', '-3.10%', '2026-01-02 09:30', 'FALSE', '']);
      expect(rows[3], ['内联', '1234567', '0.3', '', '地区!', '']);
      // Sparse cells keep their place; empty rows in between stay.
      expect(rows[6][5], '远处');
      expect(rows[4].every((c) => c.isEmpty), isTrue);
      // Rich runs joined, the phonetic hint left out.
      expect(rows[98][0], '富文本');
      expect(sheets[1].rows, [
        ['只有一格'],
      ]);
    });

    test('stored (uncompressed) entries read the same', () {
      final plain = buildXlsx([
        const TestSheet('A', [
          ['x', 1],
        ]),
      ], stored: true);
      expect(parseXlsx(plain).first.rows.first, ['x', '1']);
    });

    test('1904 dates', () {
      final mac = buildXlsx([
        TestSheet('A', [
          [DateTime(2020, 5, 1)],
        ]),
      ], date1904: true);
      expect(parseXlsx(mac).first.rows.first, ['2020-05-01']);
    });

    test('limits', () {
      final big = buildXlsx([
        TestSheet('A', [
          for (var i = 0; i < 40; i++) [i, 'r$i'],
        ]),
      ]);
      final grid = parseXlsx(big, maxRows: 10).first;
      expect(grid.rows.length, 10);
      expect(grid.truncated, isTrue);
    });

    test('cell budget includes the sparse rectangular output', () {
      final sparse = buildXlsx([
        const TestSheet(
          'A',
          [
            ['keep'],
          ],
          sparse: {'D4': 'far'},
        ),
      ]);
      // The original fixture also writes A99; the sparse sheet is 99 by 4.
      final grid = parseXlsx(sparse, maxCells: 200, maxRows: 100).single;
      expect(grid.rows.length * grid.columns, lessThanOrEqualTo(200));
      expect(grid.rows.length, 50);
      expect(grid.columns, 4);
      expect(grid.rows[0][0], 'keep');
      expect(grid.rows[3][3], 'far');
      expect(grid.rows[2], ['', '', '', '']);
      expect(grid.truncated, isTrue);
    });

    test('a discarded wide row does not widen the retained prefix', () {
      final sparse = buildXlsx([
        const TestSheet(
          'A',
          [
            ['keep'],
          ],
          sparse: {'Z4': 'late'},
        ),
      ]);
      final grid = parseXlsx(sparse, maxCells: 8, maxRows: 100).single;
      expect(grid.rows, [
        ['keep'],
        [''],
        [''],
      ]);
      expect(grid.truncated, isTrue);
    });

    test('visible sheets share the remaining rectangular budget', () {
      final multiple = buildXlsx([
        const TestSheet('hidden fixture', [], hidden: true),
        const TestSheet('first', [
          ['a', 'b'],
          ['c', 'd'],
        ]),
        const TestSheet(
          'second',
          [
            ['keep'],
          ],
          sparse: {'D4': 'late'},
        ),
      ]);
      final grids = parseXlsx(multiple, maxCells: 12);
      expect(grids.map((grid) => grid.name), ['first', 'second']);
      expect(grids.first.rows, [
        ['a', 'b'],
        ['c', 'd'],
      ]);
      expect(grids.last.rows, [
        ['keep'],
        [''],
        [''],
      ]);
      expect(grids.last.truncated, isTrue);
      expect(grids.fold<int>(0, (sum, grid) => sum + grid.rows.length * grid.columns), lessThanOrEqualTo(12));
    });

    test('a first row wider than the budget is left out', () {
      final wide = buildXlsx([
        const TestSheet('A', [], sparse: {'D1': 'too wide'}),
      ]);
      final grid = parseXlsx(wide, maxCells: 2).single;
      expect(grid.rows, isEmpty);
      expect(grid.truncated, isTrue);
    });

    test('not a workbook', () {
      expect(() => parseXlsx(Uint8List.fromList(utf8.encode('hello'))), throwsA(isA<SheetFormatException>()));
    });
  });

  test('number formats', () {
    expect(formatSheetNumber(3, null), '3');
    expect(formatSheetNumber(0.1 + 0.2, 'General'), '0.3');
    expect(formatSheetNumber(1234567.891, '#,##0.00'), '1,234,567.89');
    expect(formatSheetNumber(-1234.5, '#,##0'), '-1,235');
    expect(formatSheetNumber(0.5, '0%'), '50%');
    expect(formatSheetNumber(45589, 'yyyy-mm-dd'), '2024-10-24');
    expect(formatSheetNumber(45589.75, 'h:mm'), '18:00');
    expect(formatSheetNumber(0.5, '[h]:mm:ss'), '12:00:00');
    expect(formatSheetNumber(42, '"¥"#,##0.00'), '42.00');
  });
}
