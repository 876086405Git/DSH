// Picking which messages of a conversation go on one share card — one by one,
// or a whole stretch at once for a chat-style long image.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/app_notes.dart';
import '../chat/dsh_ui/dsh_ui.dart';
import '../chat/secret_mask.dart';
import '../common/app_sheet.dart';
import '../common/scroll_edge_fade.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// 「选择消息」: every prompt and reply with a round check; returns the picked
/// `ChatItem.key`s (null when dismissed).
///
/// A tap picks or drops one message. A long press picks the whole stretch
/// from the nearest picked message to the one pressed; keep the finger down
/// and slide to stretch it further. Picked neighbours are joined by a rail
/// through their checks, so a continuous stretch reads as one.
Future<Set<String>?> showMessagePicker(
  BuildContext context, {
  required List<ChatItem> items,
  required Set<String> selected,
}) => showAppSheet<Set<String>>(
  context,
  dismissal: SheetDismissal.drag,
  heightFactor: 0.8,
  builder: (_) => MessagePicker(items: items, selected: selected),
);

class MessagePicker extends StatefulWidget {
  const MessagePicker({super.key, required this.items, required this.selected, this.onDone});

  final List<ChatItem> items;
  final Set<String> selected;

  /// 「完成」 with the picks; null pops the route with them (a sheet of its
  /// own). The share panel pushes the picker as a page and takes them here.
  final ValueChanged<Set<String>>? onDone;

  @override
  State<MessagePicker> createState() => _MessagePickerState();
}

class _MessagePickerState extends State<MessagePicker> {
  late Set<String> _picked = {...widget.selected};
  final _scroll = ScrollController();
  final _rows = <String, GlobalKey>{};
  final _listKey = GlobalKey();
  final _sliverKey = GlobalKey();

  /// Each message's [MessagePickRow.preview] while the picker is open, so
  /// picking or dragging over rows doesn't mask and strip every visible
  /// message again. A prompt's pictures and the language go into the line.
  final _lines = Expando<(int, Locale, String)>();

  String _lineOf(ChatItem item) {
    final images = item is UserChatItem ? item.images.length : 0;
    final locale = AppLocale.current;
    if (_lines[item] case (final n, final l, final line) when n == images && l == locale) return line;
    final line = MessagePickRow.preview(item);
    _lines[item] = (images, locale, line);
    return line;
  }

  /// A stretch being drawn by a long press: what was picked before it, the
  /// message it is anchored at, and the last one the finger was over.
  Set<String>? _base;
  int? _anchor;
  int? _last;

  /// Where the finger is during a stretch (global), for scrolling at an edge.
  Offset? _pointer;
  Timer? _edgeScroll;

  /// How close to the list's top or bottom edge a stretch scrolls it.
  static const _edge = 56.0;

  @override
  void initState() {
    super.initState();
    // Open at the picked messages rather than at the top of a long chat.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final first = widget.items.indexWhere((i) => _picked.contains(i.key));
      if (first <= 0 || !_scroll.hasClients) return;
      final target = (first * MessagePickRow.minHeight - 48).clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.jumpTo(target);
    });
  }

  @override
  void dispose() {
    _edgeScroll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _toggle(String key) {
    HapticFeedback.selectionClick();
    setState(() => _picked.contains(key) ? _picked.remove(key) : _picked.add(key));
  }

  /// The row under [global], if one is built there.
  int? _rowAt(Offset global) {
    final sliver = _sliverKey.currentContext?.findRenderObject();
    if (sliver is! RenderSliverMultiBoxAdaptor) return null;
    int? first;
    // Includes kept-alive rows, which visitChildren visits after the laid-out ones.
    sliver.visitChildren((child) {
      final i = sliver.indexOf(child as RenderBox);
      if (first != null && i >= first!) return;
      if (i >= widget.items.length) return;
      final box = _rows[widget.items[i].key]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return;
      final local = box.globalToLocal(global);
      if (local.dy >= 0 && local.dy < box.size.height) first = i;
    });
    return first;
  }

  void _startStretch(LongPressStartDetails details) {
    final index = _rowAt(details.globalPosition);
    if (index == null) return;
    final picked = [
      for (final (i, item) in widget.items.indexed)
        if (_picked.contains(item.key) && i != index) i,
    ];
    // The nearest picked message anchors the stretch; with none, it starts here.
    var anchor = index;
    for (final i in picked) {
      if (anchor == index || (i - index).abs() < (anchor - index).abs()) anchor = i;
    }
    HapticFeedback.mediumImpact();
    _base = {..._picked};
    _anchor = anchor;
    _pointer = details.globalPosition;
    _stretchTo(index);
  }

  void _moveStretch(LongPressMoveUpdateDetails details) {
    if (_base == null) return;
    _pointer = details.globalPosition;
    final index = _rowAt(details.globalPosition);
    if (index != null && index != _last) {
      HapticFeedback.selectionClick();
      _stretchTo(index);
    }
    _scrollAtEdge();
  }

  void _endStretch() {
    _base = null;
    _anchor = null;
    _last = null;
    _pointer = null;
    _edgeScroll?.cancel();
    _edgeScroll = null;
  }

  void _stretchTo(int index) {
    final anchor = _anchor!;
    final (from, to) = anchor <= index ? (anchor, index) : (index, anchor);
    setState(() {
      _last = index;
      _picked = {..._base!, for (var i = from; i <= to; i++) widget.items[i].key};
    });
  }

  /// While the finger rests near the top or bottom of the list, the list
  /// scrolls and the stretch follows.
  void _scrollAtEdge() {
    final list = _listKey.currentContext?.findRenderObject();
    final pointer = _pointer;
    if (list is! RenderBox || pointer == null || !_scroll.hasClients) return;
    final y = list.globalToLocal(pointer).dy;
    final step = y < _edge ? -10.0 : (y > list.size.height - _edge ? 10.0 : 0.0);
    if (step == 0) {
      _edgeScroll?.cancel();
      _edgeScroll = null;
      return;
    }
    _edgeScroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final position = _scroll.position;
      final pointer = _pointer;
      final list = _listKey.currentContext?.findRenderObject();
      if (pointer == null || list is! RenderBox || _base == null) return _endStretchScroll();
      final y = list.globalToLocal(pointer).dy;
      final step = y < _edge ? -10.0 : (y > list.size.height - _edge ? 10.0 : 0.0);
      final next = (position.pixels + step).clamp(position.minScrollExtent, position.maxScrollExtent);
      if (step == 0 || next == position.pixels) return _endStretchScroll();
      _scroll.jumpTo(next);
      final index = _rowAt(pointer);
      if (index != null && index != _last) _stretchTo(index);
    });
  }

  void _endStretchScroll() {
    _edgeScroll?.cancel();
    _edgeScroll = null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final count = _picked.length;
    final items = widget.items;
    bool picked(int i) => i >= 0 && i < items.length && _picked.contains(items[i].key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(l10n.viewSharePickMessages),
        Expanded(
          child: GestureDetector(
            onLongPressStart: _startStretch,
            onLongPressMoveUpdate: _moveStretch,
            onLongPressEnd: (_) => _endStretch(),
            onLongPressCancel: _endStretch,
            child: ScrollEdgeFade(
              child: CustomScrollView(
                key: _listKey,
                controller: _scroll,
                semanticChildCount: items.length,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(kSheetGutter - 8, 0, kSheetGutter - 8, 8),
                    sliver: SliverList.builder(
                      key: _sliverKey,
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final item = items[i];
                        return MessagePickRow(
                          key: _rows.putIfAbsent(item.key, GlobalKey.new),
                          item: item,
                          line: _lineOf(item),
                          picked: picked(i),
                          joinAbove: picked(i) && picked(i - 1),
                          joinBelow: picked(i) && picked(i + 1),
                          onTap: () => _toggle(item.key),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 8, kSheetGutter, 12),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: count == 0
                  ? null
                  : () {
                      final onDone = widget.onDone;
                      onDone == null ? Navigator.pop(context, {..._picked}) : onDone({..._picked});
                    },
              child: Text(count == 0 ? l10n.commonDone : l10n.viewShareDoneCount(count)),
            ),
          ),
        ),
      ],
    );
  }
}

/// One message: a round check (ink when picked, like the filter capsules),
/// who said it, two lines of it. Picked neighbours share a rail through
/// their checks ([joinAbove], [joinBelow]).
class MessagePickRow extends StatelessWidget {
  const MessagePickRow({
    super.key,
    required this.item,
    required this.line,
    required this.picked,
    required this.onTap,
    this.joinAbove = false,
    this.joinBelow = false,
  });

  final ChatItem item;

  /// Two lines of it: [preview] of [item].
  final String line;
  final bool picked;
  final VoidCallback onTap;
  final bool joinAbove;
  final bool joinBelow;

  static const minHeight = 68.0;

  /// The rail's width.
  static const rail = 2.0;

  static String preview(ChatItem item) {
    final raw = switch (item) {
      UserChatItem(:final text) => maskSecrets(withoutAppNotes(text), mark: '•'),
      AssistantChatItem(:final text) => maskSecrets(dshUiPlainText(text), mark: '•'),
      _ => '',
    };
    final text = raw
        .replaceAll(RegExp(r'^\s*(`{3,}|~{3,}).*$', multiLine: true), '')
        .replaceAll(RegExp(r'!\[[^\]\n]*\]\([^)\n]*\)'), appL10n.viewShareImageMarker)
        .replaceAll(RegExp(r'\*\*|__|`+'), '')
        .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true), '')
        .replaceAll(RegExp(r'\s*\n\s*'), ' ')
        .trim();
    // A prompt's pictures lead its line: 「〔2 张图片〕 帮我调一下」.
    if (item is UserChatItem && item.images.isNotEmpty) {
      final n = item.images.length;
      return [
        n == 1 ? appL10n.viewShareImageMarker : appL10n.viewShareImagesMarker(n),
        if (text.isNotEmpty) text,
      ].join(' ');
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final user = item is UserChatItem;
    return Semantics(
      checked: picked,
      button: true,
      child: InkWell(
        onTap: onTap,
        customBorder: Squircle.border(AppShape.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: minHeight),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _CheckRail(picked: picked, joinAbove: joinAbove, joinBelow: joinBelow),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 10, 8, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          user ? l10n.viewShareYou : l10n.commonReply,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: user ? scheme.onSurfaceVariant : colors.textTertiary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          line,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The check, centred in the row's height, and the rail that joins it to a
/// picked neighbour above or below.
class _CheckRail extends StatelessWidget {
  const _CheckRail({required this.picked, required this.joinAbove, required this.joinBelow});

  final bool picked;
  final bool joinAbove;
  final bool joinBelow;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    Widget rail(bool on, Key key) => Expanded(
      child: Center(
        child: AnimatedContainer(
          key: key,
          duration: AppMotion.of(context, AppMotion.quick),
          curve: AppMotion.std,
          width: MessagePickRow.rail,
          color: on ? ink : ink.withValues(alpha: 0),
        ),
      ),
    );
    return SizedBox(
      width: _CheckDot.size,
      child: Column(
        children: [
          rail(joinAbove, const ValueKey('pick-rail-above')),
          _CheckDot(picked: picked),
          rail(joinBelow, const ValueKey('pick-rail-below')),
        ],
      ),
    );
  }
}

class _CheckDot extends StatelessWidget {
  const _CheckDot({required this.picked});

  final bool picked;

  static const size = 22.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      key: const ValueKey('pick-dot'),
      duration: AppMotion.of(context, AppMotion.quick),
      curve: AppMotion.std,
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: picked ? scheme.onSurface : Colors.transparent,
        shape: CircleBorder(
          side: picked ? BorderSide.none : BorderSide(color: scheme.outline.withValues(alpha: 0.6), width: 1.5),
        ),
      ),
      child: picked ? Icon(AppIcons.selected, size: 16, color: scheme.surface) : null,
    );
  }
}
