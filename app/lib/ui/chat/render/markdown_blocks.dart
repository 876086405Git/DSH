// List items with one marker gutter for bullets and numbers, and `<details>`
// as a disclosure, for [MarkdownBody].

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../../l10n/l10n.dart';
import '../../common/smooth_size.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// Where list items' text starts, in ems of its text: the same column for
/// bullets and numbers, so a nested list's markers sit under its parent's
/// text. A list whose numbers reach `10.` (or `100.`) widens its own column
/// to its widest number plus the gap, for all of its items — every number
/// shows whole, right-aligned against the text, and the list's text stays on
/// one column. Nothing outside that list moves.
const listGutterEm = 1.375;

/// Gap between a number's right edge and the item's text, in ems.
const _markerGapEm = 0.375;

/// Where a list item put its marker and its text (for geometry tests).
@visibleForTesting
abstract interface class ListItemGeometry {
  /// The number's painted rect in the item's coordinates; null for a bullet.
  Rect? get markerRect;

  /// Where the item's text starts, from the item's left edge.
  double get textStart;
}

/// Marks an assistant reply's Markdown drawn under a theme pack: the builders
/// below it take the pack's reply styling (bullets, headings, code frames).
/// Other Markdown (documents, thinking) has no scope and keeps the plain look.
class MarkdownReplyScope extends InheritedWidget {
  const MarkdownReplyScope({super.key, this.reply = true, required super.child});

  /// False ends the scope for Markdown nested in a reply (a card's own text).
  final bool reply;

  static bool of(BuildContext context) => context.getInheritedWidgetOfExactType<MarkdownReplyScope>()?.reply ?? false;

  @override
  bool updateShouldNotify(MarkdownReplyScope oldWidget) => false;
}

/// The gpt_markdown list builders. Static, so they keep their identity.
abstract final class MarkdownLists {
  static Widget unordered(BuildContext context, Widget child, GptMarkdownConfig config) => MarkdownTextScaling.wrap(
    ListItem(marker: null, style: config.style ?? DefaultTextStyle.of(context).style, child: child),
    enabled: config.blocksRenderDirectly,
  );

  static Widget ordered(BuildContext context, String no, Widget child, GptMarkdownConfig config) =>
      MarkdownTextScaling.wrap(
        ListItem(marker: '$no.', style: config.style ?? DefaultTextStyle.of(context).style, child: child),
        enabled: config.blocksRenderDirectly,
      );
}

/// One list item as a hanging indent: a bullet centred on the first line, or
/// a number right-aligned on its baseline, and every line of the text on the
/// [listGutterEm] column.
class ListItem extends StatelessWidget {
  const ListItem({super.key, required this.marker, required this.style, required this.child});

  /// `3.` for a numbered item, null for a bullet.
  final String? marker;

  /// The item's text style (size, line height, colour).
  final TextStyle style;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final fontSize = scaler.scale(style.fontSize ?? 16);
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final label = marker;
    return _ListItemBox(
      bullet: label == null && MarkdownReplyScope.of(context)
          ? DshThemeStyle.of(context).components.bulletStyle
          : ThemeBulletStyle.dot,
      fontSize: fontSize,
      listMarkerLength: label == null ? 0 : _listMarkerLength(context),
      dotRise: _dotRise(DefaultTextStyle.of(context).style, scaler),
      marker: label == null
          ? null
          : TextSpan(
              text: label,
              style: AppType.tabular(style.copyWith(color: color, fontWeight: FontWeight.w400)),
            ),
      textScaler: scaler,
      dotColor: color,
      textDirection: Directionality.of(context),
      child: child,
    );
  }
}

extension on ListItem {
  /// For a top-level list (a column of its items): the longest number in
  /// this item's list, in characters. When the list reaches `10.`, every item
  /// rebuilds with a new value here and lays out again on the wider column in
  /// the same frame. 0 elsewhere (a list in a paragraph realigns itself when
  /// an item joins).
  int _listMarkerLength(BuildContext context) {
    Element? parent;
    context.visitAncestorElements((element) {
      parent = element;
      return false;
    });
    final column = parent?.widget;
    if (column is! Flex || column.direction != Axis.vertical) return 0;
    final children = column.children;
    final index = children.indexWhere((child) => identical(child, this));
    if (index == -1) return 0;
    final numbered = marker != null;
    bool mate(Widget widget) => widget is ListItem && (widget.marker != null) == numbered;
    var longest = 0;
    for (var k = index; k >= 0 && mate(children[k]); k--) {
      longest = math.max(longest, (children[k] as ListItem).marker?.length ?? 0);
    }
    for (var k = index + 1; k < children.length && mate(children[k]); k++) {
      longest = math.max(longest, (children[k] as ListItem).marker?.length ?? 0);
    }
    return longest;
  }
}

/// How far above the baseline a bullet's centre sits: the middle of an `x`
/// line box in [style] — the same place gpt_markdown's own bullets used, so
/// lists keep their exact look.
double _dotRise(TextStyle style, TextScaler scaler) {
  final key = (style, scaler);
  final cached = _dotRises[key];
  if (cached != null) return cached;
  final painter = TextPainter(
    text: TextSpan(text: 'x', style: style),
    textScaler: scaler,
    textDirection: TextDirection.ltr,
  )..layout();
  final rise = painter.computeDistanceToActualBaseline(TextBaseline.alphabetic) - painter.height / 2;
  painter.dispose();
  if (_dotRises.length >= 64) _dotRises.clear();
  return _dotRises[key] = rise;
}

final _dotRises = <(TextStyle, TextScaler), double>{};

/// The first list item under [node] (the placeholder a list item sits in),
/// not looking into nested paragraphs.
_RenderListItem? _firstListItemIn(RenderObject node) {
  _RenderListItem? found;
  void visit(RenderObject child, int depth) {
    if (found != null || depth > 10) return;
    if (child is _RenderListItem) {
      found = child;
      return;
    }
    if (child is RenderParagraph) return;
    child.visitChildren((c) => visit(c, depth + 1));
  }

  visit(node, 0);
  return found;
}

/// A task-list box (`- [ ]` / `- [x]`) and the gap before its text. A bullet
/// item that opens with one draws no bullet: the box takes the bullet's
/// place and the text still starts on the list's text column, as task lists
/// are usually shown (a dot before a box reads twice).
class TaskBox extends SingleChildRenderObjectWidget {
  const TaskBox({super.key, required super.child});

  /// The box's side and its gap to the text.
  static const size = 18.0;
  static const gap = 4.0;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTaskBox();
}

/// Inside a bullet item the box hangs into the item's gutter (where the
/// bullet would be) and the text starts on the text column; elsewhere (a
/// numbered item, a bare `[ ] …` line) it is laid out as it is.
class _RenderTaskBox extends RenderProxyBox {
  static const _lead = TaskBox.size + TaskBox.gap;

  /// The bullet item this box leads (and hides the bullet of).
  _RenderListItem? _item;

  _RenderListItem? _bulletItem() {
    var node = parent;
    for (var depth = 0; node != null && depth < 16; depth++) {
      if (node is _RenderListItem) return node._marker == null ? node : null;
      node = node.parent;
    }
    return null;
  }

  void _leadItem(_RenderListItem? item) {
    if (identical(item, _item)) return;
    if (identical(_item?._taskBox, this)) _item!.taskBox = null;
    _item = item;
    item?.taskBox = this;
  }

  /// Where the child is painted: left of the box by the lead, in LTR.
  Offset get _shift =>
      _item != null && _item!._textDirection == TextDirection.ltr ? const Offset(-_lead, 0) : Offset.zero;

  BoxConstraints _childConstraints(BoxConstraints constraints) =>
      constraints.copyWith(maxWidth: constraints.maxWidth + _lead, minWidth: constraints.minWidth + _lead);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    if (_bulletItem() == null) return child.getDryLayout(constraints);
    final size = child.getDryLayout(_childConstraints(constraints));
    return constraints.constrain(Size(math.max(0, size.width - _lead), size.height));
  }

  @override
  void performLayout() {
    final child = this.child;
    final item = _bulletItem();
    _leadItem(item);
    if (child == null || item == null) {
      super.performLayout();
      return;
    }
    child.layout(_childConstraints(constraints), parentUsesSize: true);
    size = constraints.constrain(Size(math.max(0, child.size.width - _lead), child.size.height));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child != null) context.paintChild(child, offset + _shift);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _shift,
      position: position,
      hitTest: (result, transformed) => child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) => transform.translateByDouble(_shift.dx, 0, 0, 1);

  @override
  void detach() {
    _leadItem(null);
    super.detach();
  }
}

class _ListItemBox extends SingleChildRenderObjectWidget {
  const _ListItemBox({
    required this.bullet,
    required this.fontSize,
    required this.listMarkerLength,
    required this.dotRise,
    required this.marker,
    required this.textScaler,
    required this.dotColor,
    required this.textDirection,
    required super.child,
  });

  final ThemeBulletStyle bullet;
  final double fontSize;
  final int listMarkerLength;
  final double dotRise;
  final TextSpan? marker;
  final TextScaler textScaler;
  final Color dotColor;
  final TextDirection textDirection;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderListItem(
    bullet: bullet,
    fontSize: fontSize,
    listMarkerLength: listMarkerLength,
    dotRise: dotRise,
    marker: marker,
    textScaler: textScaler,
    dotColor: dotColor,
    textDirection: textDirection,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderListItem renderObject) {
    renderObject
      ..bullet = bullet
      ..fontSize = fontSize
      ..listMarkerLength = listMarkerLength
      ..dotRise = dotRise
      ..marker = marker
      ..textScaler = textScaler
      ..dotColor = dotColor
      ..textDirection = textDirection;
  }
}

class _RenderListItem extends RenderShiftedBox implements ListItemGeometry {
  _RenderListItem({
    required this._bullet,
    required this._fontSize,
    required this._listMarkerLength,
    required this._dotRise,
    required this._marker,
    required this._textScaler,
    required this._dotColor,
    required this._textDirection,
  }) : super(null);

  ThemeBulletStyle _bullet;
  set bullet(ThemeBulletStyle value) {
    if (value == _bullet) return;
    _bullet = value;
    markNeedsPaint();
  }

  double _fontSize;
  set fontSize(double value) {
    if (value == _fontSize) return;
    _fontSize = value;
    markNeedsLayout();
  }

  /// See `_listMarkerLength`: a change means the list's column may have
  /// changed.
  int _listMarkerLength;
  set listMarkerLength(int value) {
    if (value == _listMarkerLength) return;
    _listMarkerLength = value;
    markNeedsLayout();
  }

  /// The number's width in ems (0 for a bullet).
  double get _markerEm {
    final width = _markerPainter?.width;
    return width == null || _fontSize <= 0 ? 0 : width / _fontSize;
  }

  /// The column this item last laid out on, in ems.
  double? _laidOutEm;

  /// The items of this item's list, this one included, of the same kind
  /// (numbered or bulleted). A top-level list is a column of its items (the
  /// incremental view lifts them out of their paragraph): its neighbours in
  /// that column. Anywhere else (a nested list, a list in a quote) the items
  /// sit in a paragraph: its neighbours there, joined to it by nothing but
  /// line breaks. A nested list lives in its parent item's own paragraph, so
  /// it is a list of its own.
  List<_RenderListItem> _listItems() {
    final column = parent;
    if (column is RenderFlex && column.direction == Axis.vertical) return _neighboursIn(column);
    RenderObject placeholder = this;
    var node = parent;
    for (var depth = 0; node is! RenderParagraph; depth++) {
      if (node == null || node is _RenderListItem || depth > 12) return [this];
      placeholder = node;
      node = node.parent;
    }
    final paragraph = node;
    final children = <RenderBox>[];
    for (var child = paragraph.firstChild; child != null; child = paragraph.childAfter(child)) {
      children.add(child);
    }
    final index = children.indexOf(placeholder as RenderBox);
    if (index == -1) return [this];
    // While this item is being attached its own parent may not list it yet
    // (a container adopts a child before linking it): nothing found is fine.
    final first = _firstListItemIn(children[index]);
    if (first != null && !identical(first, this)) return [this];
    final plain = paragraph.text.toPlainText();
    final slots = <int>[];
    for (var i = 0; i < plain.length; i++) {
      if (plain.codeUnitAt(i) == 0xFFFC) slots.add(i);
    }
    // Mid-update (text set, children not yet): no grouping this time.
    if (slots.length != children.length) return [this];
    final numbered = _marker != null;
    _RenderListItem? itemAt(int k) {
      final item = k == index ? this : _firstListItemIn(children[k]);
      return item != null && (item._marker != null) == numbered ? item : null;
    }

    bool joined(int k) => plain.substring(slots[k] + 1, slots[k + 1]) == '\n';
    var start = index;
    while (start > 0 && joined(start - 1) && itemAt(start - 1) != null) {
      start -= 1;
    }
    var end = index;
    while (end + 1 < children.length && joined(end) && itemAt(end + 1) != null) {
      end += 1;
    }
    return [for (var k = start; k <= end; k++) itemAt(k)!];
  }

  /// This item's run of same-kind items among [column]'s children.
  List<_RenderListItem> _neighboursIn(RenderFlex column) {
    final children = <RenderBox>[];
    for (var child = column.firstChild; child != null; child = column.childAfter(child)) {
      children.add(child);
    }
    final index = children.indexOf(this);
    if (index == -1) return [this];
    final numbered = _marker != null;
    bool mate(RenderBox child) => child is _RenderListItem && (child._marker != null) == numbered;
    var first = index;
    while (first > 0 && mate(children[first - 1])) {
      first -= 1;
    }
    var last = index;
    while (last + 1 < children.length && mate(children[last + 1])) {
      last += 1;
    }
    return [for (var k = first; k <= last; k++) children[k] as _RenderListItem];
  }

  /// The list's column, in ems: [listGutterEm], or the widest number plus
  /// the gap.
  static double _columnEm(List<_RenderListItem> items) {
    var widest = 0.0;
    for (final item in items) {
      widest = math.max(widest, item._markerEm);
    }
    return math.max(listGutterEm, widest + _markerGapEm);
  }

  /// A new or renumbered item can widen its list (it reached `10.`): the
  /// items already on the old column lay out again. Run while the tree is
  /// being built, never during layout.
  void _realignList() {
    final items = _listItems();
    final column = _columnEm(items);
    for (final item in items) {
      if (!identical(item, this) && item.attached && item._laidOutEm != null && item._laidOutEm != column) {
        item.markNeedsLayout();
      }
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    if (_marker != null) _realignList();
  }

  double _dotRise;
  set dotRise(double value) {
    if (value == _dotRise) return;
    _dotRise = value;
    markNeedsPaint();
  }

  TextSpan? _marker;
  set marker(TextSpan? value) {
    if (value == _marker) return;
    _marker = value;
    _painter?.dispose();
    _painter = null;
    if (attached && value != null) _realignList();
    markNeedsLayout();
  }

  TextScaler _textScaler;
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _painter?.dispose();
    _painter = null;
    markNeedsLayout();
  }

  Color _dotColor;
  set dotColor(Color value) {
    if (value == _dotColor) return;
    _dotColor = value;
    markNeedsPaint();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  TextPainter? _painter;

  TextPainter? get _markerPainter {
    final span = _marker;
    if (span == null) return null;
    return _painter ??= TextPainter(text: span, textDirection: _textDirection, textScaler: _textScaler)..layout();
  }

  /// Where the text starts; set by [performLayout] from the whole list.
  double _indentPx = 0;

  double get _indent => _indentPx;

  /// The list's column for this item's size, read fresh (intrinsics and dry
  /// layout run before or outside a layout pass).
  double get _columnPx => _fontSize * _listColumnEm;

  double get _listColumnEm => _marker == null ? listGutterEm : _columnEm(_listItems());

  @override
  Rect? get markerRect {
    final marker = _markerPainter;
    if (marker == null) return null;
    final ascent = marker.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    return Offset(_markerLeft(marker), _baseline - ascent) & marker.size;
  }

  @override
  double get textStart => _indent;

  /// The number's left edge: right-aligned against the text, never left of
  /// the item.
  double _markerLeft(TextPainter marker) {
    final edge = _indent - _fontSize * _markerGapEm;
    return _textDirection == TextDirection.ltr
        ? math.max(0, edge - marker.width)
        : math.min(size.width - marker.width, size.width - edge);
  }

  double _baseline = 0;

  /// The [TaskBox] this bullet item opens with: it sits where the bullet
  /// would, so no bullet is drawn.
  _RenderTaskBox? _taskBox;
  set taskBox(_RenderTaskBox? value) {
    if (identical(value, _taskBox)) return;
    _taskBox = value;
    markNeedsPaint();
  }

  @override
  double computeMinIntrinsicWidth(double height) => _columnPx + (child?.getMinIntrinsicWidth(height) ?? 0);

  @override
  double computeMaxIntrinsicWidth(double height) => _columnPx + (child?.getMaxIntrinsicWidth(height) ?? 0);

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(math.max(0, width - _columnPx)) ?? _fontSize;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(math.max(0, width - _columnPx)) ?? _fontSize;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final indent = _columnPx;
    final size = child.getDryLayout(constraints.deflate(EdgeInsets.only(left: indent)));
    return constraints.constrain(Size(indent + size.width, size.height));
  }

  @override
  void performLayout() {
    final columnEm = _listColumnEm;
    _laidOutEm = columnEm;
    _indentPx = _fontSize * columnEm;
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    final indent = _indent;
    child.layout(constraints.deflate(EdgeInsets.only(left: indent)), parentUsesSize: true);
    final childBaseline = child.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true) ?? _fontSize;
    // A number taller above its baseline than the first line (never, in
    // practice) pushes the text down rather than poking out of the box.
    final markerAscent = _markerPainter?.computeDistanceToActualBaseline(TextBaseline.alphabetic) ?? 0;
    final shift = math.max(0.0, markerAscent - childBaseline);
    _baseline = childBaseline + shift;
    final ltr = _textDirection == TextDirection.ltr;
    (child.parentData! as BoxParentData).offset = Offset(ltr ? indent : 0, shift);
    size = constraints.constrain(Size(indent + child.size.width, child.size.height + shift));
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final ltr = _textDirection == TextDirection.ltr;
    final marker = _markerPainter;
    if (marker != null) {
      final ascent = marker.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      marker.paint(context.canvas, offset + Offset(_markerLeft(marker), _baseline - ascent));
      return;
    }
    if (_taskBox != null) return;
    // A bullet near the margin, centred on a lowercase x of the first line.
    // 5 px across, 7 px in from the margin, at the 16 px body size.
    final radius = _fontSize * 0.3125 / 2;
    final inset = _fontSize * 0.4375 + radius;
    final cx = ltr ? inset : size.width - inset;
    final centre = offset + Offset(cx, _baseline - _dotRise);
    final paint = Paint()..color = _dotColor;
    // Drawn, not typed: a glyph could be missing from the pack's font.
    switch (_bullet) {
      case ThemeBulletStyle.dot:
        context.canvas.drawCircle(centre, radius, paint);
      case ThemeBulletStyle.square:
        context.canvas.drawRect(Rect.fromCircle(center: centre, radius: radius), paint);
      case ThemeBulletStyle.diamond:
        final d = radius * 1.3;
        context.canvas.drawPath(
          Path()
            ..moveTo(centre.dx, centre.dy - d)
            ..lineTo(centre.dx + d, centre.dy)
            ..lineTo(centre.dx, centre.dy + d)
            ..lineTo(centre.dx - d, centre.dy)
            ..close(),
          paint,
        );
      case ThemeBulletStyle.dash || ThemeBulletStyle.arrow:
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = _fontSize * 0.09
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        if (_bullet == ThemeBulletStyle.dash) {
          final half = Offset(_fontSize * 0.2, 0);
          context.canvas.drawLine(centre - half, centre + half, paint);
        } else {
          final w = _fontSize * 0.1 * (ltr ? 1 : -1);
          final h = _fontSize * 0.2;
          context.canvas.drawPath(
            Path()
              ..moveTo(centre.dx - w, centre.dy - h)
              ..lineTo(centre.dx + w, centre.dy)
              ..lineTo(centre.dx - w, centre.dy + h),
            paint,
          );
        }
    }
  }

  @override
  void dispose() {
    _painter?.dispose();
    _painter = null;
    super.dispose();
  }
}

/// `<details><summary>…</summary>…</details>`: a disclosure that starts
/// closed (open with the `open` attribute), its body indented to the title.
class MarkdownDisclosure extends StatefulWidget {
  const MarkdownDisclosure({super.key, required this.title, required this.child, this.initiallyOpen = false});

  /// The summary as spans; null shows 「详情」.
  final List<InlineSpan>? title;
  final Widget child;
  final bool initiallyOpen;

  /// The `details` tag for gpt_markdown's HTML table.
  static Widget build(BuildContext context, HtmlElementDetails element) {
    final (:found, :rest) = element.take('summary');
    return MarkdownDisclosure(
      title: found == null ? null : element.buildInline(found.children),
      initiallyOpen: element['open'] != null,
      child: element.buildBlocks(rest),
    );
  }

  @override
  State<MarkdownDisclosure> createState() => _MarkdownDisclosureState();
}

class _MarkdownDisclosureState extends State<MarkdownDisclosure> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final style = DefaultTextStyle.of(context).style;
    final fontSize = style.fontSize ?? 16;
    final duration = AppMotion.of(context, AppMotion.standard);
    final title = widget.title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedRotation(
                  turns: _open ? 0.25 : 0,
                  duration: duration,
                  curve: AppMotion.std,
                  child: Icon(AppIcons.disclosure, size: fontSize * 1.25, color: theme.colorScheme.onSurfaceVariant),
                ),
                SizedBox(width: fontSize * 0.25),
                Flexible(
                  child: Text.rich(
                    TextSpan(children: title ?? [TextSpan(text: l10n.commonDetails)]),
                    style: style.copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ),
        SmoothSize(
          duration: duration,
          curve: AppMotion.std,
          alignment: Alignment.topLeft,
          child: _open
              ? Padding(
                  padding: EdgeInsetsDirectional.only(start: fontSize * 1.5, top: fontSize * 0.25),
                  child: widget.child,
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
