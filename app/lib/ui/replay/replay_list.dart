// The replay's message list. Rows come from the chat's own derivation
// (chat_rows.dart `deriveRows`) and are drawn by the chat's row widgets, so a
// replayed conversation looks like the conversation did; only what can't be
// done here (approve, answer, branch, rate, open a subagent) is left out.
//
// The spacing rules and the row → widget mapping mirror ChatList
// (chat_list.dart `_gapBefore`, `_rowWidget`); keep the two in step.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_notes.dart';
import '../../state/settings_state.dart';
import '../chat/chat_rows.dart';
import '../chat/dsh_ui/dsh_ui.dart';
import '../chat/widgets/assistant_message.dart';
import '../chat/widgets/attachments.dart';
import '../chat/widgets/change_card.dart';
import '../chat/widgets/command_row.dart';
import '../chat/widgets/notice_row.dart';
import '../chat/widgets/stream_motion.dart';
import '../chat/widgets/tool_row.dart';
import '../chat/widgets/turn_footnote.dart';
import '../chat/widgets/turn_process.dart';
import '../chat/widgets/user_bubble.dart';
import '../common/bleed.dart';
import '../theme/theme.dart';
import 'replay_frame.dart';

/// Session id the replay's pictures are read under (see ReplayPage's
/// `sessionImageProvider` override).
const replaySessionId = 'replay';

class ReplayList extends ConsumerStatefulWidget {
  const ReplayList({
    super.key,
    required this.frame,
    required this.topInset,
    required this.bottomInset,
    required this.live,
    this.scrolledUnder,
    this.controller,
  });

  final ReplayFrame frame;

  /// The header's height (status bar included).
  final double topInset;

  /// How far the bottom bar reaches up over the list.
  final double bottomInset;

  /// The frame came from playing (new rows fade in, finished turns fold in
  /// front of the reader), not from seeking.
  final bool live;

  /// How far content has scrolled under the header (0..1).
  final ValueNotifier<double>? scrolledUnder;
  final ScrollController? controller;

  @override
  ConsumerState<ReplayList> createState() => _ReplayListState();
}

class _ReplayListState extends ConsumerState<ReplayList> {
  late final ScrollController _scroll = widget.controller ?? ScrollController();

  /// Following the newest row (the reader hasn't scrolled up).
  bool _pinned = true;
  late final _physics = _FollowPhysics(() => _pinned);

  List<ChatRow> _rows = const [];
  Map<String, int> _rowIndices = const {};
  Set<int> _running = const {};
  final Map<String, int> _fresh = {};
  final Set<String> _settling = {};

  @override
  void dispose() {
    if (widget.controller == null) _scroll.dispose();
    super.dispose();
  }

  void _derive(ReplayFrame frame, {required bool fold}) {
    final rows = deriveRows(
      items: frame.items,
      commands: frame.commands,
      turns: frame.turns,
      running: frame.running,
      foldTurns: fold,
    );
    final running = {
      for (final t in frame.turns)
        if (t.running) t.startSeq,
    };
    if (widget.live) {
      var order = 0;
      for (final row in rows) {
        if (_rowIndices.containsKey(row.key)) continue;
        final animate = switch (row) {
          TurnProcessRow() => false,
          _ => true,
        };
        if (animate) _fresh[row.key] = order++;
        // A turn that finished in front of the reader: shown open, then
        // folded (as the chat does).
        if (row is TurnProcessRow && _running.contains(row.trace.startSeq)) _settling.add(row.key);
      }
    } else {
      _fresh.clear();
      _settling.clear();
    }
    _rows = rows;
    // The first row wins, as in the delegate's original indexWhere lookup.
    _rowIndices = {for (var i = rows.length - 1; i >= 0; i--) rows[i].key: i};
    _running = running;
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    final m = n.metrics;
    final under = widget.scrolledUnder;
    if (under != null) under.value = ((m.pixels - m.minScrollExtent) / 24).clamp(0.0, 1.0);
    if (n is ScrollUpdateNotification && n.dragDetails != null) {
      _pinned = m.maxScrollExtent - m.pixels < 48;
    } else if (n is ScrollEndNotification) {
      _pinned = m.maxScrollExtent - m.pixels < 48;
    }
    return false;
  }

  /// Back to the newest row (after a seek, or 「全文」).
  void _followAfterFrame() {
    if (!_pinned) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_pinned) return;
      final p = _scroll.position;
      if (p.maxScrollExtent - p.pixels > 0.5) _scroll.jumpTo(p.maxScrollExtent);
    });
  }

  @override
  void didUpdateWidget(ReplayList old) {
    super.didUpdateWidget(old);
    // A jump back to the start reads from the top again.
    if (!widget.live && widget.frame.visible < old.frame.visible) _pinned = true;
  }

  @override
  Widget build(BuildContext context) {
    _derive(widget.frame, fold: ref.watch(settingsProvider.select((s) => s.foldCompletedTurns)));
    _followAfterFrame();
    final rows = _rows;
    final indices = _rowIndices;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: CustomScrollView(
        controller: _scroll,
        physics: _physics,
        slivers: [
          SliverToBoxAdapter(child: SizedBox(height: widget.topInset + AppSpace.sm)),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _buildRow(rows, i),
              childCount: rows.length,
              findChildIndexCallback: (key) => key is ValueKey<String> ? indices[key.value] : null,
            ),
          ),
          SliverToBoxAdapter(child: SizedBox(height: widget.bottomInset + AppSpace.sm)),
        ],
      ),
    );
  }

  Widget _buildRow(List<ChatRow> rows, int index) {
    final row = rows[index];
    final previous = index > 0 ? rows[index - 1] : null;
    final fresh = _fresh.remove(row.key);
    return KeyedSubtree(
      key: ValueKey<String>(row.key),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSpace.readingWidth),
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(AppSpace.gutter, replayGapBefore(row, previous), AppSpace.gutter, 0),
            child: StreamFadeIn(enabled: fresh != null, index: fresh ?? 0, child: _rowWidget(row)),
          ),
        ),
      ),
    );
  }

  static Future<void> _noRespond(ApprovalRequest request, ApprovalDecision decision) async {}

  Widget _rowWidget(ChatRow row) {
    return switch (row) {
      UserRow(:final item) when dshUiReplyChip(item.text) != null => DshUiReplyChip(label: dshUiReplyChip(item.text)!),
      UserRow(:final item) => UserBubble(
        text: withoutAppNotes(item.text),
        attachments: item.images.isEmpty && item.files.isEmpty
            ? null
            : SentAttachments.echoed(sessionId: replaySessionId, images: item.images, files: item.files),
      ),
      PendingRow() => const SizedBox.shrink(),
      AssistantRow(:final item, :final showActions, :final footnote) => DshUiScope(
        sessionId: replaySessionId,
        messageId: item.id,
        state: DshUiState.expired,
        child: AssistantMessage(
          item: item,
          showActions: showActions,
          footnote: footnote == null ? null : TurnFootnote(trace: footnote),
        ),
      ),
      TurnFootnoteRow(:final trace) => Bleed(
        horizontal: 8,
        child: Align(
          alignment: Alignment.centerLeft,
          child: TurnFootnote(trace: trace),
        ),
      ),
      ToolCallRow(:final item, :final card) => ToolRow(item: item, card: card, onRespond: _noRespond),
      ToolGroupRow(:final tools, :final live) => ToolGroup(tools: tools, live: live, onRespond: _noRespond),
      final TurnProcessRow row => TurnProcess(
        row: row,
        settle: _settling.remove(row.key),
        buildRow: _rowWidget,
        gapBefore: replayGapBefore,
      ),
      NoticeRowData(:final item) => NoticeRow(item: item),
      ChangeCardRow(:final files) => ChangeCard(files: files),
      CommandNoticeRow(:final notice) => CommandRow(notice: notice),
      ArtifactCardRow() || ApprovalRow() || QuestionRow() => const SizedBox.shrink(),
    };
  }
}

/// ChatList's spacing: 24 between turns, 8 within one, 0 between process
/// lines, 12 before cards, 4 before a footnote.
double replayGapBefore(ChatRow row, ChatRow? previous) {
  bool isUser(ChatRow? r) => r is UserRow || r is PendingRow;
  bool isProcess(ChatRow? r) => switch (r) {
    ToolCallRow() || ToolGroupRow() || CommandNoticeRow() => true,
    AssistantRow(:final item) => item.text.trim().isEmpty && item.reasoning.trim().isNotEmpty,
    NoticeRowData(:final item) => item.kind != 'error',
    _ => false,
  };
  if (previous == null) return 0;
  if (isUser(row)) return isUser(previous) ? AppSpace.sm : AppSpace.xxl;
  if (isProcess(row) && isProcess(previous)) return 0;
  if (row is ApprovalRow || row is QuestionRow || row is ChangeCardRow || row is ArtifactCardRow) {
    return AppSpace.md;
  }
  if (row is TurnFootnoteRow) return AppSpace.xs;
  return AppSpace.sm;
}

/// Keeps the newest row in view while it grows, in the same layout pass (no
/// frame where it hides under the bottom bar).
class _FollowPhysics extends ScrollPhysics {
  const _FollowPhysics(this.follows, {super.parent});

  final bool Function() follows;

  @override
  _FollowPhysics applyTo(ScrollPhysics? ancestor) => _FollowPhysics(follows, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final adjusted = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    if (isScrolling || velocity != 0 || !follows()) return adjusted;
    return newPosition.maxScrollExtent;
  }
}
