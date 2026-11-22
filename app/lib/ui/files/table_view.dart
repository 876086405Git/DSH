// A read-only spreadsheet view for CSV / TSV / XLSX previews — row numbers down
// the left, the first row pinned as the header, both axes scrolling, a tapped
// cell's full text in a bar at the bottom.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/sheet_files.dart';
import '../theme/theme.dart';

/// `0` → `A`, `27` → `AB`.
String columnLetters(int index) {
  var n = index + 1;
  final out = StringBuffer();
  final letters = <int>[];
  while (n > 0) {
    final r = (n - 1) % 26;
    letters.add(0x41 + r);
    n = (n - 1) ~/ 26;
  }
  for (final c in letters.reversed) {
    out.writeCharCode(c);
  }
  return out.toString();
}

final _numeric = RegExp(r'^[-+]?(\d{1,3}(,\d{3})+|\d+)?(\.\d+)?%?$');

/// Whether a cell reads as a number (right-aligned, tabular figures).
bool isNumericCell(String text) => text.isNotEmpty && text != '.' && _numeric.hasMatch(text.trim());

/// Row numbers on the left, the first row pinned as the header, scrolling both
/// ways; a tapped cell shows its full text at the bottom.
class SheetTable extends StatefulWidget {
  const SheetTable({super.key, required this.grid, this.maxColumns = 200});

  final SheetGrid grid;

  /// Columns past this are left out (a note says so).
  final int maxColumns;

  static const rowHeight = 36.0;
  static const cellInset = 12.0;
  static const minColumn = 56.0;
  static const maxColumn = 280.0;

  @override
  State<SheetTable> createState() => _SheetTableState();
}

class _SheetTableState extends State<SheetTable> {
  final _headerH = ScrollController();
  final _bodyH = ScrollController();
  final _gutterV = ScrollController();
  final _bodyV = ScrollController();

  List<double>? _widths;
  double? _gutter;
  TextScaler? _scaler;
  (int row, int col)? _selected;

  @override
  void initState() {
    super.initState();
    _bodyH.addListener(() {
      if (_headerH.hasClients && _headerH.offset != _bodyH.offset) {
        _headerH.jumpTo(_bodyH.offset);
      }
    });
    _bodyV.addListener(() {
      if (_gutterV.hasClients && _gutterV.offset != _bodyV.offset) {
        _gutterV.jumpTo(_bodyV.offset);
      }
    });
  }

  @override
  void didUpdateWidget(SheetTable old) {
    super.didUpdateWidget(old);
    if (!identical(old.grid, widget.grid)) {
      _widths = null;
      _selected = null;
    }
  }

  @override
  void dispose() {
    _headerH.dispose();
    _bodyH.dispose();
    _gutterV.dispose();
    _bodyV.dispose();
    super.dispose();
  }

  int get _columns => math.min(widget.grid.columns, widget.maxColumns);

  TextStyle _cellStyle(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 13.5, height: 1.3);

  /// Column widths from the header and the first rows' text.
  void _measure(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    if (_widths != null && _scaler == scaler) return;
    _scaler = scaler;
    final style = _cellStyle(context);
    final bold = style.copyWith(fontWeight: FontWeight.w600);
    final rows = widget.grid.rows;
    final sample = math.min(rows.length, 120);
    final painter = TextPainter(textDirection: TextDirection.ltr, maxLines: 1, textScaler: scaler);
    final widths = List<double>.filled(_columns, SheetTable.minColumn);
    for (var c = 0; c < widths.length; c++) {
      var widest = 0.0;
      for (var r = 0; r < sample; r++) {
        final row = rows[r];
        final text = c < row.length ? row[c] : '';
        if (text.isEmpty) continue;
        painter.text = TextSpan(text: text.length > 60 ? text.substring(0, 60) : text, style: r == 0 ? bold : style);
        painter.layout();
        widest = math.max(widest, painter.width);
      }
      widths[c] = (widest + SheetTable.cellInset * 2 + 1).clamp(SheetTable.minColumn, SheetTable.maxColumn);
    }
    painter.text = TextSpan(
      text: '${math.max(rows.length, 1)}',
      style: AppType.tabular(Theme.of(context).textTheme.bodySmall!),
    );
    painter.layout();
    _gutter = math.max(36, painter.width + 20);
    painter.dispose();
    _widths = widths;
  }

  @override
  Widget build(BuildContext context) {
    _measure(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dsh = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final widths = _widths!;
    final gutter = _gutter!;
    final total = widths.fold(0.0, (a, b) => a + b);
    final rows = widget.grid.rows;
    final body = rows.length > 1 ? rows.length - 1 : 0;
    final line = scheme.outlineVariant.withValues(alpha: dark ? 0.35 : 0.55);
    final headerFill = dark ? Colors.white.withValues(alpha: 0.06) : scheme.onSurface.withValues(alpha: 0.04);
    final style = _cellStyle(context);
    final numberStyle = AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: dsh.textTertiary));

    Widget cell(int r, int c, {bool header = false}) {
      final row = rows[r];
      final text = c < row.length ? row[c] : '';
      final numeric = !header && isNumericCell(text);
      final selected = _selected == (r, c);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _selected = selected ? null : (r, c));
        },
        child: Container(
          width: widths[c],
          height: SheetTable.rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: SheetTable.cellInset),
          alignment: numeric ? Alignment.centerRight : Alignment.centerLeft,
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withValues(alpha: 0.10) : null,
            border: Border(
              right: BorderSide(color: line, width: 0.5),
              bottom: BorderSide(color: line, width: 0.5),
            ),
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: header
                ? style.copyWith(fontWeight: FontWeight.w600)
                : numeric
                ? AppType.tabular(style)
                : style,
          ),
        ),
      );
    }

    Widget numberCell(String label, {Color? fill}) => Container(
      width: gutter,
      height: SheetTable.rowHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        border: Border(
          right: BorderSide(color: line, width: 0.5),
          bottom: BorderSide(color: line, width: 0.5),
        ),
      ),
      child: Text(label, maxLines: 1, style: numberStyle),
    );

    final header = rows.isEmpty
        ? const SizedBox.shrink()
        : Row(children: [for (var c = 0; c < widths.length; c++) cell(0, c, header: true)]);

    final table = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ColoredBox(
          color: headerFill,
          child: Row(
            children: [
              numberCell('1'),
              Expanded(
                child: SingleChildScrollView(
                  controller: _headerH,
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  child: header,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: gutter,
                child: ListView.builder(
                  controller: _gutterV,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemExtent: SheetTable.rowHeight,
                  itemCount: body,
                  itemBuilder: (context, i) => numberCell('${i + 2}', fill: headerFill),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: _bodyH,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: total,
                    child: ListView.builder(
                      controller: _bodyV,
                      padding: EdgeInsets.zero,
                      itemExtent: SheetTable.rowHeight,
                      itemCount: body,
                      itemBuilder: (context, i) =>
                          Row(children: [for (var c = 0; c < widths.length; c++) cell(i + 1, c)]),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    final selected = _selected;
    final picked = selected == null
        ? null
        : (selected.$2 < rows[selected.$1].length ? rows[selected.$1][selected.$2] : '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: table),
        if (selected != null) _CellBar(label: '${columnLetters(selected.$2)}${selected.$1 + 1}', text: picked ?? ''),
      ],
    );
  }
}

/// The tapped cell: its address and full text (selectable).
class _CellBar extends StatelessWidget {
  const _CellBar({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6), width: 0.5)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, maxHeight: 132),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 48,
                child: Text(label, style: AppType.monoLabel(color: dsh.textTertiary)),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    text.isEmpty ? l10n.botsEmptyCell : text,
                    style: theme.textTheme.bodyMedium?.copyWith(color: text.isEmpty ? dsh.textTertiary : null),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
