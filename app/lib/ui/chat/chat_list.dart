// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
// Local changes: rewritten around a centre-anchored CustomScrollView (see
// [ChatList]); the jump-to-bottom control is a chrome-glass circle.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../pets/pet_signals.dart' show petHeadroomProvider;
import '../../plugins/native/native_surface.dart' show nativeTurnNoteProvider;
import '../../state/agents_state.dart' show hostSessionsProvider, selectConversation;
import '../../state/app_notes.dart';
import '../../state/artifacts.dart';
import '../../state/attachments.dart' show DraftAttachment;
import '../../state/chat_reveal.dart';
import '../../state/chat_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart' show HostKind, activeHostProvider;
import '../../state/regenerate.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../common/app_dialog.dart';
import '../common/bleed.dart';
import '../common/ui_trace.dart';
import '../pets/pet_perch.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../update/update_sheet.dart' show checkForUpdates;
import 'chat_rows.dart';
import 'chat_rows_cache.dart';
import 'media/media_paths.dart';
import 'composer_toast.dart';
import 'dsh_ui/dsh_ui.dart';
import 'render/markdown_image.dart';
import 'trajectory_sheet.dart';
import 'turn_summary.dart' show forgetToolSummaries;
import 'widgets/approval_card.dart';
import 'widgets/artifact_card.dart';
import 'widgets/assistant_message.dart';
import 'widgets/attachments.dart';
import 'widgets/background_task_notice.dart';
import 'widgets/change_card.dart';
import 'widgets/command_row.dart';
import 'widgets/notice_row.dart';
import 'widgets/question_card.dart';
import 'widgets/stream_motion.dart';
import 'widgets/tool_row.dart';
import 'widgets/turn_failure_text.dart' show modelRefusalCodes;
import 'widgets/turn_footnote.dart';
import 'widgets/turn_process.dart';
import 'widgets/user_bubble.dart';

/// Sends [text] with [images] in conversation [sessionId] (a fork just made).
typedef ResendPrompt = Future<void> Function(String sessionId, String text, List<DraftAttachment> images);

/// 消息列表:最新在底部,流式时跟随,用户上翻后不打扰。
///
/// ## 为什么是"居中锚定"的 CustomScrollView
///
/// 视口被切成两段 sliver,中心([center])在两段之间:
///
/// ```
///   顶部留白 / 加载更早
///   ┌ before:打开会话时已有的行,倒序向上长 ┐   ← 加载更早的历史接在这一段的
///   └──────────────── center ───────────────┘      最上方,不改变任何现有偏移
///   ┌ after:之后新来的行,向下长           ┐   ← 流式增长只发生在这一段,
///   └ 底部留白(= 输入条高度)             ┘      上翻阅读时视口纹丝不动
/// ```
///
/// - 头部插入历史、尾部流式增长都不移动用户正在看的内容(普通列表两者必有
///   其一要做偏移补偿,而惰性列表的 `maxScrollExtent` 只是估算值)。
/// - [CustomScrollView.anchor] 设为"输入条上沿"在视口里的比例:零偏移
///   正好让 before 段的最后一行贴着输入条,打开会话不需要先跳一次。
/// - 跟随 = 贴底时内容一变,**同一次布局**里就把位置挪到新的末尾
///   ([_FollowPhysics]):新内容不会先藏在输入条后面一帧再跳上来,内容
///   变矮时也不会先露一道缝再弹回去。离底较远时(刚发了消息)由帧后的
///   `jumpTo(maxScrollExtent)` 追过去,追到底之后同样由它接手。
/// - 列表的下沿由页面跟着输入条在同一帧里排好(见 ChatScreen),所以
///   [bottomInset] 只是"伸到输入条下面多少",是个常量。
class ChatList extends ConsumerStatefulWidget {
  const ChatList({
    super.key,
    required this.sessionId,
    required this.topInset,
    this.scrolledUnder,
    required this.bottomInset,
    this.onWithdraw,
    this.onSendNow,
    this.onEditPrompt,
    this.onResend,
    this.onQuote,
    this.onToast,
    this.onSwitchModel,
    this.toTop,
  });

  final String sessionId;

  /// Where the status bar's tap arrives (iOS).
  final StatusBarTop? toTop;

  /// 顶栏占的高度(含状态栏)。
  final double topInset;

  /// How far the viewport extends below the composer's top edge. Overflowing
  /// content stops `bottomInset + 8` above the viewport bottom; short content
  /// stays aligned to the top instead.
  final double bottomInset;

  /// Set to how far content has scrolled under the top bar (0..1); the header
  /// fades in its backdrop by it.
  final ValueNotifier<double>? scrolledUnder;

  /// "撤回" on a queued message; the screen puts it back into the composer.
  final ValueChanged<PendingPrompt>? onWithdraw;

  /// 「立即发送」 on a waiting message (「发送」 once no turn runs); null
  /// leaves it out.
  final ValueChanged<PendingPrompt>? onSendNow;

  /// "编辑后重发" on a sent message: called with its text once the fork that
  /// ends just before it is open; the screen puts the text into the composer.
  /// Null leaves the action out.
  final ValueChanged<String>? onEditPrompt;

  /// 「重新回答」: called once the fork that ends just before the last prompt
  /// is open and selected, with that prompt's text and images; the screen
  /// sends them there (and puts them back into the composer if that fails).
  /// Null leaves the action out.
  final ResendPrompt? onResend;

  /// 「引用」 on a reply (all of it, or a passage picked in 「选择文字」); the
  /// screen puts it above the composer. Null leaves the action out.
  final ValueChanged<String>? onQuote;

  /// A toast clear of the composer (「已在新对话中打开」 with 返回原对话);
  /// null: the plain SnackBar.
  final ComposerToast? onToast;

  /// 「换模型」 on a turn the engine refused for its model; the screen opens
  /// the model sheet for this conversation. Null leaves the action out.
  final VoidCallback? onSwitchModel;

  @override
  ConsumerState<ChatList> createState() => _ChatListState();
}

class _ChatListState extends ConsumerState<ChatList> with SingleTickerProviderStateMixin {
  late final _scroll = _TopBoundedScrollController(_leadingBoundary, _prependCorrection);
  final _centerKey = GlobalKey();
  final _beforeKey = GlobalKey();
  final _historyKey = GlobalKey();
  double _anchorPixels = 0;

  // A centered viewport clamps its leading extent to <= 0. With a short
  // reverse segment that leaves empty space above the first row. Its actual
  // leading boundary can be positive. Read geometry during content-dimension
  // negotiation, after both sliver lists have been laid out; no frame callback
  // or change to the stable center coordinate is needed.
  double? _leadingBoundary() {
    final before = _beforeKey.currentContext?.findRenderObject();
    final header = _historyKey.currentContext?.findRenderObject();
    if (before is! RenderSliver || header is! RenderSliver) return null;
    final rows = before.geometry?.scrollExtent;
    final history = header.geometry?.scrollExtent;
    if (rows == null || history == null) return null;
    return _anchorPixels - rows - history - widget.topInset - AppSpace.sm;
  }

  /// EditableText's reveal request includes its caret padding. The centered
  /// viewport's getOffsetToReveal omits the anchor, so use the actual rectangle
  /// in this viewport instead. Other reveal requests keep Flutter's behavior.
  bool _revealInlineEditor(RenderObject target, Rect? rect, Duration duration, Curve curve) {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus == null || !focus.mounted || focus.findAncestorStateOfType<_ChatListState>() != this) return false;
    final editor = focus.findAncestorStateOfType<EditableTextState>();
    if (editor == null || editor.widget.readOnly) return false;
    RenderObject? ancestor = editor.renderEditable;
    while (ancestor != null && ancestor != target) {
      ancestor = ancestor.parent;
    }
    if (ancestor == null || !_scroll.hasClients) return false;
    final viewport = _centerKey.currentContext?.findRenderObject()?.parent;
    if (viewport is! RenderViewport || !viewport.hasSize) return false;
    final position = _scroll.position;
    // Do not interrupt a finger or the fling it started. A previous implicit
    // caret animation has an idle user direction and may be superseded.
    if (_fingers > 0 || position.userScrollDirection != ScrollDirection.idle || !position.allowImplicitScrolling) {
      return true;
    }
    final revealed = MatrixUtils.transformRect(target.getTransformTo(viewport), rect ?? target.paintBounds);
    final leading = revealed.top - widget.topInset;
    final trailing = revealed.bottom - _anchorPixels;
    // When the requested area is taller than the viewport and already spans
    // it, neither edge is preferable (the same rule as showInViewport).
    if (leading < 0 && trailing > 0) return true;
    final shift = trailing > 0 ? trailing : math.min(0.0, leading);
    if (shift.abs() > precisionErrorTolerance) {
      unawaited(position.moveTo(position.pixels + shift, duration: duration, curve: curve));
    }
    return true;
  }

  /// 视口贴在底部(决定流式时是否跟随)。
  bool _pinned = true;

  /// 手指刚点过列表里的东西(展开一组工具、一段思考):这之后行自己长高
  /// 不算"新内容",不去追底,点开的标题留在原处。新数据到来或开始拖动时
  /// 解除。
  bool _held = false;

  late final _physics = _FollowPhysics(() => _pinned && !_held && _fingers == 0, glides: () => _glidable);

  /// Fingers on the list. Any `jumpTo` ends the drag under them for good (it goes idle,
  /// and the rest of that gesture moves nothing), so while one rests here or the list is
  /// moving on its own, following waits: the list is the user's.
  int _fingers = 0;

  bool get _userHasList => _fingers > 0 || (_scroll.hasClients && _scroll.position.isScrollingNotifier.value);

  /// Heading up, by finger or fling: however near the bottom, that is not "at the bottom".
  bool _goingUp = false;

  /// Following waited for the user; it picks up when they let go.
  bool _followWaiting = false;

  /// The next follow overrides the user: they asked for the bottom, or just sent something.
  bool _followNow = false;

  /// The fluid tier: following glides to a new line instead of snapping to it. Real
  /// scrolling, so everything else about the list is as it was; the new line only starts
  /// a little lower, behind the composer.
  bool _fluid = false;

  /// The glide is ours: its scroll updates say nothing about what the user wants.
  bool _gliding = false;
  bool _snapNext = false;
  late final Ticker _glide = createTicker(_onGlide);
  Duration _glideLast = Duration.zero;

  /// Time constant of the glide: a line (about 28) lands in some 150ms, and lines
  /// arriving faster than that blend into one steady motion.
  static const _glideSeconds = 0.07;

  /// Further than this is not a next line: a jump, as before.
  static const _glideReach = 240.0;

  bool get _glidable => _fluid && !_snapNext;

  void _startGlide() {
    _gliding = true;
    if (_glide.isActive) return;
    _glideLast = Duration.zero;
    _glide.start();
  }

  void _goToTop() => unawaited(_runToTop());

  /// The rows above are measured as they come into view, so the top can turn out nearer or further
  /// than it first looked: stop on arriving, and go on if it's further. A finger takes over.
  Future<void> _runToTop() async {
    if (!_scroll.hasClients) return;
    _stopGlide();
    _pinned = false;
    final position = _scroll.position;
    final duration = AppMotion.of(context, const Duration(milliseconds: 600));
    void stopAtTop() {
      if (position.pixels < position.minScrollExtent) position.jumpTo(position.minScrollExtent);
    }

    _scroll.addListener(stopAtTop);
    for (
      var tries = 0;
      tries < 3 && mounted && _fingers == 0 && position.pixels > position.minScrollExtent + 1;
      tries++
    ) {
      if (duration == Duration.zero) {
        position.jumpTo(position.minScrollExtent);
      } else {
        await position.animateTo(position.minScrollExtent, duration: duration, curve: AppMotion.glide);
      }
    }
    if (mounted) _scroll.removeListener(stopAtTop);
  }

  void _stopGlide() {
    _gliding = false;
    if (_glide.isActive) _glide.stop();
  }

  void _onGlide(Duration elapsed) {
    if (!mounted || !_scroll.hasClients || !_pinned || _held) return _stopGlide();
    if (_userHasList) {
      _followWaiting = true;
      return _stopGlide();
    }
    final seconds = (elapsed - _glideLast).inMicroseconds / Duration.microsecondsPerSecond;
    _glideLast = elapsed;
    final p = _scroll.position;
    final gap = p.maxScrollExtent - p.pixels;
    if (gap <= 0.5 || gap > _glideReach) {
      if (gap != 0) p.jumpTo(p.maxScrollExtent);
      return _stopGlide();
    }
    p.jumpTo(p.pixels + gap * (1 - math.exp(-seconds / _glideSeconds)));
  }

  /// 回到底部按钮 / 新内容角标。用 notifier 而不是 setState:
  /// 显隐翻转不该重建整个列表。
  final _showJump = ValueNotifier<bool>(false);
  final _hasNew = ValueNotifier<bool>(false);

  /// before 段最后一行的主键;null = before 段为空。首次加载完成时确定。
  String? _splitKey;
  bool _splitChosen = false;
  int? _oldestRowSeq;
  ({String key, double offset})? _prependAnchor;
  String? _snapPaddingKey;

  // 行派生缓存:输入不变就不重算。
  List<ChatRow> _rows = const [];
  final _rowCache = ChatRowsCache();
  Map<String, int> _index = const {};
  Object? _rowsInputs;
  Set<String> _autoAnswered = const {};

  /// Row widgets as last built, by row key. A row whose [ChatRow] object, gap
  /// and motion are unchanged gets the same widget back, so Flutter skips it:
  /// a text delta rebuilds only the reply it grows. Cleared whenever rows are
  /// derived afresh, and when anything else a row reads changes (see
  /// [_clearBuiltRows]).
  ///
  /// The rule this rests on: whatever the row-building layer ([_rowFrame] and
  /// the methods it calls) reads that does not come with the row object (the
  /// chat state, the list's context, the language, the list's own fields,
  /// other providers) must either clear this map when it changes, or be read
  /// in the row widget's own build instead. Today that is: the chat state
  /// ([_deriveRows]), the motion duration and the language ([build]), the
  /// fork / regenerate marks ([_clearBuiltRows]) and which callbacks are given
  /// ([didUpdateWidget]).
  final Map<String, ({ChatRow row, double gap, Widget widget})> _built = {};
  Duration? _builtMotion;
  Locale? _builtLocale;
  ChatState? _builtState;

  /// A streaming draft has words, not only thinking: earlier rows read that
  /// (whether a visual block was answered by a later reply).
  bool _draftSays = false;

  double? _lastViewport;
  int _lastPendingCount = 0;
  bool _followScheduled = false;

  /// The turn is running (queued bubbles can still be moved into it).
  bool _running = false;

  /// 正在分叉的那条回复(挡连点)。
  String? _forkingId;

  /// 正在准备重新回答的那条回复(读原图、分叉;挡连点)。
  String? _regeneratingId;

  // 一轮在眼前结束时怎么收起过程(开着「收起过程」时):贴底看着的,先按原样
  // 画一帧再平滑收起;往上翻着看的,下一次派生里直接收掉,不保留展开。
  // 冷打开、重新加载时已结束的轮照旧直接收着。
  Set<int> _runningTurns = const {};

  /// 要播收起动画的过程行;第一次建出来就拿掉(同 [_fresh])。
  final Set<String> _settling = {};

  /// 刚出现、还没画过的行 → 它在这一批里的序号(淡入上移的错开)。
  /// 第一次建出来就从这里拿掉:滚出去再滚回来不会重播。
  final Map<String, int> _fresh = {};

  // 方法 tear-off 对同一个 State 恒等:子行的回调不会每帧都"变"。
  Future<void> _respond(ApprovalRequest request, ApprovalDecision decision) =>
      ref.read(chatProvider(widget.sessionId).notifier).respond(request, decision);

  Future<void> _allowAll(ApprovalRequest request) =>
      ref.read(chatProvider(widget.sessionId).notifier).allowAll(request);

  Future<void> _answer(UserQuestionRequest request, List<QuestionAnswer> answers) =>
      ref.read(chatProvider(widget.sessionId).notifier).answer(request, answers);

  Future<void> _rejectQuestion(UserQuestionRequest request) =>
      ref.read(chatProvider(widget.sessionId).notifier).rejectQuestion(request);

  @override
  void initState() {
    super.initState();
    widget.toTop?.onTap = _goToTop;
  }

  @override
  void dispose() {
    if (widget.toTop?.onTap == _goToTop) widget.toTop?.onTap = null;
    // This conversation's calls leave the tool summary caches with it.
    forgetToolSummaries({
      for (final item in _builtState?.items ?? const <ChatItem>[])
        if (item is ToolChatItem) item.callId,
    });
    _glide.dispose();
    _scroll.dispose();
    _showJump.dispose();
    _hasNew.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ChatList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.toTop != widget.toTop) {
      if (oldWidget.toTop?.onTap == _goToTop) oldWidget.toTop?.onTap = null;
      widget.toTop?.onTap = _goToTop;
    }
    if (oldWidget.bottomInset != widget.bottomInset && _pinned) _follow();
    // Rows call the callbacks through `widget` when tapped; only whether
    // each is there shapes what they show.
    bool same(Object? a, Object? b) => (a == null) == (b == null);
    if (oldWidget.sessionId != widget.sessionId ||
        !same(oldWidget.onWithdraw, widget.onWithdraw) ||
        !same(oldWidget.onSendNow, widget.onSendNow) ||
        !same(oldWidget.onEditPrompt, widget.onEditPrompt) ||
        !same(oldWidget.onResend, widget.onResend) ||
        !same(oldWidget.onQuote, widget.onQuote) ||
        !same(oldWidget.onSwitchModel, widget.onSwitchModel)) {
      _built.clear();
    }
  }

  void _clearBuiltRows(VoidCallback change) => setState(() {
    change();
    _built.clear();
  });

  void _quote(String passage) => widget.onQuote?.call(passage);

  void _switchModel() => widget.onSwitchModel?.call();

  // ---------------------------------------------------------------------------
  // 跟随与贴底

  bool _atBottom([double slop = 24]) {
    if (!_scroll.hasClients) return true;
    final p = _scroll.position;
    return p.maxScrollExtent - p.pixels <= slop;
  }

  /// 下一帧贴到底;max 在新内容布局后可能再变,最多追几帧。
  void _follow() {
    if (_followScheduled) return;
    _followScheduled = true;
    var attempts = 0;
    void step(Duration _) {
      if (!mounted || !_scroll.hasClients || !_pinned) {
        _followScheduled = false;
        return;
      }
      final p = _scroll.position;
      if (_followNow) {
        _followNow = false;
        // Ends a fling or a drag in progress.
        p.jumpTo(p.pixels);
      } else if (_userHasList) {
        _followScheduled = false;
        _followWaiting = true;
        return;
      }
      if (uiTraceEnabled && p.pixels != p.maxScrollExtent) {
        uiTrace('chat-list', 'follow', {'from': p.pixels, 'to': p.maxScrollExtent, 'held': _held, 'attempt': attempts});
      }
      final gap = p.maxScrollExtent - p.pixels;
      if (_glidable && gap > 0 && gap <= _glideReach) {
        _followScheduled = false;
        _startGlide();
        return;
      }
      _snapNext = false;
      if (p.pixels != p.maxScrollExtent) p.jumpTo(p.maxScrollExtent);
      attempts++;
      if (attempts < 4 && _scroll.position.pixels < p.maxScrollExtent - 0.5) {
        WidgetsBinding.instance.addPostFrameCallback(step);
      } else {
        _followScheduled = false;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback(step);
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _resumeFollow() {
    if (!_followWaiting || _userHasList) return;
    _followWaiting = false;
    if (!_pinned) return;
    _held = false;
    _follow();
  }

  void _onFingerUp() {
    if (_fingers > 0) _fingers--;
    _resumeFollow();
  }

  void jumpToBottom() {
    _pinned = true;
    _goingUp = false;
    _followNow = true;
    _snapNext = true;
    _stopGlide();
    _hasNew.value = false;
    _showJump.value = false;
    _follow();
  }

  void _reportScrolledUnder(ScrollMetrics m) {
    final target = widget.scrolledUnder;
    if (target == null) return;
    target.value = (m.extentBefore / 24).clamp(0.0, 1.0);
  }

  /// A dimension correction can end a ballistic activity during layout.
  /// Publish notifier/provider changes only after that frame, using the
  /// final geometry rather than a snapshot from an intermediate layout pass.
  void _consumeScrollMetrics(ScrollMetrics metrics, void Function(ScrollMetrics) consume) {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      final session = widget.sessionId;
      final position = _scroll.hasClients ? _scroll.position : null;
      _afterFrame(() {
        if (_scroll.hasClients && widget.sessionId == session && identical(_scroll.position, position)) {
          consume(_scroll.position);
        }
      });
    } else {
      consume(metrics);
    }
  }

  bool _onMetrics(ScrollMetricsNotification n) {
    if (n.depth != 0) return false;
    _consumeScrollMetrics(n.metrics, _applyMetrics);
    return false;
  }

  void _applyMetrics(ScrollMetrics metrics) {
    _reportScrolledUnder(metrics);
    // The reveal grows the reply between state updates.
    if (_glidable && _pinned && !_held && _scroll.hasClients && !_atBottom(0.5) && _atBottom(_glideReach)) {
      if (_userHasList) {
        _followWaiting = true;
      } else {
        _startGlide();
      }
    } else if (_glidable && _pinned && !_held && _scroll.hasClients && !_atBottom(_glideReach)) {
      // Too far to glide, with no new state to set off a follow: the jump it would do.
      if (_userHasList) {
        _followWaiting = true;
      } else {
        _follow();
      }
    }
    // 点开的内容往下长出了视口:不再算贴底,之后的新内容不把它顶走。
    if (_held && _pinned && !_atBottom()) {
      _pinned = false;
      if (!_showJump.value && !_atBottom(160)) _showJump.value = true;
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    // Only this list's drag dismisses the keyboard. A code well's inner
    // horizontal drag must keep its SelectionArea focused.
    if (n is ScrollUpdateNotification && n.dragDetails != null) {
      final scope = FocusScope.of(context);
      if (scope.hasFocus && !scope.hasPrimaryFocus) FocusManager.instance.primaryFocus?.unfocus();
    }
    _consumeScrollMetrics(n.metrics, (metrics) => _applyScroll(n, metrics));
    return false;
  }

  void _applyScroll(ScrollNotification n, ScrollMetrics metrics) {
    _reportScrolledUnder(metrics);
    if (n is UserScrollNotification) _held = false;
    if (n is UserScrollNotification && n.direction == ScrollDirection.forward) {
      // 手指往下拖 = 往回看:立刻停止跟随,别和用户抢。
      _pinned = false;
      _goingUp = true;
    } else if (n is UserScrollNotification && n.direction == ScrollDirection.reverse) {
      _goingUp = false;
    } else if (_gliding) {
      // Our own motion: still following, however far behind it is for now.
    } else if (n is ScrollEndNotification) {
      _goingUp = false;
      // Behind only because following waited: that isn't the user leaving.
      if (!_followWaiting || !_pinned) _pinned = _atBottom();
      // The activity that ended is still being replaced.
      scheduleMicrotask(() {
        if (mounted) _resumeFollow();
      });
    } else if (n is ScrollUpdateNotification && !_goingUp && !_followWaiting) {
      _pinned = _atBottom();
    }
    // Show only after leaving the bottom area; once shown, keep it until
    // the list is pinned again. A single threshold reverses the fade on
    // every tiny scroll/layout oscillation around 160.
    final far = !_atBottom(_showJump.value ? 24 : 160);
    if (_showJump.value != far) _showJump.value = far;
    if (!far) _hasNew.value = false;
    _maybeLoadOlder(metrics);
  }

  void _maybeLoadOlder(ScrollMetrics metrics) {
    if (metrics.pixels - metrics.minScrollExtent > 800) return;
    final state = ref.read(chatProvider(widget.sessionId));
    if (state.hasMoreHistory && !state.loadingOlder && !state.loading) {
      ref.read(chatProvider(widget.sessionId).notifier).loadOlder();
    }
  }

  // ---------------------------------------------------------------------------
  // 行与分界

  void _deriveRows(ChatState s, {required bool foldTurns, List<TurnArtifacts> artifacts = const []}) {
    if (s.loading || !foldTurns) {
      _settling.clear();
    } else {
      for (final turn in s.turns) {
        if (turn.running || !_runningTurns.contains(turn.startSeq) || !(turn.endReason?.isCompleted ?? false)) {
          continue;
        }
        // 贴底看着的一轮:先按原样画一帧,再平滑收成摘要。往上翻着看的
        // 不播动画,直接收 —— 过程一律收起来,不再有"读过就不收"。
        if (_pinned) _settling.add('tp${turn.startSeq}');
      }
    }
    _runningTurns = {
      if (!s.loading)
        for (final turn in s.turns)
          if (turn.running) turn.startSeq,
    };
    final changed = !identical(s, _builtState);
    _builtState = s;
    final inputs = (
      foldTurns,
      artifacts,
      s.items,
      s.approvals,
      s.questions,
      s.pending,
      s.running,
      s.autoAnswered,
      s.commands,
      s.turns,
    );
    if (_rowsInputs == inputs) {
      // Nothing the rows are made of changed, but what they read from the
      // controller (branch points, reply ids) may have.
      if (changed) _built.clear();
      return;
    }
    _rowsInputs = inputs;
    _held = false;
    final previousLength = _rows.length;
    final previousRows = _rows;
    final previousKeys = _index;
    final previousSplit = _split;
    final previousOldest = _oldestRowSeq;
    _oldestRowSeq = s.items
        .map(
          (item) => switch (item) {
            UserChatItem(:final seq) => seq,
            AssistantChatItem(:final seq) => seq,
            ToolChatItem(:final seq) => seq,
            NoticeChatItem(:final seq) => seq,
          },
        )
        .whereType<int>()
        .firstOrNull;
    final oldestCommand = s.commands.map((command) => command.seq).whereType<int>().firstOrNull;
    if (oldestCommand != null) _oldestRowSeq = math.min(_oldestRowSeq ?? oldestCommand, oldestCommand);
    // A page can restore an older turn boundary and fold existing items
    // without adding a message or command of its own.
    final oldestTurn = s.turns.firstOrNull?.startSeq;
    if (oldestTurn != null) _oldestRowSeq = math.min(_oldestRowSeq ?? oldestTurn, oldestTurn);
    final prepended = previousOldest != null && _oldestRowSeq != null && _oldestRowSeq! < previousOldest;
    final hadPending = _rows.any((r) => r is PendingRow);
    _rows = _rowCache.update(s, foldTurns: foldTurns, artifacts: artifacts);
    _index = _rowCache.index;
    // Only a draft streaming on keeps the other rows' widgets: anything else
    // may change what a row shows beyond its own item (running, pending,
    // later items, controller lookups).
    final draftSays = _draftHasWords(s.items);
    if (!_rowCache.onlyDraftChanged || draftSays != _draftSays) _built.clear();
    _draftSays = draftSays;
    // 被插话切开的轮:前几片的摘要行(`tp<轮起点>@<插话>`)跟最后一片一起收。
    // 这一帧没建出来的(在屏幕外)不留到以后:翻回去时不该再播一遍。
    for (final row in _rows) {
      if (row is TurnProcessRow &&
          row.cut != null &&
          _settling.contains('tp${row.trace.startSeq}') &&
          _settling.add(row.key)) {
        final key = row.key;
        _afterFrame(() => _settling.remove(key));
      }
    }
    _settling.removeWhere((key) => !_index.containsKey(key));
    _autoAnswered = s.autoAnswered;
    _markFresh(previousKeys, hadPending: hadPending, loading: s.loading);

    if (s.pending.length > _lastPendingCount) {
      // 自己刚发了消息:无论之前翻到哪,都回到底部。
      _pinned = true;
      _goingUp = false;
      _followNow = true;
      _afterFrame(() => _hasNew.value = false);
    }
    _lastPendingCount = s.pending.length;

    if (!s.loading && _splitChosen && prepended) {
      // Restoring turn metadata can also change rows after a valid center.
      // Capture them using the previous split; keep that center if it survives.
      if (!_pinned) _rememberPrependAnchor(previousRows, previousSplit);
      for (final row in _rows.whereType<TurnFootnoteRow>()) {
        // This restored footnote is history, not a new row that should grow in.
        if (row.trace.startSeq < previousOldest) _fresh.remove(row.key);
      }
      final first = previousRows.skip(previousSplit).where((row) => _index.containsKey(row.key)).firstOrNull;
      if (first case AssistantRow(:final key)) {
        // Prepending can change the gap before the first surviving forward
        // row. Lay out that history change with the prepend correction.
        _snapPaddingKey = key;
        _afterFrame(() {
          if (_snapPaddingKey == key) _snapPaddingKey = null;
        });
      }
    }

    if (s.loading) {
      // (重新)加载中:等首个快照到了再定分界,别把整段历史放进 after 段。
      _splitChosen = false;
      _splitKey = null;
    } else if (!_splitChosen) {
      _splitChosen = true;
      _splitKey = _lastStableKey(beforeSeq: s.runningTurn?.startSeq);
      _snapNext = true;
    } else if (_splitKey == null && prepended) {
      // A partial window can have no stable row before its running turn.
      // Reselect only from newly loaded history, never from the old forward
      // segment when completion removes the running-turn cutoff.
      _splitKey = _lastStableKey(beforeSeq: math.min(previousOldest, s.runningTurn?.startSeq ?? previousOldest));
      for (var i = 0; i < _split; i++) {
        _fresh.remove(_rows[i].key);
      }
    } else if (_splitKey != null && !_index.containsKey(_splitKey)) {
      // 锚点行被替换(重新同步后结构变了):重新分界,贴底时跟上。
      final folded = _rows.whereType<TurnProcessRow>().where((row) => row.rows.any((child) => child.key == _splitKey));
      _splitKey = folded.isEmpty ? _lastStableKey(beforeSeq: s.runningTurn?.startSeq) : folded.first.key;
    }

    if (uiTraceEnabled) {
      uiTrace('chat-list', 'rows', {
        'rows': _rows.length,
        'split': _split,
        'loading': s.loading,
        'pinned': _pinned,
        'held': _held,
      });
    }
    if (s.hasMoreHistory) {
      // 内容不满一屏时没有滚动事件可等:帧后看一眼是否已经在顶端。
      _afterFrame(() {
        if (_scroll.hasClients) _maybeLoadOlder(_scroll.position);
      });
    }

    if (_pinned) {
      _follow();
    } else if (_rows.length != previousLength || s.running) {
      _afterFrame(() => _hasNew.value = true);
    }
  }

  /// Drafts trail the list (no seq yet).
  static bool _draftHasWords(List<ChatItem> items) {
    for (var i = items.length - 1; i >= 0; i--) {
      switch (items[i]) {
        case AssistantChatItem(seq: null, :final text) when text.trim().isNotEmpty:
          return true;
        case AssistantChatItem(seq: null) || ToolChatItem(seq: null):
          continue;
        default:
          return false;
      }
    }
    return false;
  }

  /// 这次派生里新出现的行,哪些要淡入上移。
  ///
  /// 只认打开会话之后、在底部新长出来的"消息":气泡、回复、卡片、提示。
  /// 重新分组(三次调用并成一组、一轮结束收起过程)换了主键但不是新内容,
  /// 不播;回显的用户消息替换的是刚才的乐观气泡,也不播。
  void _markFresh(Map<String, int> previous, {required bool hadPending, required bool loading}) {
    _fresh.removeWhere((key, _) => !_index.containsKey(key));
    if (!_splitChosen || loading) return;
    final split = _split;
    var order = 0;
    for (var i = split; i < _rows.length; i++) {
      final row = _rows[i];
      if (previous.containsKey(row.key)) continue;
      final animate = switch (row) {
        PendingRow() ||
        AssistantRow() ||
        ToolCallRow() ||
        NoticeRowData() ||
        ApprovalRow() ||
        QuestionRow() ||
        ChangeCardRow() ||
        ArtifactCardRow() ||
        CommandNoticeRow() ||
        TurnFootnoteRow() => true,
        UserRow() => !hadPending,
        _ => false,
      };
      if (animate) _fresh[row.key] = order++;
    }
  }

  /// build 期间不能改 notifier(会在同一帧标脏别的元素):挪到帧后。
  void _afterFrame(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) action();
    });
  }

  String? _lastStableKey({int? beforeSeq}) {
    for (var i = _rows.length - 1; i >= 0; i--) {
      final row = _rows[i];
      if (!row.stable) continue;
      // A durable message in the running turn can still be folded away.
      // Keep the whole turn after the center, including steering pieces,
      // so its completion cannot move the history the person is reading.
      if (beforeSeq != null) {
        final seq = switch (row) {
          UserRow(:final item) => item.seq,
          AssistantRow(:final item) => item.seq,
          NoticeRowData(:final item) => item.seq,
          TurnProcessRow(:final trace) => trace.endSeq,
          TurnFootnoteRow(:final trace) => trace.endSeq,
          CommandNoticeRow(:final notice) => notice.seq,
          _ => null,
        };
        if (seq == null || seq >= beforeSeq) continue;
      }
      return row.key;
    }
    return null;
  }

  int get _split {
    final key = _splitKey;
    if (key == null) return 0;
    final i = _index[key];
    return i == null ? 0 : i + 1;
  }

  Iterable<({String key, RenderBox body, double offset})> _laidOutForwardRows(List<ChatRow> rows, int split) sync* {
    final sliver = _centerKey.currentContext?.findRenderObject();
    if (sliver is! RenderSliverMultiBoxAdaptor) return;
    for (RenderBox? child = sliver.firstChild; child != null; child = sliver.childAfter(child)) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      final index = data.index;
      if (index == null || data.layoutOffset == null) continue;
      final at = split + index;
      if (at < 0 || at >= rows.length) continue;
      // _buildRow's outer Padding owns the inter-message gap. Anchor its
      // child so a newly inserted leading gap cannot move the read text.
      RenderBox? box = child;
      while (box != null && box is! RenderPadding) {
        box = switch (box) {
          RenderProxyBox(:final child) || RenderShiftedBox(:final child) => child,
          _ => null,
        };
      }
      if (box case RenderPadding(child: final body?) when body.hasSize) {
        // A sliver coordinate excludes scroll motion and viewport resizing.
        // It remains valid when a prepend arrives during a drag or fling.
        yield (
          key: rows[at].key,
          body: body,
          offset: data.layoutOffset! + body.localToGlobal(Offset.zero, ancestor: child).dy,
        );
      }
    }
  }

  void _rememberPrependAnchor(List<ChatRow> previousRows, int previousSplit) {
    for (final row in _laidOutForwardRows(previousRows, previousSplit)) {
      if (!_index.containsKey(row.key)) continue;
      final viewport = RenderAbstractViewport.of(row.body);
      final top = row.body.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (top + row.body.size.height <= widget.topInset || top >= (_lastViewport ?? 0) - widget.bottomInset) continue;
      _prependAnchor = (key: row.key, offset: row.offset);
      return;
    }
  }

  double _prependCorrection() {
    final anchor = _prependAnchor;
    _prependAnchor = null;
    if (anchor == null) return 0;
    for (final row in _laidOutForwardRows(_rows, _split)) {
      if (row.key == anchor.key) return row.offset - anchor.offset;
    }
    return 0;
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(chatProvider(widget.sessionId));
    _running = s.running;
    _deriveRows(
      s,
      foldTurns: ref.watch(settingsProvider.select((s) => s.foldCompletedTurns)),
      artifacts: ref.watch(sessionArtifactsProvider(widget.sessionId)),
    );
    final rows = _rows;
    final split = _split;
    _fluid = AppMotion.fluid(context);
    final motion = AppMotion.of(context, AppMotion.quick);
    // A language switch rebuilds every element (app.dart) without an
    // inherited change; rows hold [appL10n] strings in their arguments.
    final locale = AppLocale.current;
    if (motion != _builtMotion || locale != _builtLocale) {
      _builtMotion = motion;
      _builtLocale = locale;
      _built.clear();
    }

    // Images in replies read this conversation's workspace.
    final headroom = ref.watch(petHeadroomProvider);
    ref.listen(petHeadroomProvider, (_, _) {
      if (_pinned) _follow();
    });
    // Back in the app to read a result (a finished phone task): the newest line.
    ref.listen(chatRevealProvider, (_, reveal) {
      if (reveal?.sessionId == widget.sessionId) jumpToBottom();
    });
    return MarkdownImageScope(
      sessionId: widget.sessionId,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = constraints.maxHeight;
          if (_lastViewport != null && _lastViewport != viewport && _pinned) {
            _follow();
          }
          // The chat page's pet stands over the composer: the last line
          // stops clear of it (0 without a pet).
          final bottomPad = widget.bottomInset + AppSpace.sm + headroom;
          final anchor = viewport <= 0 ? 1.0 : ((viewport - bottomPad) / viewport).clamp(0.0, 1.0);
          final anchorPixels = viewport * anchor;
          if (_lastViewport != null && !_pinned && _scroll.hasClients) {
            // The composer can shrink when a turn ends. Preserve the same
            // visible history as its bottom-anchored viewport grows, without
            // ending a drag or fling with jumpTo.
            final shift = anchorPixels - _anchorPixels;
            if (shift != 0) _scroll.position.correctBy(shift);
          }
          _lastViewport = viewport;
          _anchorPixels = anchorPixels;

          return Stack(
            children: [
              Listener(
                onPointerDown: (_) {
                  _fingers++;
                  // The list stops where it is, under the finger.
                  if (_gliding) {
                    _stopGlide();
                    _followWaiting = true;
                  }
                  _held = true;
                },
                onPointerUp: (_) => _onFingerUp(),
                onPointerCancel: (_) => _onFingerUp(),
                child: NotificationListener<ScrollMetricsNotification>(
                  onNotification: _onMetrics,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    child: CustomScrollView(
                      controller: _scroll,
                      physics: _physics,
                      // Material's stretch indicator moves the painted first
                      // row even while clamping physics holds its pixels.
                      scrollBehavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
                      center: _centerKey,
                      anchor: anchor,
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
                      slivers: [
                        SliverToBoxAdapter(child: SizedBox(height: widget.topInset + AppSpace.sm)),
                        SliverToBoxAdapter(
                          key: _historyKey,
                          child: _HistoryHeader(
                            loading: s.loadingOlder || (s.loading && rows.isEmpty),
                            hasMore: s.hasMoreHistory,
                          ),
                        ),
                        SliverList(
                          key: _beforeKey,
                          delegate: SliverChildBuilderDelegate(
                            (context, i) => _buildRow(split - 1 - i),
                            childCount: split,
                            findChildIndexCallback: (key) {
                              final i = key is ValueKey<String> ? _index[key.value] : null;
                              return i == null || i >= split ? null : split - 1 - i;
                            },
                          ),
                        ),
                        SliverList(
                          key: _centerKey,
                          delegate: SliverChildBuilderDelegate(
                            (context, i) => _buildRow(split + i),
                            childCount: rows.length - split,
                            findChildIndexCallback: (key) {
                              final i = key is ValueKey<String> ? _index[key.value] : null;
                              return i == null || i < split ? null : i - split;
                            },
                          ),
                        ),
                        SliverToBoxAdapter(child: SizedBox(height: bottomPad)),
                      ],
                    ),
                  ),
                ),
              ),
              // 浮层与阅读列边缘、与输入条之间都是 12(和顶栏、输入条同一层);
              // 手机上阅读列就是整屏宽。
              Positioned(
                right: math.max(0.0, (constraints.maxWidth - AppSpace.readingWidth) / 2) + AppSpace.floatInset,
                bottom: widget.bottomInset + 12,
                // The pet keeps out of the key's way while it shows.
                child: ValueListenableBuilder<bool>(
                  valueListenable: _showJump,
                  builder: (context, visible, child) => PetAvoid(active: visible, child: child!),
                  child: _JumpToBottom(
                    visible: _showJump,
                    hasNew: _hasNew,
                    waiting: s.questions.length + s.approvals.where((a) => !s.autoAnswered.contains(a.eventId)).length,
                    onTap: jumpToBottom,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRow(int index) {
    final row = _rows[index];
    final previous = index > 0 ? _rows[index - 1] : null;
    final gap = _gapBefore(row, previous);
    final fresh = _fresh.remove(row.key);
    // A row's first appearance (fade in, settle) plays once: that build is
    // not kept, or scrolling back to the row would play it again.
    if (fresh != null || _settling.contains(row.key)) {
      _built.remove(row.key);
      return _rowFrame(row, gap, fresh);
    }
    final built = _built[row.key];
    if (built != null && identical(built.row, row) && built.gap == gap) return built.widget;
    final frame = _rowFrame(row, gap, null);
    _built[row.key] = (row: row, gap: gap, widget: frame);
    return frame;
  }

  Widget _rowFrame(ChatRow row, double gap, int? fresh) {
    final padding = EdgeInsets.fromLTRB(AppSpace.gutter, gap, AppSpace.gutter, 0);
    final body = StreamFadeIn(
      enabled: fresh != null,
      index: fresh ?? 0,
      rise: row is UserRow || row is PendingRow,
      child: _rowWidget(row),
    );
    return KeyedSubtree(
      key: ValueKey<String>(row.key),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSpace.readingWidth),
          // 撑满阅读宽度:否则短行(用户气泡、提示行)会被 Center 居中。
          child: row is AssistantRow
              // 等待和思考算过程行,正文不算:接上正文时间距缓缓让开,回复不跳。
              ? AnimatedPadding(
                  duration: row.key == _snapPaddingKey ? Duration.zero : AppMotion.of(context, AppMotion.quick),
                  curve: AppMotion.std,
                  padding: padding,
                  child: SizedBox(width: double.infinity, child: body),
                )
              : Container(width: double.infinity, padding: padding, child: body),
        ),
      ),
    );
  }

  /// 过程行:工具、工具组、只有思考的回复(或还在等第一个字:接上来多半是思考,
  /// 间距先按它算,交接时不跳)、斜杠指令、非错误提示。
  /// 它们自带上下 4 的留白,彼此之间不再加间距(图形块之间正好 8)。
  static bool _isProcess(ChatRow? row) => switch (row) {
    ToolCallRow() || ToolGroupRow() || CommandNoticeRow() => true,
    AssistantRow(:final item) => item.text.trim().isEmpty && (item.reasoning.trim().isNotEmpty || item.streaming),
    NoticeRowData(:final item) => item.kind != 'error',
    _ => false,
  };
  static bool _isUser(ChatRow? row) => switch (row) {
    UserRow() => true,
    PendingRow(:final prompt) => !prompt.isBackgroundTask,
    _ => false,
  };

  /// 换轮 24、同一轮 8、相邻过程行 0、卡片 12、脚注 4(全是 4 的倍数)。
  static double _gapBefore(ChatRow row, ChatRow? previous) {
    if (previous == null) return 0;
    if (_isUser(row)) return _isUser(previous) ? AppSpace.sm : AppSpace.xxl;
    if (_isProcess(row) && _isProcess(previous)) return 0;
    if (row is ApprovalRow || row is QuestionRow || row is ChangeCardRow || row is ArtifactCardRow) {
      return AppSpace.md;
    }
    if (row is TurnFootnoteRow) return AppSpace.xs;
    return AppSpace.sm;
  }

  Widget _pendingBubble(PendingPrompt prompt) {
    if (prompt.isBackgroundTask) {
      return BackgroundTaskNotice(key: ValueKey((widget.sessionId, prompt.requestId, prompt.inboxId)), prompt: prompt);
    }
    if (dshUiReplyChip(prompt.text) case final label? when !prompt.failed) {
      return DshUiReplyChip(label: label, pending: true);
    }
    final chat = ref.read(chatProvider(widget.sessionId).notifier);
    final (label, icon) = switch ((prompt.slot, prompt.mode)) {
      // In the inbox with no turn to take it: stopped elsewhere, or before
      // this app looked.
      (_?, _) when !_running => (appL10n.chatUnsent, AppIcons.paused),
      (InboxSlot.nextStep, _) => (appL10n.chatSteerNextStep, AppIcons.steer),
      (InboxSlot.nextTurn, _) => (appL10n.chatQueuedAfterTurn, AppIcons.queued),
      (null, SendMode.steer) => (appL10n.chatSteering, AppIcons.steer),
      (null, SendMode.queue) => (appL10n.chatQueued, AppIcons.queued),
      (null, SendMode.interrupt) => (appL10n.chatStoppingTurn, AppIcons.interrupt),
      (null, SendMode.now) => (appL10n.chatSending, AppIcons.queued),
    };
    final canAct = prompt.inboxId != null;
    return UserBubble(
      text: withoutAppNotes(prompt.text),
      attachments: prompt.attachments.isEmpty ? null : SentAttachments.pending(prompt.attachments),
      pendingLabel: prompt.failed ? appL10n.chatFailedSubmission : label,
      pendingIcon: prompt.failed ? AppIcons.error : icon,
      pendingActions: [
        if (prompt.failed && prompt.resendable) (appL10n.chatEditFailedSubmission, () => _editFailedSubmission(prompt)),
        if (canAct && prompt.resendable && widget.onSendNow != null)
          (_running ? appL10n.chatSendNow : appL10n.commonSend, () => widget.onSendNow!(prompt)),
        if (canAct && _running && prompt.slot == InboxSlot.nextTurn)
          (appL10n.chatSwitchToSteer, () => chat.steerQueued(prompt)),
        if (canAct && widget.onWithdraw != null) (appL10n.chatWithdraw, () => widget.onWithdraw!(prompt)),
      ],
    );
  }

  Future<void> _editFailedSubmission(PendingPrompt prompt) async {
    final sessionId = widget.sessionId;
    final client = ref.read(activeConnectionProvider).value?.client;
    final generation = client?.mux.generation;
    final readyNumber = client?.mux.lastReadyGenerationNumber;
    var retired = false;
    final connection = ref.listenManual(activeConnectionProvider.select((c) => c.value?.client), (_, next) {
      if (!identical(next, client)) retired = true;
    });
    var text = withoutAppNotes(prompt.text);
    try {
      final edited = await showAppDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(appL10n.chatEditFailedSubmission),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  initialValue: text,
                  onChanged: (value) => text = value,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 8,
                ),
                if (prompt.attachments.isNotEmpty) SentAttachments.pending(prompt.attachments),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog), child: Text(appL10n.commonCancel)),
            TextButton(onPressed: () => Navigator.pop(dialog, text), child: Text(appL10n.commonSend)),
          ],
        ),
      );
      if (edited == null ||
          !mounted ||
          retired ||
          widget.sessionId != sessionId ||
          !identical(ref.read(activeConnectionProvider).value?.client, client) ||
          !identical(client?.mux.generation, generation) ||
          client?.mux.lastReadyGenerationNumber != readyNumber) {
        return;
      }
      // Emptied: as before, nothing to send (the notes alone are not a message).
      final retry = edited.trim().isEmpty ? edited : withAppNotesOf(prompt.text, edited);
      await ref.read(chatProvider(sessionId).notifier).retryFailed(prompt, retry);
    } finally {
      connection.close();
    }
  }

  // ---------------------------------------------------------------------------
  // 消息操作:分叉打开的是一个新对话,原对话不动。

  Widget _reply(AssistantChatItem item, bool showActions, TurnTrace? footnote) {
    // A picture a media card shows is not drawn again in the reply.
    if (withoutShownImages(item.text, ref.read(sessionMediaPathsProvider(widget.sessionId))) case final text?) {
      item = replyWithText(item, text);
    }
    final chat = ref.read(chatProvider(widget.sessionId).notifier);
    final branchable = chat.branchPointAfter(item) != null;
    // 「重新回答」: the conversation's last reply, its turn over cleanly.
    final prompt = branchable && widget.onResend != null
        ? regenerablePrompt(ref.read(chatProvider(widget.sessionId)), item)
        : null;
    final message = AssistantMessage(
      item: item,
      showActions: showActions,
      onBranch: branchable ? () => _branch(item) : null,
      branching: _forkingId == item.id,
      onRegenerate: prompt == null ? null : () => _regenerate(item, prompt),
      regenerating: _regeneratingId == item.id,
      onQuote: widget.onQuote == null ? null : _quote,
      footnote: footnote == null ? null : _footnote(footnote),
    );
    // Always in a scope, so a reply that grows a visual block keeps its
    // State; only replies that carry one pay for working out whether it can
    // still be answered.
    final s = ref.read(chatProvider(widget.sessionId));
    return DshUiScope(
      sessionId: widget.sessionId,
      messageId: item.id,
      state: !item.text.contains('dsh-ui') && !item.text.contains('{')
          ? DshUiState.expired
          : dshUiStateFor(
              items: s.items,
              messageId: item.id,
              running: s.running,
              pending: [for (final p in s.pending) p.text],
            ),
      onReply: chat.send,
      onAskResend: chat.send,
      child: message,
    );
  }

  Widget _footnote(TurnTrace trace) => Consumer(
    builder: (context, ref, _) => TurnFootnote(
      trace: trace,
      notes: ref.watch(nativeTurnNoteProvider((widget.sessionId, trace.turn))),
      onTap: () => showTrajectorySheet(context, sessionId: widget.sessionId, turn: trace.turn),
    ),
  );

  Future<void> _branch(AssistantChatItem item) async {
    if (_forkingId != null || _regeneratingId != null) return;
    _clearBuiltRows(() => _forkingId = item.id);
    try {
      final messenger = ScaffoldMessenger.maybeOf(context);
      final outcome = await ref.read(chatProvider(widget.sessionId).notifier).branchAfter(item);
      if (outcome == null || !mounted) return;
      _openFork(outcome, messenger, appL10n.chatContinuedInNewChat);
    } finally {
      if (mounted) _clearBuiltRows(() => _forkingId = null);
    }
  }

  /// 「重新回答」: read the prompt's images back, fork just before it, open
  /// the fork, and let the screen send the prompt there again. The source
  /// stays as it was. A failure before the fork stays here, in the banner.
  Future<void> _regenerate(AssistantChatItem item, UserChatItem prompt) async {
    final resend = widget.onResend;
    if (resend == null || _forkingId != null || _regeneratingId != null) {
      return;
    }
    // Image loading precedes the controller operation. Keep that preparation
    // attached to the connection on which the user chose to regenerate.
    final sessionId = widget.sessionId;
    final client = ref.read(activeConnectionProvider).value?.client;
    final generation = client?.mux.generation;
    final readyGeneration = client?.mux.lastReadyGenerationNumber;
    var retired = false;
    final connection = ref.listenManual(activeConnectionProvider.select((c) => c.value?.client), (_, next) {
      if (!identical(next, client)) retired = true;
    });
    bool current() =>
        mounted &&
        !retired &&
        widget.sessionId == sessionId &&
        identical(ref.read(activeConnectionProvider).value?.client, client) &&
        identical(client?.mux.generation, generation) &&
        client?.mux.lastReadyGenerationNumber == readyGeneration;
    _clearBuiltRows(() => _regeneratingId = item.id);
    try {
      final messenger = ScaffoldMessenger.maybeOf(context);
      final chat = ref.read(chatProvider(sessionId).notifier);
      final List<DraftAttachment> images;
      try {
        images = await resendImages(prompt, (image) => sessionImageBytes(ref, sessionId, image));
      } catch (_) {
        if (current()) chat.reportError(appL10n.chatReadOriginalImageFailed);
        return;
      }
      if (!current()) return;
      final outcome = await chat.forkBeforePrompt(prompt, action: appL10n.chatRegenerateFailed);
      if (outcome == null || !current()) return;
      _openFork(outcome, messenger, appL10n.chatRegeneratedInNewChat);
      // This list goes with the switch; the screen stays and sends.
      unawaited(resend(outcome.sessionId, prompt.text, images));
    } finally {
      connection.close();
      if (mounted) _clearBuiltRows(() => _regeneratingId = null);
    }
  }

  Future<void> _editPrompt(UserChatItem item) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final compose = widget.onEditPrompt;
    final outcome = await ref.read(chatProvider(widget.sessionId).notifier).forkBeforePrompt(item);
    if (outcome == null || !mounted) return;
    final attached = item.images.isNotEmpty || item.files.isNotEmpty;
    _openFork(outcome, messenger, attached ? appL10n.chatOpenedInNewChatReattach : appL10n.chatOpenedInNewChat);
    compose?.call(withoutAppNotes(item.text));
  }

  /// Switches to the fork; the toast offers the way back.
  void _openFork(ForkOutcome outcome, ScaffoldMessengerState? messenger, String message) {
    final source = widget.sessionId;
    final current = ref.read(currentSessionProvider.notifier);
    unawaited(ref.read(sessionsProvider.notifier).refresh());
    current.select(outcome.sessionId);
    final left = outcome.leftQueued;
    final text = left == 0 ? message : appL10n.chatForkQueuedLeft(message, left);
    void back() => current.select(source);
    if (widget.onToast case final toast?) {
      toast(text, actionLabel: appL10n.chatReturnToOriginal, onAction: back);
      return;
    }
    messenger?.showSnackBar(
      SnackBar(
        content: Text(text),
        persist: false,
        action: SnackBarAction(label: appL10n.chatReturnToOriginal, onPressed: back),
      ),
    );
  }

  /// 「子代理 · …」: that child's conversation, once the host lists it.
  bool _openSubagent(String id) {
    if (!ref.read(hostSessionsProvider).containsKey(id)) return false;
    selectConversation(ref, id);
    return true;
  }

  /// 对话停在出错、被打断或输出到上限的一轮上:提示行尾给一个「重试」
  /// (这一轮什么都还没做、问的是纯文字,原样再发)或「继续」。
  /// 引擎拒绝这个模型时给去处:本机引擎太旧就「检查更新」(引擎随 App
  /// 更新),其余「换模型」。上下文超限也先换模型,不原样重发。
  NoticeAction? _noticeAction(NoticeChatItem notice) {
    final s = ref.read(chatProvider(widget.sessionId));
    if (s.running) return null;
    final code = notice.failure?.code ?? '';
    final refused = notice.kind == 'error' && (modelRefusalCodes.contains(code) || code == 'CONTEXT_WINDOW_EXCEEDED');
    final repeatable = switch (notice.kind) {
      // 换个说法、再发一次都没用的:Key、余额、账号额度、模型本身用不了。
      'error' =>
        !refused && !const {'AUTH', 'INVALID_CREDENTIAL', 'QUOTA'}.contains(code) && !code.startsWith('ACCOUNT_'),
      'interrupted' || 'max-tokens' => true,
      _ => false,
    };
    if (!repeatable && !refused) return null;
    final at = s.items.lastIndexOf(notice);
    if (at < 0 || s.items.skip(at + 1).any((item) => item is! NoticeChatItem || item.kind != 'retry')) {
      return null;
    }
    if (refused) {
      if (code == 'CLIENT_UPGRADE_REQUIRED' && !wordsForIos && ref.read(activeHostProvider).kind == HostKind.local) {
        return (label: appL10n.updateCheck, onPressed: () => checkForUpdates(context, ref));
      }
      return widget.onSwitchModel == null ? null : (label: appL10n.chatSwitchModel, onPressed: _switchModel);
    }
    if (s.pending.isNotEmpty) return null;
    final turn = s.turns.where((turn) => turn.endSeq == notice.seq).firstOrNull;
    if (turn == null) return null;
    UserChatItem? prompt;
    var worked = false;
    for (var i = at - 1; i >= 0 && prompt == null; i--) {
      final item = s.items[i];
      if (item is NoticeChatItem && item.kind != 'retry') break;
      if (item is UserChatItem && item.seq < turn.startSeq) break;
      switch (item) {
        case final UserChatItem item:
          prompt = item;
        case ToolChatItem():
          worked = true;
        case AssistantChatItem(:final text) when text.trim().isNotEmpty:
          worked = true;
        default:
          break;
      }
    }
    if (prompt == null) return null;
    final chat = ref.read(chatProvider(widget.sessionId).notifier);
    if (notice.kind == 'error' &&
        !worked &&
        prompt.images.isEmpty &&
        prompt.files.isEmpty &&
        prompt.text.trim().isNotEmpty) {
      final text = prompt.text;
      return (label: appL10n.commonRetry, onPressed: () => chat.send(text));
    }
    return (label: appL10n.commonContinue, onPressed: () => chat.send(appL10n.commonContinue));
  }

  Widget _rowWidget(ChatRow row) {
    return switch (row) {
      UserRow(:final item) when dshUiReplyChip(item.text) != null => DshUiReplyChip(label: dshUiReplyChip(item.text)!),
      UserRow(:final item) => UserBubble(
        text: withoutAppNotes(item.text),
        attachments: item.images.isEmpty && item.files.isEmpty
            ? null
            : SentAttachments.echoed(sessionId: widget.sessionId, images: item.images, files: item.files),
        onEdit: widget.onEditPrompt == null ? null : () => _editPrompt(item),
      ),
      PendingRow(:final prompt) => _pendingBubble(prompt),
      AssistantRow(:final item, :final showActions, :final footnote) => _reply(item, showActions, footnote),
      TurnFootnoteRow(:final trace) => Bleed(
        horizontal: 8,
        child: Align(alignment: Alignment.centerLeft, child: _footnote(trace)),
      ),
      ToolCallRow(:final item, :final card) => ToolRow(
        item: item,
        card: card,
        onRespond: _respond,
        onAllowAll: _allowAll,
        autoAnswered: _autoAnswered,
        onOpenSubagent: _openSubagent,
      ),
      ToolGroupRow(:final tools, :final live) => ToolGroup(
        tools: tools,
        live: live,
        onRespond: _respond,
        onAllowAll: _allowAll,
        autoAnswered: _autoAnswered,
        onOpenSubagent: _openSubagent,
      ),
      final TurnProcessRow row => TurnProcess(
        row: row,
        settle: _settling.remove(row.key),
        buildRow: _rowWidget,
        gapBefore: _gapBefore,
      ),
      NoticeRowData(:final item) => NoticeRow(item: item, action: _noticeAction(item)),
      ChangeCardRow(:final files) => ChangeCard(files: files),
      ArtifactCardRow(:final group) => ArtifactCard(sessionId: widget.sessionId, group: group),
      CommandNoticeRow(:final notice) => CommandRow(notice: notice),
      ApprovalRow(:final request) => ApprovalCard(request: request, onRespond: _respond, onAllowAll: _allowAll),
      QuestionRow(:final request) => _InlineEditorReveal(
        onShow: _revealInlineEditor,
        child: QuestionCard(request: request, onAnswer: _answer, onReject: _rejectQuestion),
      ),
    };
  }
}

/// Intercept only the focused question editor's original reveal request,
/// before the centered scroll view can misclassify it as already visible.
class _InlineEditorReveal extends SingleChildRenderObjectWidget {
  const _InlineEditorReveal({required this.onShow, required super.child});

  final bool Function(RenderObject, Rect?, Duration, Curve) onShow;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderInlineEditorReveal(onShow);

  @override
  void updateRenderObject(BuildContext context, _RenderInlineEditorReveal renderObject) {
    renderObject.onShow = onShow;
  }
}

class _RenderInlineEditorReveal extends RenderProxyBox {
  _RenderInlineEditorReveal(this.onShow);

  bool Function(RenderObject, Rect?, Duration, Curve) onShow;

  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (descendant != null && onShow(descendant, rect, duration, curve)) return;
    super.showOnScreen(descendant: descendant, rect: rect, duration: duration, curve: curve);
  }
}

/// 列表顶端:加载更早历史时的小环;没有更多时什么也不画。
class _HistoryHeader extends StatelessWidget {
  const _HistoryHeader({required this.loading, required this.hasMore});

  final bool loading;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    if (!loading && !hasMore) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: Center(
        child: loading
            ? SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 1.8, color: Theme.of(context).colorScheme.primary),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

/// 回到底部:输入条右上方的 chrome 玻璃圆钮(44 / 图标 22,与顶栏圆钮
/// 同规格);离开期间有新内容加主色角标。有待确认的审批 / 提问时换成一枚
/// 同高的胶囊。两种形态之间交叉淡变。
class _JumpToBottom extends StatelessWidget {
  const _JumpToBottom({required this.visible, required this.hasNew, required this.waiting, required this.onTap});

  final ValueListenable<bool> visible;
  final ValueListenable<bool> hasNew;
  final int waiting;
  final VoidCallback onTap;

  static const _size = 44.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final quick = AppMotion.of(context, AppMotion.quick);
    final fluid = AppMotion.fluid(context);

    final pill = GlassSurface(
      key: const ValueKey('waiting'),
      tier: GlassTier.chrome,
      // 悬在滚动 / 流式内容上:每帧重采样背景太贵,这两颗悬浮胶囊直接不模糊。
      blur: false,
      stadium: true,
      onTap: onTap,
      child: SizedBox(
        height: _size,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.approval, size: 18, color: dsh.warning),
              const SizedBox(width: 8),
              Text(l10n.chatWaitingCount(waiting), style: AppType.tabular(theme.textTheme.labelLarge!)),
              const SizedBox(width: 4),
              Icon(AppIcons.scrollToBottom, size: 18, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );

    final circle = SizedBox.square(
      key: const ValueKey('jump'),
      dimension: _size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GlassSurface(
              tier: GlassTier.chrome,
              blur: false,
              circle: true,
              onTap: onTap,
              child: Center(child: Icon(AppIcons.scrollToBottom, size: 22, color: colors.onSurface)),
            ),
          ),
          // 角标圆心落在圆钮 45° 的边上(离右上角 22·(1−cos45°) ≈ 6.4)。
          Positioned(
            top: 2,
            right: 2,
            child: ValueListenableBuilder<bool>(
              valueListenable: hasNew,
              builder: (context, fresh, _) => AnimatedScale(
                scale: fresh ? 1 : 0,
                duration: fluid && fresh ? AppMotion.popCurve.duration : quick,
                curve: fluid && fresh ? AppMotion.popCurve : AppMotion.std,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.surface, width: 1.5),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (context, show, _) => IgnorePointer(
        ignoring: !show,
        child: AnimatedScale(
          scale: show ? 1 : (fluid ? 0.6 : 0.8),
          duration: fluid && show ? AppMotion.popCurve.duration : quick,
          curve: fluid && show ? AppMotion.popCurve : AppMotion.enter,
          child: AnimatedOpacity(
            opacity: show ? 1 : 0,
            duration: quick,
            child: Semantics(
              button: true,
              label: waiting > 0 ? l10n.chatWaitingBackToBottom(waiting) : l10n.chatBackToBottom,
              excludeSemantics: true,
              onTap: onTap,
              child: AnimatedSwitcher(
                duration: quick,
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.centerRight, children: [...previous, ?current]),
                child: waiting > 0 ? pill : circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 贴底跟随:跟随中(且这一刻本来就停在末尾)内容高度一变,在同一次布局
/// 里把位置放到新的末尾。拖动、惯性滚动中不插手。
///
/// 默认的 [RangeMaintainingScrollPhysics] 只在"变矮且越界"时夹回范围,而
/// 且上一帧刚 `jumpTo` 过就不夹:那一帧末尾露出一道缝,再由回弹动画收回,
/// 看起来像被往上推了一下。
class _FollowPhysics extends ScrollPhysics {
  const _FollowPhysics(this.follows, {required this.glides, super.parent});

  final bool Function() follows;

  /// A taller list is left for the glide to catch up with. Shorter still lands at once:
  /// a gap at the bottom can't wait.
  final bool Function() glides;

  @override
  _FollowPhysics applyTo(ScrollPhysics? ancestor) =>
      _FollowPhysics(follows, glides: glides, parent: buildParent(ancestor));

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
    // 上一帧之后可能刚追过底(帧后 jumpTo):看当前位置,也看上次记下的。
    final at = newPosition.pixels > oldPosition.pixels ? newPosition.pixels : oldPosition.pixels;
    if (oldPosition.maxScrollExtent - at > 1 && !glides()) return adjusted;
    if (glides() && newPosition.maxScrollExtent >= at) return adjusted;
    return newPosition.maxScrollExtent;
  }
}

/// Keeps the center anchor while removing the viewport's artificial leading
/// gap using the same (possibly estimated) sliver geometry as the viewport.
/// Near the leading edge, a short reverse segment is fully laid out and its
/// extent is exact. Long reverse segments keep Flutter's original extent.
/// If all content fits, the bounds coincide and dragging cannot move it away
/// from the top.
class _TopBoundedScrollController extends ScrollController {
  _TopBoundedScrollController(this.leadingBoundary, this.prependCorrection);

  final double? Function() leadingBoundary;
  final double Function() prependCorrection;

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _TopBoundedScrollPosition(
        leadingBoundary: leadingBoundary,
        prependCorrection: prependCorrection,
        physics: physics,
        context: context,
        initialPixels: initialScrollOffset,
        keepScrollOffset: keepScrollOffset,
        oldPosition: oldPosition,
        debugLabel: debugLabel,
      );
}

class _TopBoundedScrollPosition extends ScrollPositionWithSingleContext {
  _TopBoundedScrollPosition({
    required this.leadingBoundary,
    required this.prependCorrection,
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final double? Function() leadingBoundary;
  final double Function() prependCorrection;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    // The slivers now have actual geometry. Retry this layout at the same
    // readable row, without estimating heights or ending a drag/fling.
    final correction = prependCorrection();
    if (correction.abs() > precisionErrorTolerance) {
      correctBy(correction);
      return false;
    }
    if (minScrollExtent == 0) {
      final leading = leadingBoundary();
      if (leading != null && leading.isFinite && leading > 0) {
        minScrollExtent = leading;
        maxScrollExtent = math.max(leading, maxScrollExtent);
      }
    }
    // ScrollPosition skips dimension correction on its first layout. Correct
    // that initial position here and ask the same viewport layout to retry;
    // otherwise a short chat would paint at the old anchor for one frame.
    // A collapsed range is also non-scrollable while a fling is active.
    // RangeMaintainingScrollPhysics otherwise retains an out-of-range offset
    // at nonzero velocity and springs a now-short chat back over later frames.
    if (!hasContentDimensions || minScrollExtent == maxScrollExtent) {
      // The initial running turn can fill the forward segment: land at its
      // end in this layout, without painting the center for one frame first.
      final initial = hasContentDimensions ? pixels.clamp(minScrollExtent, maxScrollExtent) : maxScrollExtent;
      if (initial != pixels) {
        correctPixels(initial);
        return false;
      }
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

/// A tap on iOS's status bar: the framework's Scaffold asks the nearest primary scroll controller to
/// go to 0, and this one hands that to the conversation, whose list has its own top.
class StatusBarTop extends ScrollController {
  VoidCallback? onTap;

  @override
  bool get hasClients => true;

  @override
  Future<void> animateTo(double offset, {required Duration duration, required Curve curve}) async => onTap?.call();
}
