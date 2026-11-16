// One tavern chat (docs/design/roleplay-ui.md §2, §7): the current path of the
// tree, the reply as it streams, alternatives under the last reply (‹ 2/5 ›),
// and a long-press menu for the rest. Messages draw with the chat's own
// widgets for now; the canvas (WebView, ST's display pipeline) replaces the
// list once regex and HTML land (R2).

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/l10n.dart';
import '../../speech/read_aloud.dart';
import '../../speech/voice_cloud.dart';
import '../speech/speech_ui.dart';
import '../../state/connection_state.dart';
import '../../state/settings_state.dart';
import '../../state/voice_model_state.dart';
import '../../state/voice_settings.dart';
import '../../state/voice_state.dart';
import '../../tavern/tavern_backgrounds.dart';
import '../../tavern/tavern_bookmarks.dart';
import '../../tavern/tavern_live2d.dart';
import '../../tavern/tavern_preview.dart';
import '../../tavern/tavern_card_theme.dart';
import '../../tavern/tavern_interact.dart';
import '../../tavern/tavern_islands.dart';
import '../../tavern/tavern_canvas.dart';
import '../../tavern/tavern_canvas_calls.dart';
import '../../tavern/tavern_card_scripts.dart';
import '../../tavern/tavern_components.dart' show tavernComponentTagsOut;
import '../../tavern/tavern_jump.dart';
import '../../tavern/tavern_markers.dart';
import '../../tavern/tavern_pinned.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_quick_replies.dart';
import '../../tavern/tavern_session_usage.dart';
import '../../tavern/tavern_settings.dart';
import '../../tavern/tavern_tool_turns.dart';
import '../../tavern/tavern_slash.dart';
import '../../tavern/tavern_sprites.dart';
import '../../usage/usage_stats.dart';
import '../bots/bot_chat_kit.dart';
import '../chat/composer.dart';
import '../chat/render/markdown_body.dart';
import '../chat/voice/voice_controller.dart';
import '../chat/widgets/notice_row.dart';
import '../chat/widgets/stream_row.dart';
import '../chat/widgets/thinking_pill.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/capsule_chip.dart';
import '../common/smooth_size.dart';
import '../common/status_dot.dart';
import '../common/typing_indicator.dart';
import '../companion/companion_stage.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../onboarding/api_key_page.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../wallpaper/wallpaper_backdrop.dart';
import 'tavern_arrive.dart';
import 'tavern_channels_page.dart' show TavernChannelEditPage;
import 'tavern_canvas_view.dart';
import 'tavern_component_view.dart';
import 'tavern_group_page.dart';
import 'tavern_character_page.dart';
import 'tavern_dice_sheet.dart';
import 'tavern_ink.dart';
import 'tavern_island.dart';
import 'tavern_inspector_page.dart';
import 'tavern_interact_view.dart';
import 'tavern_live_display.dart';
import 'tavern_message_edit_page.dart';
import 'tavern_personas.dart';
import 'tavern_quick_replies_page.dart';
import 'tavern_reading.dart';
import 'tavern_stage_panel.dart';
import 'tavern_vn_view.dart';
import 'tavern_tool_strip.dart';
import 'tavern_widgets.dart';

class TavernChatPage extends ConsumerStatefulWidget {
  const TavernChatPage({super.key, required this.chatId});

  final String chatId;

  static Route<void> route(String chatId) => MaterialPageRoute<void>(builder: (_) => TavernChatPage(chatId: chatId));

  @override
  ConsumerState<TavernChatPage> createState() => _TavernChatPageState();
}

class _TavernChatPageState extends ConsumerState<TavernChatPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scrolled = ValueNotifier(0.0);

  /// Scrolled back into the story, away from the newest lines: the chips over
  /// the box fold away for the reading (back when typing).
  final _readingBack = ValueNotifier(false);

  /// 小说, reading back: the header and the composer step aside for the
  /// story (docs/design/roleplay-roadmap.md P1), back on the way down to the
  /// newest lines, near them, or at a tap on the story.
  final _immersive = ValueNotifier(false);

  /// The frame's Scaffold: 舞台 slides in from its right edge.
  final _scaffold = GlobalKey<ScaffoldState>();

  /// Wide enough for 舞台 to stand beside the story instead of sliding in.
  static const _stageBesideFrom = 900.0;
  static const _stageWidth = 340.0;

  /// The character's Live2D model in the visual novel, when she has one; set
  /// once it can't be shown, and the card's picture stands in.
  final _stage = CompanionStageController();
  bool _stageFailed = false;

  /// The page the stage last played, played again when it (re)loads.
  TavernPage? _staged;
  late final Tavern _tavern = ref.read(tavernProvider);

  /// Held from the start: the page stops what it read aloud as it closes,
  /// when it can no longer read providers.
  late final ReadAloudController _readAloud = ref.read(readAloudProvider.notifier);

  /// Stops reading aloud if what is being read is one of the tavern's lines,
  /// and drops a read still waiting for its display text.
  void _quietTavern() {
    _readAsk++;
    _readAloud.stopWhere((id) => id.startsWith('tavern:'));
  }

  /// Counts read-aloud asks: one overtaken while its text was made is dropped.
  int _readAsk = 0;
  StreamSubscription<void>? _changes;
  StreamSubscription<Object?>? _turn;

  /// This chat's group (engine P2 125), when it is one: its roster and how
  /// it takes turns; and, while a batch runs, who speaks and who follows.
  StreamSubscription<TavernGroupChat?>? _groupWatch;
  TavernGroupChat? _group;

  /// This chat is a group's: by its own details, or its summary before they
  /// are in (a line sent then still goes to the group).
  bool _groupChat = false;
  TavernGroupProgress? _groupProgress;

  /// The director's three suggestions for now (engine T18), first in the row
  /// over the composer; none when it has not run, or its last thought is
  /// for an earlier moment.
  StreamSubscription<TavernDirectorSnapshot>? _director;
  List<String> _directed = const [];

  List<TavernMessage>? _messages;

  /// The reply being written: its node, and the text so far. Only the reply
  /// listens to the text: a piece arriving rebuilds it, not the page and every
  /// message on it.
  String? _streamNode;
  final _stream = ValueNotifier<_Streamed>(_nothing);

  /// Whole seconds the model has thought this turn, counting until its reply
  /// starts; null before any thinking. A tick, not a clock, so it can be read
  /// without asking the time.
  final _thinking = ValueNotifier<int?>(null);
  Timer? _thinkingTick;

  void _stopThinking() {
    _thinkingTick?.cancel();
    _thinkingTick = null;
  }

  /// The reply's text through the display regex, as it will show once stored.
  late final _live = TavernLiveDisplay((text) => _tavern.displayText(widget.chatId, nodeId: _streamNode, text: text));

  /// The reply being written as 整页画布 takes it: who says it and its HTML;
  /// null while nothing is being written. Fed only while the canvas shows.
  final _canvasStream = ValueNotifier<(String, String)?>(null);
  bool _canvasOn = false;

  /// A card's script on the canvas asking the engine (dsh.call): in this
  /// chat's own script context, opened on its first call.
  TavernCanvasCalls? _calls;
  String? _canvasCharacter;
  TavernCanvasCalls get _canvasCalls => _calls ??= TavernCanvasCalls(
    _tavern.scripts,
    chatId: widget.chatId,
    characterId: () => _canvasCharacter,
    pages: ref.read(tavernScriptPagesProvider),
    avatar: (id) async => tavernImageDataUrl((await _tavern.character(id))?.avatarPath),
    interact: _interact,
  )..liveButtons.addListener(_buttonsChanged);

  void _buttonsChanged() {
    if (mounted) setState(() {});
  }

  /// Whether this page has looked at the card for MVU.
  bool _mvuAsked = false;

  /// MVU being turned on for this chat; a reply starts after it, so its
  /// variables are counted from the first.
  Future<void>? _mvuOn;

  Stream<TavernEvent> _afterMvu(Stream<TavernEvent> Function() start) {
    final on = _mvuOn;
    return on == null ? start() : Stream.fromFuture(on.catchError((_) {})).asyncExpand((_) => start());
  }

  /// Turns the engine's MVU on for this chat, once: the card's [initvar]
  /// read in, and its replies' variable updates kept from then on.
  Future<void> _turnOnMvu() async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$tavernMvuOnKey${widget.chatId}';
    if (prefs.getBool(key) ?? false) return;
    final reply = await _canvasCalls.handle({
      'id': 0,
      'method': 'setMvuEnabled',
      'params': {'enabled': true},
    });
    if (reply['ok'] == true) await prefs.setBool(key, true);
  }

  /// A card script's request to the person, shown here: a dialog, a notice,
  /// or words put in the composer (/setinput).
  Future<TavernInteractAnswer> _interact(
    TavernInteractKind kind,
    Map<String, Object?> fields, {
    required Future<void> withdraw,
  }) async {
    if (!mounted) return const TavernInteractAnswer(TavernInteractStatus.cancelled);
    return showTavernInteract(
      context,
      kind,
      fields,
      withdraw: withdraw,
      onSetInput: (text) {
        _input.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      },
    );
  }

  /// The chat's character (or a group's title), and the names of all.
  String _canvasSpeaker = '';
  Map<String, String> _canvasNames = const {};

  void _feedCanvas() {
    if (!_canvasOn) return;
    final text = _live.shown;
    // In a group, the member speaking as of their own events, which come
    // before the page rebuilds for them.
    final speaker = _canvasNames[_group == null ? null : _groupProgress?.speakerCharacterId] ?? _canvasSpeaker;
    _canvasStream.value = _running && !_drafting && text.isNotEmpty
        ? (speaker, tavernStoryHtml(tavernComponentTagsOut(tavernStripMarkers(text))))
        : null;
  }

  String? _error;

  /// [_error] is how a reply ended, not a failure: said without alarm.
  bool _calm = false;

  /// The error's button: 「重试」 when trying again can help, 「设置」 when
  /// the key is missing or refused.
  ({String label, VoidCallback onPressed})? _action;

  bool get _running => _turn != null && !_rejoining;

  /// Listening for a reply from before this page opened, none seen yet: not
  /// running until one shows.
  bool _rejoining = false;

  /// The running turn writes into the box (帮我写), not the story.
  bool _drafting = false;

  /// Dictation into the box (§6), the main chat's: the system's recognizer,
  /// or the engine's voice model where the on-device host has it.
  late final VoiceInputController _voice;
  late final VoiceInputActiveController _voiceFlag;

  /// The host's connection, only if the app already has one: a chat page
  /// never starts connecting just to offer dictation.
  HostConnection? get _connection =>
      mounted && ref.exists(activeConnectionProvider) ? ref.read(activeConnectionProvider).value : null;

  void _reportVoice() => _voiceFlag.set(_voice.active);

  @override
  void initState() {
    super.initState();
    _readAloud; // Bound now: dispose can't read providers.
    _changes = _tavern.pathChanges(widget.chatId).listen((_) => unawaited(_reload()));
    _director = _tavern.watchDirector(widget.chatId).listen(
      (view) {
        final run = view.latestSuccess;
        final next = [
          if (run != null && !view.stale)
            for (final suggestion in run.suggestions)
              if (suggestion['text'] case final String text when text.trim().isNotEmpty) text.trim(),
        ];
        if (!listEquals(next, _directed)) setState(() => _directed = next);
      },
      // The row goes on without them.
      onError: (Object _) {},
    );
    unawaited(_reload());
    _groupWatch = _tavern
        .watchGroupChat(widget.chatId)
        .listen((group) => mounted ? setState(() => _group = group) : null, onError: (Object _) {});
    unawaited(_rejoin());
    _voice = VoiceInputController(
      input: _input,
      bridge: ref.read(voiceBridgeProvider),
      mode: () => ref.read(voiceSettingsProvider.notifier).ready(),
      cloud: (mode) => ref.read(voiceCloudProvider)(mode),
      cloudLikely: () => ref.read(voiceCloudLikelyProvider)(),
      // The voice model lives in the on-device engine: it counts for that host only.
      modelReady: () =>
          (_connection?.isLocal ?? false) && ref.read(voiceModelProvider).status == VoiceModelStatus.ready,
      client: () => _connection?.client,
    );
    _voiceFlag = ref.read(voiceInputActiveProvider.notifier);
    _voice.addListener(_reportVoice);
    _live.addListener(_feedCanvas);
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    unawaited(_director?.cancel());
    unawaited(_groupWatch?.cancel());
    // A reply goes on without the page (engine T24) and is picked up when it
    // opens again; a line being written into this page's box has nowhere to go.
    if (_running && _drafting) _tavern.stop(widget.chatId);
    // Its lines are not read on after the story is left (providers change after the tree settles).
    final readAloud = _readAloud;
    scheduleMicrotask(() => readAloud.stopWhere((id) => id.startsWith('tavern:')));
    unawaited(_turn?.cancel());
    _stream.dispose();
    _live.removeListener(_feedCanvas);
    _live.dispose();
    _canvasStream.dispose();
    unawaited(_calls?.close());
    _stopThinking();
    _thinking.dispose();
    _voice.removeListener(_reportVoice);
    _voice.dispose();
    // The page is gone, and its dictation with it.
    final flag = _voiceFlag;
    scheduleMicrotask(() => flag.set(false));
    _input.dispose();
    _focus.dispose();
    _scrolled.dispose();
    _readingBack.dispose();
    _transcript.dispose();
    _immersive.dispose();
    super.dispose();
  }

  /// Messages per page when scrolling back.
  static const _page = 60;

  /// How many of the latest messages are loaded; grows a page at a time as
  /// you scroll back, and every reload keeps it.
  int _window = _page;

  /// A full window came back: there may be older ones.
  bool _hasOlder = false;
  bool _loadingOlder = false;

  Future<void> _reload() async {
    final window = _window;
    final messages = await _tavern.path(widget.chatId, limit: window);
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _hasOlder = messages.length >= window;
    });
    unawaited(_readPinned());
  }

  /// The state the card pins, for the header's line (engine T17); none when
  /// it pins nothing or the state cannot be read.
  String? _pinned;

  Future<void> _readPinned() async {
    String? line;
    try {
      line = tavernPinnedLine(await _tavern.readState(widget.chatId));
    } on Object {
      line = null;
    }
    if (mounted && line != _pinned) setState(() => _pinned = line);
  }

  /// The transcript's scroll (newest at 0: it runs reversed).
  final _transcript = ScrollController();

  /// The message being gone to (a search hit), marked a moment once there.
  String? _jumpTarget;
  final _jumpKey = GlobalKey();

  /// Goes to [nodeId] in the story, already on the current path: loads back
  /// a page at a time until it is in the transcript, then scrolls back until
  /// it is built and brings it to the middle. Gives up quietly after a while.
  Future<void> _jumpTo(String nodeId) async {
    ref.read(tavernJumpProvider(widget.chatId).notifier).done();
    bool loaded() => _messages?.any((m) => m.nodeId == nodeId) ?? false;
    // Its branch was just switched to: read the path again, then page back.
    await _reload();
    for (var i = 0; i < 40 && mounted && !loaded() && _hasOlder; i++) {
      _window += _page;
      await _reload();
    }
    if (!mounted || !loaded()) return;
    setState(() => _jumpTarget = nodeId);
    for (var i = 0; i < 60; i++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (_jumpKey.currentContext case final row? when row.mounted) {
        await Scrollable.ensureVisible(row, alignment: 0.5, duration: const Duration(milliseconds: 280));
        break;
      }
      if (!_transcript.hasClients) continue;
      final position = _transcript.position;
      if (position.pixels >= position.maxScrollExtent) {
        // At the top of what is loaded: the row is built by now or never.
        if (i > 2) break;
        continue;
      }
      _transcript.jumpTo((position.pixels + position.viewportDimension * 0.8).clamp(0, position.maxScrollExtent));
    }
    // The mark fades after a moment.
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (mounted && _jumpTarget == nodeId) setState(() => _jumpTarget = null);
  }

  /// Near the oldest loaded message: load another page before it.
  Future<void> _loadOlder() async {
    if (!_hasOlder || _loadingOlder) return;
    setState(() {
      _loadingOlder = true;
      _window += _page;
    });
    await _reload();
    if (mounted) setState(() => _loadingOlder = false);
  }

  void _run(Stream<TavernEvent> Function() start, {String? draft, bool rejoin = false}) {
    // A rejoin still listening for nothing must not end this turn when it closes.
    unawaited(_turn?.cancel());
    _immersive.value = false;
    _rejoining = rejoin;
    if (!rejoin) {
      setState(() {
        _error = null;
        _action = null;
        _streamNode = null;
      });
    }
    _stream.value = _nothing;
    _live.reset();
    _stopThinking();
    _thinking.value = null;
    _turn = start().listen(
      (event) {
        if (!mounted) return;
        switch (event) {
          // A rejoined turn (resumeTurn) opens with what it has so far; this
          // page's own turns start with TavernTurnStarted.
          case TavernTurnSnapshot(generationType: 'impersonate'):
            // Someone else's box: not this page's to show.
            unawaited(_turn?.cancel());
            setState(() {
              _turn = null;
              _rejoining = false;
            });
          case TavernTurnSnapshot(:final message, :final startedAt):
            setState(() {
              _rejoining = false;
              _streamNode = message?.nodeId;
            });
            if (message != null) {
              _stream.value = (text: message.text, reasoning: message.reasoning ?? '');
              _live.text = message.text;
              // Still thinking: the count goes on from when the turn began.
              if (message.text.isEmpty && (message.reasoning ?? '').isNotEmpty) {
                _thinking.value = DateTime.now().difference(startedAt).inSeconds;
                _thinkingTick = Timer.periodic(
                  const Duration(seconds: 1),
                  (_) => _thinking.value = _thinking.value! + 1,
                );
              }
            }
          // A tool the model used was taken up: read what it did.
          case TavernToolActivity():
            _refreshTools();
          case TavernTurnStarted(:final message):
            setState(() => _streamNode = message.nodeId);
            unawaited(_reload());
          case TavernTextDelta(:final nodeId, :final text):
            _adopt(nodeId);
            _stream.value = (text: _stream.value.text + text, reasoning: _stream.value.reasoning);
            _live.text = _stream.value.text;
            // The reply has begun: the thinking took what the count says.
            _stopThinking();
          case TavernReasoningDelta(:final nodeId, :final text):
            _adopt(nodeId);
            _stream.value = (text: _stream.value.text, reasoning: _stream.value.reasoning + text);
            if (_thinking.value == null && _stream.value.text.isEmpty) {
              _thinking.value = 0;
              _thinkingTick = Timer.periodic(const Duration(seconds: 1), (_) => _thinking.value = _thinking.value! + 1);
            }
          case TavernTurnDone(:final message, :final finishReason):
            _countTokens(message);
            // Cut short by the reply limit, or by the provider's filter: say
            // so over the composer, with the way on.
            final l10n = context.l10n;
            switch (finishReason) {
              case 'length':
                _finish(
                  error: l10n.tavernCutShort,
                  calm: true,
                  action: (
                    label: l10n.tavernContinueReply,
                    onPressed: () => _run(() => _tavern.continueReply(widget.chatId, message.nodeId)),
                  ),
                );
              case 'content_filter':
                _finish(
                  error: l10n.tavernFiltered,
                  calm: true,
                  action: (
                    label: l10n.tavernRegenerate,
                    onPressed: () => _run(() => _tavern.regenerate(widget.chatId, message.nodeId)),
                  ),
                );
              default:
                if (_overCost(message) case final over?) {
                  _finish(error: over.error, calm: true, action: over.action);
                } else {
                  _finish();
                }
            }
          case TavernTurnFailed(:final kind, :final detail, :final partial, :final toolFailureCode):
            if (partial == null && draft != null && _input.text.isEmpty) _input.text = draft;
            if (kind == TavernFailure.cancelled) return _finish();
            final l10n = context.l10n;
            _finish(
              error: _failureText(kind, detail, toolFailureCode),
              action: switch (kind) {
                // Trying again cannot help until the key is there.
                TavernFailure.noKey ||
                TavernFailure.badKey => (label: l10n.commonSettings, onPressed: _openKeySettings),
                // Nothing stored: the line is back in the composer, send it
                // again. Half a reply: write that reply again.
                _ => (
                  label: l10n.commonRetry,
                  onPressed: switch (partial) {
                    null when draft != null => _send,
                    final p? => () => _run(() => _tavern.regenerate(widget.chatId, p.nodeId)),
                    null => () => _run(start),
                  },
                ),
              },
            );
        }
      },
      onDone: () {
        if (!mounted || _turn == null) return;
        if (_rejoining) {
          // Nothing was running.
          setState(() {
            _turn = null;
            _rejoining = false;
          });
        } else {
          _finish();
        }
      },
    );
  }

  /// A reply left running when the page was last closed (engine T24), or a
  /// group's batch (P2): picked up as it is now.
  Future<void> _rejoin() async {
    TavernGroupChat? group;
    try {
      group = await _tavern.groupChat(widget.chatId);
    } on Object {
      group = null;
    }
    if (!mounted || _turn != null) return;
    if (group != null) {
      setState(() => _group = group);
      _runGroup(() => _tavern.resumeGroupTurn(widget.chatId), rejoin: true);
    } else {
      _run(() => _tavern.resumeTurn(widget.chatId), rejoin: true);
    }
  }

  /// A group's batch (engine P2 125): the outer events say who speaks and who
  /// follows; each member's own turn streams as a reply does, one after the
  /// other; the batch ends once, at its Finished.
  void _runGroup(Stream<TavernGroupEvent> Function() start, {String? draft, bool rejoin = false}) {
    unawaited(_turn?.cancel());
    _immersive.value = false;
    _rejoining = rejoin;
    if (!rejoin) {
      setState(() {
        _error = null;
        _action = null;
        _streamNode = null;
        _groupProgress = null;
      });
    }
    _stream.value = _nothing;
    _live.reset();
    _stopThinking();
    _thinking.value = null;
    // The round's costliest reply: what 单回合费用提醒 speaks of once it ends.
    TavernMessage? costliest;
    var most = 0.0;
    void member(TavernEvent event) {
      switch (event) {
        case TavernTurnStarted(:final message):
          _stream.value = _nothing;
          _live.reset();
          _stopThinking();
          _thinking.value = null;
          setState(() => _streamNode = message.nodeId);
          unawaited(_reload());
        case TavernTextDelta(:final nodeId, :final text):
          _adopt(nodeId);
          _stream.value = (text: _stream.value.text + text, reasoning: _stream.value.reasoning);
          _live.text = _stream.value.text;
          _stopThinking();
        case TavernReasoningDelta(:final nodeId, :final text):
          _adopt(nodeId);
          _stream.value = (text: _stream.value.text, reasoning: _stream.value.reasoning + text);
          if (_thinking.value == null && _stream.value.text.isEmpty) {
            _thinking.value = 0;
            _thinkingTick = Timer.periodic(const Duration(seconds: 1), (_) => _thinking.value = _thinking.value! + 1);
          }
        case TavernTurnDone(:final message):
          _countTokens(message);
          if (_replyCost(message) case final cost? when cost > most) {
            costliest = message;
            most = cost;
          }
          // This one has said it; the next follows.
          _stream.value = _nothing;
          _live.reset();
          _stopThinking();
          setState(() => _streamNode = null);
          unawaited(_reload());
        case TavernToolActivity():
          _refreshTools();
        default:
        // A member's failure ends the batch: its Finished says how.
      }
    }

    _turn = start().listen(
      (event) {
        if (!mounted) return;
        switch (event) {
          case TavernGroupStarted(:final progress) || TavernGroupProgressChanged(:final progress):
            setState(() {
              _rejoining = false;
              _groupProgress = progress;
            });
          case TavernGroupSnapshot(:final progress, :final message):
            setState(() {
              _rejoining = false;
              _groupProgress = progress;
              _streamNode = message?.nodeId;
            });
            if (message != null) {
              _stream.value = (text: message.text, reasoning: message.reasoning ?? '');
              _live.text = message.text;
            }
          case TavernGroupMemberEvent(:final progress, :final event):
            _groupProgress = progress;
            member(event);
          case TavernGroupFinished(:final reason, :final failure, :final detail, :final progress, :final code):
            setState(() => _groupProgress = null);
            final l10n = context.l10n;
            switch (reason) {
              case TavernGroupEndReason.completed || TavernGroupEndReason.cancelled:
                final over = switch (costliest) {
                  final reply? => _overCost(reply),
                  null => null,
                };
                if (over != null) {
                  _finish(error: over.error, calm: true, action: over.action);
                } else {
                  _finish();
                }
              case TavernGroupEndReason.noSpeakers:
                _finish(error: l10n.tavernGroupNoSpeakers, calm: true);
              case TavernGroupEndReason.failed:
                // Your line was not kept: back in the box.
                final kept = progress?.userNodeId != null;
                if (!kept && draft != null && _input.text.isEmpty) _input.text = draft;
                final kind = failure ?? TavernFailure.server;
                _finish(
                  error: _failureText(kind, detail, code),
                  action: switch (kind) {
                    TavernFailure.noKey ||
                    TavernFailure.badKey => (label: l10n.commonSettings, onPressed: _openKeySettings),
                    // Kept: the group goes on from it. Not kept: send it again.
                    _ => (
                      label: l10n.commonRetry,
                      onPressed: kept || draft == null
                          ? () => _runGroup(() => _tavern.sendGroup(widget.chatId, ''))
                          : _send,
                    ),
                  },
                );
            }
        }
      },
      onDone: () {
        if (!mounted || _turn == null) return;
        if (_rejoining) {
          setState(() {
            _turn = null;
            _rejoining = false;
          });
        } else {
          _finish();
        }
      },
    );
  }

  /// 点名 (a group): [characterId] replies next, to what is in the box or to
  /// nothing; muted or not.
  void _speak(String characterId) {
    if (_running) return;
    if (_tavern is! TavernPreview && ref.read(tavernNeedsKeyProvider)) {
      _openKeySettings();
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    final text = _input.text;
    _input.clear();
    _countMessage();
    _runGroup(() => _tavern.sendGroup(widget.chatId, text, speakerCharacterId: characterId), draft: text);
  }

  /// Anonymous usage statistics (lib/usage/usage_stats.dart): one more
  /// message the person sent here. Not in the preview.
  void _countMessage() {
    if (_tavern is! TavernPreview) ref.read(usageStatsProvider.notifier).count(UsageCount.tavern);
  }

  /// The tokens [message]'s provider reported, when it did; never estimated.
  void _countTokens(TavernMessage message) {
    if (_tavern is TavernPreview || !mounted) return;
    if (message.reportedUsage case final usage?) {
      ref.read(usageStatsProvider.notifier).tokens(usage.promptTokens, usage.completionTokens);
    }
  }

  /// 小说: into the story by the reader's own hand hides the header and the
  /// box; back toward the newest lines, or near them, shows them again. Not
  /// while a reply is written or something is being typed.
  void _immerse(ScrollNotification n) {
    if (n.metrics.pixels <= 240 || _running || _focus.hasFocus) {
      _immersive.value = false;
    } else if (n is ScrollUpdateNotification && n.dragDetails != null) {
      // The list runs newest first: scrolling into the story adds pixels.
      final delta = n.scrollDelta ?? 0;
      if (delta > 4) _immersive.value = true;
      if (delta < -4) _immersive.value = false;
    }
  }

  /// 视觉小说: paging back through older pages hides the header and the box,
  /// as reading back does in 小说; the newest page shows them again. Not
  /// while a reply is written or something is being typed.
  void _vnReadingBack(bool back) {
    _immersive.value = back && !_running && !_focus.hasFocus;
  }

  /// [reply], when what it cost (at DeepSeek's list prices) is over 酒馆设置's
  /// 单回合费用提醒: what to say over the composer, and 看看发了什么 to see what went
  /// into that turn. Null when it is off, under the line, or not priced.
  ({String error, ({String label, VoidCallback onPressed}) action})? _overCost(TavernMessage reply) {
    final line = ref.read(tavernSettingsProvider).costAlert;
    final cost = _replyCost(reply);
    if (line <= 0 || cost == null || cost <= line) return null;
    final l10n = context.l10n;
    return (
      error: l10n.tavernCostAlertNotice(tavernCostLabel(l10n, cost), 'US\$${line.toStringAsFixed(2)}'),
      action: (
        label: l10n.tavernInspectMenu,
        onPressed: () =>
            unawaited(Navigator.of(context).push(TavernInspectorPage.route(widget.chatId, nodeId: reply.nodeId))),
      ),
    );
  }

  /// What [reply] cost at DeepSeek's list prices; null when not priced.
  static double? _replyCost(TavernMessage reply) {
    final usage = reply.reportedUsage;
    final price = tavernModelPrice(usage?.model);
    return usage == null || price == null ? null : tavernReplyCost(usage, price, reply.at);
  }

  /// The reply's node, once known: the page places the reply by it.
  void _adopt(String nodeId) {
    if (_streamNode == null) setState(() => _streamNode = nodeId);
  }

  /// What the chat's turns did with tools (the dice, what to remember), read
  /// again: a turn ended, a tool was taken up, a decision was made.
  void _refreshTools() => ref.invalidate(tavernChatToolTurnsProvider(widget.chatId));

  /// 记住 / 不用 on what a reply proposed to remember: as the proposal is
  /// now (its version, its context), under a new decision id, kept before it
  /// is sent (STAGE1-APP-INTEGRATION §5.2).
  Future<void> _decide(TavernMemoryProposalSnapshot proposal, TavernMemoryDecision decision) async {
    if (proposal.workflow != 'pending_confirmation' || !proposal.eligible) return;
    // A second tap while the first is out would replace the kept decision.
    if (!_deciding.add(proposal.proposalId)) return;
    try {
      final intent = TavernMemoryIntent.of(proposal, decision, tavernNewId());
      await tavernKeepMemoryIntent(intent);
      // Left the page meanwhile: the kept decision is offered again (重试).
      if (!mounted) return;
      await _submitDecision(intent);
    } finally {
      _deciding.remove(proposal.proposalId);
    }
  }

  /// Proposals whose decision is being kept and sent.
  final _deciding = <String>{};

  /// Sends [intent] (again, unchanged, for 重试). Its record is what it is:
  /// not applied says why. Kept only while it may yet go through (the engine
  /// could not save or read back); a conflict or refusal lets it go.
  Future<void> _submitDecision(TavernMemoryIntent intent) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    try {
      final receipt = await intent.submit(_tavern);
      await tavernForgetMemoryIntent(intent.proposalId);
      if (receipt.record.outcome == 'not_applied') {
        messenger?.showBriefNotice(l10n.tavernToolMemoryNotApplied(tavernToolReason(l10n, receipt.record.reason)));
      }
    } on TavernToolException catch (e) {
      if (e.code != TavernToolErrorCode.storageFailure) await tavernForgetMemoryIntent(intent.proposalId);
      messenger?.showBriefNotice(l10n.tavernToolMemoryFailed(e.message));
    }
    if (!mounted) return;
    ref.invalidate(tavernMemoryIntentProvider(intent.proposalId));
    _refreshTools();
  }

  void _finish({String? error, bool calm = false, ({String label, VoidCallback onPressed})? action}) {
    _refreshTools();
    unawaited(_turn?.cancel());
    setState(() {
      _turn = null;
      _streamNode = null;
      _error = error;
      _calm = calm;
      _action = action;
    });
    _stream.value = _nothing;
    _live.reset();
    _stopThinking();
    unawaited(_reload());
  }

  /// What went wrong, as the player reads it. A tool's failure says which
  /// ([toolCode], STAGE1-APP-INTEGRATION §3.2); one not known here, or none,
  /// falls back to the detail as it came.
  String _failureText(TavernFailure kind, String? detail, [String? toolCode]) {
    final l10n = context.l10n;
    return switch (kind) {
      TavernFailure.toolFailure => switch (toolCode) {
        'budget_exhausted' => l10n.tavernToolFailBudget,
        'batch_limit' => l10n.tavernToolFailBatch,
        'protocol_invalid' => l10n.tavernToolFailProtocol,
        'unsupported_response_snapshot' => l10n.tavernToolFailSnapshot,
        'receipt_failure' => l10n.tavernToolFailReceipt,
        'anchor_changed' => l10n.tavernToolFailAnchor,
        _ => detail == null ? l10n.tavernToolFail : l10n.tavernToolFailDetail(detail),
      },
      TavernFailure.noKey => l10n.tavernErrorNoKey,
      TavernFailure.badKey => l10n.tavernErrorBadKey,
      TavernFailure.busy => l10n.tavernErrorBusy,
      TavernFailure.network => l10n.tavernErrorNetwork,
      TavernFailure.contextTooLong => l10n.tavernErrorTooLong,
      TavernFailure.insufficientBalance => l10n.tavernErrorBalance,
      TavernFailure.invalidParameters =>
        detail == null ? l10n.tavernErrorParameters : l10n.tavernErrorParametersDetail(detail),
      _ => detail == null ? l10n.commonFailedTryAgain : l10n.tavernErrorDetail(detail),
    };
  }

  void _send() {
    if (_running) return;
    _quietTavern();
    // A slash command (/sys, /send: no model, so no key needed).
    final slash = tavernSlashOf(_input.text);
    if (slash case (command: TavernSlash.narrate || TavernSlash.sendOnly, :final rest)) {
      unawaited(_sendAside(rest, narrate: slash.command == TavernSlash.narrate));
      return;
    }
    // No key yet: the line would only fail. Keep it, and go and add one.
    if (_tavern is! TavernPreview && ref.read(tavernNeedsKeyProvider)) {
      _openKeySettings();
      return;
    }
    if (slash != null) {
      _slash(slash.command);
      return;
    }
    final text = _input.text;
    _input.clear();
    _countMessage();
    // A group: the line goes to all of them, who answer in turn.
    if (_groupChat) {
      _runGroup(() => _tavern.sendGroup(widget.chatId, text), draft: text);
      return;
    }
    _run(() => _afterMvu(() => _tavern.send(widget.chatId, text)), draft: text);
  }

  /// /continue, /regen, /imp: as the message menu and 帮我写 do them, on the
  /// latest reply.
  void _slash(TavernSlash command) {
    if (command == TavernSlash.impersonate) {
      _impersonate();
      return;
    }
    final last = _messages?.where((m) => m.role == TavernRole.character).lastOrNull;
    if (last == null) {
      ScaffoldMessenger.maybeOf(context)?.showBriefNotice(context.l10n.tavernSlashNoReply);
      return;
    }
    _input.clear();
    switch (command) {
      case TavernSlash.continueReply:
        _run(() => _tavern.continueReply(widget.chatId, last.nodeId));
      case TavernSlash.regenerate:
        _run(() => _tavern.regenerate(widget.chatId, last.nodeId));
      case TavernSlash.narrate || TavernSlash.sendOnly || TavernSlash.impersonate:
        break;
    }
  }

  void _stop() => _tavern.stop(widget.chatId);

  /// One of the director's suggestions, into the box to change and send (or
  /// not); never sent for you.
  void _suggest(String text) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _scaffold.currentState?.closeEndDrawer();
    _focus.requestFocus();
  }

  /// A command picked from the row: in the box, ready for its words (or to send).
  void _pickSlash(TavernSlash c) {
    final text = c.takesText ? '/${c.word} ' : '/${c.word}';
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
  }

  /// The line in the box, sent another way (engine T16): into the story
  /// with no reply, or as narration.
  Future<void> _sendOptions() async {
    final l10n = context.l10n;
    final narrate = await showAppSheet<bool>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: SheetGroup(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          children: [
            SettingsTile(
              key: const ValueKey('tavern-send-only'),
              icon: AppIcons.send,
              tinted: false,
              title: l10n.tavernSendOnly,
              subtitle: l10n.tavernSendOnlySubtitle,
              onTap: () => Navigator.of(sheet).pop(false),
            ),
            SettingsTile(
              key: const ValueKey('tavern-narrate'),
              icon: AppIcons.quote,
              tinted: false,
              title: l10n.tavernNarrate,
              subtitle: l10n.tavernNarrateSubtitle,
              onTap: () => Navigator.of(sheet).pop(true),
            ),
          ],
        ),
      ),
    );
    if (narrate == null || !mounted || _running) return;
    await _sendAside(_input.text, narrate: narrate);
  }

  /// [text] into the story with no reply: as narration, or as yours. On a
  /// failure it goes back in the box.
  Future<void> _sendAside(String text, {required bool narrate}) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    _input.clear();
    try {
      if (narrate) {
        await _tavern.narrate(widget.chatId, text);
      } else {
        await _tavern.sendOnly(widget.chatId, text);
      }
    } on Object {
      // Back in the box, to try again.
      if (_input.text.isEmpty) _input.text = text;
      messenger.showBriefNotice(l10n.tavernSendFailed);
      return;
    }
    unawaited(_reload());
  }

  /// A quick reply sends as it is; on failure it waits in the box.
  /// A card script's button: pressed in the page, where the script listens
  /// for it (eventOn(getButtonEvent(name))).
  void _pressScriptButton(String scriptId, String name) {
    unawaited(HapticFeedback.selectionClick());
    final deliver = _canvasCalls.deliver;
    if (deliver != null) unawaited(deliver({'kind': 'button', 'scriptId': scriptId, 'name': name}));
  }

  void _sendQuick(String text) {
    if (_running) return;
    unawaited(HapticFeedback.selectionClick());
    _countMessage();
    if (_groupChat) {
      _runGroup(() => _tavern.sendGroup(widget.chatId, text), draft: text);
      return;
    }
    _run(() => _afterMvu(() => _tavern.send(widget.chatId, text)), draft: text);
  }

  /// Long-press: the quick reply goes into the box to change first.
  /// 全部: every quick reply whole, as the row can't show them; a tap sends
  /// one, the pencil puts it in the box, and the last row manages them.
  Future<void> _allQuick() async {
    final l10n = context.l10n;
    final navigator = Navigator.of(context);
    final replies = ref.read(tavernQuickRepliesProvider);
    final picked = await showAppSheet<(String, bool)>(
      context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: SheetGroup(
            title: l10n.tavernQuickReplies,
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            children: [
              for (final (i, reply) in replies.indexed)
                SettingsTile(
                  key: ValueKey('tavern-qr-all-$i'),
                  tinted: false,
                  title: reply.trim(),
                  chevron: false,
                  trailing: IconButton(
                    key: ValueKey('tavern-qr-all-edit-$i'),
                    tooltip: l10n.commonEdit,
                    icon: const Icon(AppIcons.edit, size: 18),
                    onPressed: () => Navigator.of(sheet).pop((reply, false)),
                  ),
                  onTap: () => Navigator.of(sheet).pop((reply, true)),
                ),
              SettingsTile(
                key: const ValueKey('tavern-qr-manage'),
                icon: AppIcons.configure,
                tinted: false,
                title: l10n.tavernQuickRepliesManage,
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(navigator.push(TavernQuickRepliesPage.route()));
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final (text, send) = picked;
    send ? _sendQuick(text) : _editQuick(text);
  }

  void _editQuick(String text) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
  }

  /// 接着写: the newest reply goes on from where it stopped.
  void _continueLast() {
    final last = _messages?.lastOrNull;
    if (_running || last == null || last.role != TavernRole.character) return;
    unawaited(HapticFeedback.selectionClick());
    _run(() => _tavern.continueReply(widget.chatId, last.nodeId));
  }

  /// 掷骰: what came up joins whatever is in the box, on a line of its own.
  Future<void> _dice() async {
    final line = await showTavernDice(context, chatId: widget.chatId);
    if (line == null || !mounted) return;
    final before = _input.text.trimRight();
    final text = before.isEmpty ? line : '$before\n$line';
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
  }

  /// 帮我写: the model writes your next line into the composer. Nothing is
  /// sent or stored; edit it, then send. Stop keeps what has arrived.
  void _impersonate() {
    if (_running) return;
    unawaited(HapticFeedback.selectionClick());
    _setDraft('');
    setState(() {
      _error = null;
      _action = null;
    });
    _drafting = true;
    _turn = _tavern
        .impersonate(widget.chatId)
        .listen(
          (event) {
            if (!mounted) return;
            switch (event) {
              case TavernTextDelta(:final text):
                _setDraft(_input.text + text);
              case TavernTurnDone(:final message):
                _countTokens(message);
                _setDraft(message.text);
                _endDraft();
              case TavernTurnFailed(:final kind, :final detail):
                if (kind == TavernFailure.cancelled) return _endDraft();
                _endDraft(failure: (kind, detail));
              case TavernTurnSnapshot() || TavernTurnStarted() || TavernReasoningDelta() || TavernToolActivity():
                break;
            }
          },
          onDone: () {
            if (mounted && _running) _endDraft();
          },
        );
    setState(() {});
  }

  void _setDraft(String text) => _input.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );

  void _endDraft({(TavernFailure, String?)? failure}) {
    unawaited(_turn?.cancel());
    _drafting = false;
    final l10n = context.l10n;
    setState(() {
      _turn = null;
      _calm = false;
      _error = switch (failure) {
        (final kind, final detail)? => _failureText(kind, detail),
        null => null,
      };
      _action = switch (failure?.$1) {
        null => null,
        TavernFailure.noKey || TavernFailure.badKey => (label: l10n.commonSettings, onPressed: _openKeySettings),
        _ => (label: l10n.commonRetry, onPressed: _impersonate),
      };
    });
    if (failure == null) _focus.requestFocus();
  }

  /// Where the DeepSeek key is set (as 酒馆设置 opens it); the line waits in
  /// the composer.
  /// Where the key in use is set: the app's DeepSeek key, or the channel's own.
  void _openKeySettings() => unawaited(
    Navigator.of(context).push(switch (ref.read(tavernSettingsProvider).activeChannel) {
      final channel? => TavernChannelEditPage.route(channel),
      null => MaterialPageRoute<void>(builder: (_) => const ApiKeyPage(onboarding: false)),
    }),
  );

  Future<void> _sibling(TavernMessage message, int delta) async {
    if (_running) return;
    final index = message.siblingIndex + delta;
    if (index >= message.siblingCount) {
      _run(() => _tavern.regenerate(widget.chatId, message.nodeId));
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    final messages = _messages ?? const <TavernMessage>[];
    final later = messages.indexWhere((m) => m.nodeId == message.nodeId) < messages.length - 1;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    await _tavern.selectSibling(widget.chatId, message.nodeId, index);
    // An earlier message: everything after it is now another branch's.
    if (!later || !mounted) return;
    messenger.showUndoNotice(
      l10n.tavernSwitchedBranch,
      undoLabel: l10n.tavernUndo,
      window: tavernUndoWindow,
      onUndo: () => unawaited(_tavern.selectSibling(widget.chatId, message.nodeId, message.siblingIndex)),
    );
  }

  Future<void> _menu(TavernMessage message, {required bool last}) async {
    final l10n = context.l10n;
    final character = message.role == TavernRole.character;
    final marked = ref.read(tavernBookmarksProvider(widget.chatId).notifier).has(message.nodeId);
    final readId = 'tavern:${message.nodeId}';
    final reading = ref.read(readAloudProvider).id == readId;
    final action = await showAppSheet<_MessageAction>(
      context,
      // As tall as its rows: eight of them pass the default cap on a phone.
      isScrollControlled: true,
      builder: (sheet) {
        Widget row(_MessageAction action, IconData icon, String title, {bool danger = false}) => SettingsTile(
          key: ValueKey('tavern-menu-${action.name}'),
          icon: icon,
          tinted: false,
          danger: danger,
          title: title,
          onTap: () => Navigator.of(sheet).pop(action),
        );
        // Up to seven rows: scrolls on a short screen instead of overflowing.
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: SheetGroup(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              children: [
                row(_MessageAction.copy, AppIcons.copy, l10n.commonCopy),
                if (character)
                  row(
                    _MessageAction.readAloud,
                    reading ? AppIcons.stop : AppIcons.readAloud,
                    reading ? l10n.speechReadAloudStop : l10n.speechReadAloud,
                  ),
                row(_MessageAction.edit, AppIcons.edit, l10n.commonEdit),
                if (marked)
                  row(_MessageAction.bookmark, AppIcons.bookmarkActive, l10n.tavernBookmarkRemove)
                else
                  row(_MessageAction.bookmark, AppIcons.bookmark, l10n.tavernBookmarkAdd),
                if (character) row(_MessageAction.regenerate, AppIcons.regenerate, l10n.tavernRegenerate),
                if (character && last)
                  row(_MessageAction.continueReply, AppIcons.continueReply, l10n.tavernContinueReply),
                if (character) row(_MessageAction.inspect, AppIcons.code, l10n.tavernInspectMenu),
                // Back to here, what came after kept as a branch (engine T16 selectNode).
                if (_messages?.lastOrNull?.nodeId != message.nodeId)
                  row(_MessageAction.branchHere, AppIcons.fork, l10n.tavernBranchHere),
                if (message.hidden)
                  row(_MessageAction.hide, AppIcons.showSecret, l10n.tavernUnhide)
                else
                  row(_MessageAction.hide, AppIcons.hideSecret, l10n.tavernHide),
                row(_MessageAction.deleteOne, AppIcons.remove, l10n.tavernDeleteOne, danger: true),
                row(_MessageAction.delete, AppIcons.delete, l10n.tavernDeleteFrom, danger: true),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: message.text));
      case _MessageAction.readAloud:
        // What the bubble shows (through the display regex), not what is stored.
        final ask = ++_readAsk;
        final shown = await _tavern.displayText(widget.chatId, nodeId: message.nodeId, text: message.text);
        if (!mounted || ask != _readAsk) return;
        readAloudReply(context, readId, tavernStripMarkers(shown.superseded ? message.text : shown.text));
      case _MessageAction.edit:
        await _edit(message);
      case _MessageAction.bookmark:
        final messenger = ScaffoldMessenger.maybeOf(context);
        final now = await ref.read(tavernBookmarksProvider(widget.chatId).notifier).toggle(message);
        messenger?.showBriefNotice(now ? l10n.tavernBookmarkAdded : l10n.tavernBookmarkRemoved);
      case _MessageAction.regenerate:
        if (!_running) _run(() => _tavern.regenerate(widget.chatId, message.nodeId));
      case _MessageAction.continueReply:
        if (!_running) _run(() => _tavern.continueReply(widget.chatId, message.nodeId));
      case _MessageAction.inspect:
        await Navigator.of(context).push(TavernInspectorPage.route(widget.chatId, nodeId: message.nodeId));
      case _MessageAction.branchHere:
        // The story goes on from here; what came after stays, a branch to
        // find in 分支. 撤销 picks the old end again.
        if (_running) return;
        final messenger = ScaffoldMessenger.of(context);
        final end = _messages?.lastOrNull?.nodeId;
        try {
          await _tavern.selectNode(widget.chatId, message.nodeId);
        } on Object {
          messenger.showBriefNotice(l10n.tavernBranchHereFailed);
          return;
        }
        if (!mounted || end == null) return;
        messenger.showUndoNotice(
          l10n.tavernBranchedHere,
          undoLabel: l10n.tavernUndo,
          window: tavernUndoWindow,
          onUndo: () => unawaited(_tavern.selectNode(widget.chatId, end).catchError((Object _) {})),
        );
      case _MessageAction.hide:
        if (!_running) await _tavern.setHidden(widget.chatId, message.nodeId, !message.hidden);
      case _MessageAction.deleteOne:
        // Only this one, for good (engine T16): what came after it stays,
        // joined to the message before. No undo, so ask first.
        if (_running) return;
        final l10n = context.l10n;
        final ok = await confirmTavernDelete(
          context,
          title: l10n.tavernDeleteOneTitle,
          message: l10n.tavernDeleteOneMessage,
        );
        if (ok && mounted && !_running) {
          await _tavern.deleteMessage(widget.chatId, message.nodeId);
        }
      case _MessageAction.delete:
        // Gone at once, with 撤销 for a while (engine T24: hidden until the
        // library is next opened); [tavernDeleteAskFrom] or more ask first.
        if (_running) return;
        final at = _messages?.indexWhere((m) => m.nodeId == message.nodeId) ?? -1;
        final count = at < 0 ? 1 : _messages!.length - at;
        final l10n = context.l10n;
        final messenger = ScaffoldMessenger.of(context);
        if (count >= tavernDeleteAskFrom) {
          final ok = await confirmTavernDelete(
            context,
            title: l10n.tavernDeleteFromTitle(count),
            message: l10n.tavernDeleteFromUndoable,
          );
          if (!ok || !mounted || _running) return;
        }
        final token = await _tavern.deleteFrom(widget.chatId, message.nodeId);
        messenger.showUndoNotice(
          l10n.tavernDeletedCount(count),
          undoLabel: l10n.tavernUndo,
          window: tavernUndoWindow,
          onUndo: () => unawaited(_undoDelete(token, messenger, l10n.tavernUndoFailed)),
        );
    }
  }

  Future<void> _undoDelete(String token, ScaffoldMessengerState messenger, String failed) async {
    // False: something since took its place, or the library was reopened.
    if (!await _tavern.undoDeleteFrom(widget.chatId, token)) messenger.showBriefNotice(failed);
  }

  /// The stage plays [page]: thinking while a reply starts, then the cues.
  void _cue(TavernPage page) {
    _staged = page;
    if (page.streaming) {
      _stage.command('mood', {'mood': 'thinking'});
      return;
    }
    for (final (type, args) in tavernStageCues(
      you: page.message.role == TavernRole.user,
      text: page.text,
      marker: page.marker,
    )) {
      _stage.command(type, args);
    }
  }

  late final _stageEvents = CompanionStageEvents(
    onReady: () {
      if (_staged case final page?) _cue(page);
    },
    onFailed: (why) {
      debugPrint('tavern: Live2D stage failed: $why');
      if (mounted) setState(() => _stageFailed = true);
    },
    onTouch: (_, _) {},
    onWake: () {},
    onMood: (_) {},
    onObject: (_) {},
    onActivity: (_) {},
  );

  /// A whole page for the message (long replies need room); saves only a change.
  Future<void> _edit(TavernMessage message) async {
    final speaker = message.role == TavernRole.user ? context.l10n.tavernYou : message.speaker;
    final text = await Navigator.of(context).push(TavernMessageEditPage.route(speaker: speaker, text: message.text));
    if (text != null && text != message.text && mounted) await _tavern.edit(widget.chatId, message.nodeId, text);
  }

  @override
  Widget build(BuildContext context) {
    // A message to go to (舞台 › 在对话里搜索 › 到对话里这一条).
    ref.listen(tavernJumpProvider(widget.chatId), (_, nodeId) {
      if (nodeId != null) unawaited(_jumpTo(nodeId));
    });
    final l10n = context.l10n;
    // Only what this page needs from the chat list, so the page is not built
    // again each time any chat's summary changes (every reply, every chat).
    final (characterId, kind) = ref.watch(
      tavernChatsProvider(null).select((chats) {
        final summary = chats.value?.where((c) => c.id == widget.chatId).firstOrNull;
        return (summary?.characterId, summary?.kind);
      }),
    );
    // A group by its summary too, before its own details are in.
    _groupChat = _group != null || kind == TavernChatKind.group;
    final characters = ref.watch(tavernCharactersProvider).value;
    final character = characters?.where((c) => c.id == characterId).firstOrNull;
    // A group goes by its own title; its members by theirs.
    final group = _group;
    final names = {for (final c in characters ?? const <TavernCharacter>[]) c.id: c.name};
    final name = group?.title ?? character?.name ?? l10n.tavernTitle;
    // Who writes the reply now: in a group, the member speaking, not the
    // group's title; else the chat's character.
    final speaking = group == null ? null : _groupProgress?.speakerCharacterId;
    final writer = names[speaking] ?? name;
    final preview = _tavern is TavernPreview;
    // The card's own look (酒馆设置 can turn it off): a layout to start in,
    // a picture, an accent and name colours for the story.
    final cardTheme = ref.watch(tavernCardThemeProvider(characterId));
    final layout =
        ref.watch(tavernChatLayoutProvider(widget.chatId)) ??
        cardTheme?.layout ??
        ref.watch(tavernSettingsProvider.select((s) => s.layout));
    final novel = layout == TavernLayout.novel;
    final indent = novel && ref.watch(tavernSettingsProvider.select((s) => s.novelIndent));
    final showUsage = ref.watch(tavernSettingsProvider.select((s) => s.showUsage));
    // What each reply's turn did with tools, by reply (the engine's record).
    final toolTurns = ref.watch(tavernChatToolTurnsProvider(widget.chatId)).value ?? const {};
    final messages = _messages;
    final (String status, StatusTone tone) = switch (()) {
      // A group: who speaks now, and who follows.
      _ when _running && _groupProgress?.speakerCharacterId != null => (
        [
          l10n.tavernGroupSpeaking(names[_groupProgress!.speakerCharacterId] ?? ''),
          if (_groupProgress!.remainingCharacterIds.isNotEmpty)
            l10n.tavernGroupThen([for (final id in _groupProgress!.remainingCharacterIds) names[id] ?? id].join('、')),
        ].join(' · '),
        StatusTone.busy,
      ),
      _ when _running => (l10n.tavernReplying, StatusTone.busy),
      _ when preview => (l10n.tavernPreviewStatus, StatusTone.warn),
      // What the card pins (好感 8 · 地点 旅店) in place of 「就绪」.
      _ when _pinned != null => (_pinned!, StatusTone.ok),
      _ => (l10n.tavernReady, StatusTone.ok),
    };
    final topInset = BotChatHeader.heightOf(context);
    final lastCharacter = messages?.lastWhere((m) => m.role == TavernRole.character, orElse: () => _none).nodeId;

    final shown = messages ?? const <TavernMessage>[];
    final marked = {for (final b in ref.watch(tavernBookmarksProvider(widget.chatId))) b.nodeId};
    final rows = <Widget>[
      for (final (i, m) in shown.indexed) ...[
        // 小说: a long pause in the story starts a chapter, marked with when.
        if (novel && i > 0 && m.at.difference(shown[i - 1].at) >= tavernChapterGap)
          TavernChapterBreak(key: ValueKey('tavern-chapter-${m.nodeId}'), at: m.at),
        if (m.nodeId == _streamNode)
          _StreamingReply(
            key: ValueKey('stream-${m.nodeId}'),
            stream: _stream,
            live: _live,
            thinking: _thinking,
            indent: indent,
            speaker: group != null && !novel ? m.speaker : null,
            lead: name,
          )
        else
          _MessageRow(
            chatId: widget.chatId,
            key: ValueKey(m.nodeId),
            message: m,
            last: m.nodeId == lastCharacter,
            busy: _running,
            onMenu: () => unawaited(_menu(m, last: m.nodeId == lastCharacter)),
            onSibling: (delta) => unawaited(_sibling(m, delta)),
            novel: novel,
            indent: indent,
            showUsage: showUsage,
            lead: name,
            bookmarked: marked.contains(m.nodeId),
            showName: group != null,
            tools: toolTurns[m.nodeId] ?? const [],
            onDecide: _decide,
            onRetryDecision: _submitDecision,
          ),
      ],
      if (_running && (_streamNode == null || !(messages?.any((m) => m.nodeId == _streamNode) ?? false)))
        _StreamingReply(
          key: const ValueKey('stream-pending'),
          stream: _stream,
          live: _live,
          thinking: _thinking,
          indent: indent,
          speaker: group != null && !novel ? writer : null,
          lead: name,
        ),
    ];

    // Read here, not in the 视觉小说 builder below, which reruns on every
    // piece of the reply.
    // A group's stage shows whoever speaks, in their own picture: no one
    // member's Live2D model stands for all of them.
    final live2d = layout != TavernLayout.visualNovel || characterId == null || _stageFailed || group != null
        ? null
        : ref.watch(tavernLive2dProvider(characterId)).value;
    final revealRate = ref.watch(tavernSettingsProvider.select((s) => s.textSpeed.charactersPerSecond));
    // The character's own way to show the card (角色页 › 配置), else 酒馆设置's;
    // a group follows the settings.
    final render = characterId == null || _groupChat ? null : ref.watch(tavernCharacterRenderProvider(characterId));
    // 整页画布 (a trial, 酒馆设置): the story in one web page; not for 视觉小说.
    final canvas =
        layout != TavernLayout.visualNovel &&
        (render == null ? ref.watch(tavernSettingsProvider.select((s) => s.canvas)) : render == TavernRender.canvas);
    final islands = render == null
        ? ref.watch(tavernSettingsProvider.select((s) => s.islands))
        : render != TavernRender.text;
    _canvasOn = canvas;
    _canvasSpeaker = name;
    _canvasNames = names;
    _canvasCharacter = _groupChat ? null : characterId;
    if (canvas) _feedCanvas();
    // A card that uses MVU: its variables kept by the engine in this chat,
    // whichever way the story is shown.
    if (!_mvuAsked && !_groupChat && characterId != null) {
      final card = ref.watch(tavernCardDataProvider(characterId));
      if (card.hasValue || card.hasError) {
        _mvuAsked = true;
        if (tavernUsesMvu(card.value)) _mvuOn = _turnOnMvu();
      }
    }
    // The buttons the card's own scripts show: only where those scripts run
    // (the canvas, scripts on, one character).
    final scriptCharacter = _canvasCharacter;
    // A script that changed its buttons (replaceScriptButtons…) shows those.
    final live = _calls?.liveButtons.value ?? const <String, List<String>>{};
    final scriptButtons =
        canvas && scriptCharacter != null && !ref.watch(tavernSettingsProvider.select((s) => s.islandNoScripts))
        ? [
            for (final s in ref.watch(tavernCardScriptsProvider(scriptCharacter)).value ?? const <TavernCardScript>[])
              for (final b in live[s.id] ?? s.buttons) (s.id, b),
          ]
        : const <(String, String)>[];
    // The card's own scripts, where they wait on 整页画布 being on (off, and
    // not 视觉小说, which has no canvas): said over the composer with the way
    // to turn it on, until put away for this card. Not where the player chose
    // 不运行卡的脚本, nor for a group, whose scripts do not run.
    final hintCharacter = !canvas && layout != TavernLayout.visualNovel && !_groupChat ? characterId : null;
    final scriptsWaiting =
        hintCharacter != null &&
            !ref.watch(tavernSettingsProvider.select((s) => s.islandNoScripts)) &&
            ref.watch(tavernScriptsHintOffProvider(hintCharacter)).value == false
        ? (ref.watch(tavernCardScriptsProvider(hintCharacter)).value ?? const <TavernCardScript>[]).length
        : 0;
    // The pages and the canvas read each message as shown, through the
    // display regex; the bubble and novel rows ask for their own.
    final shownText = layout == TavernLayout.visualNovel || canvas
        ? {
            for (final m in messages ?? const <TavernMessage>[])
              m.nodeId: ref.watch(tavernShownTextProvider((widget.chatId, m.nodeId, m.text))).value ?? m.text,
          }
        : const <String, String>{};

    final cardPicture = cardTheme?.background;
    final scene =
        ref.watch(tavernChatBackgroundProvider(widget.chatId)) ??
        (cardPicture == null ? null : ref.watch(tavernCardBackgroundProvider(cardPicture)).value);
    final beside = MediaQuery.sizeOf(context).width >= _stageBesideFrom;
    TavernStagePanel stage({double topInset = 0}) => TavernStagePanel(
      chatId: widget.chatId,
      turn: messages?.lastOrNull?.nodeId,
      topInset: topInset,
      characterId: characterId,
      name: name,
      busy: _running,
      onSuggest: _suggest,
      onStateChanged: () => unawaited(_readPinned()),
    );
    return _IslandsScope(
      islands: islands,
      child: BotChatFrame(
        // The chat's picture, when it has one; the page's gradient otherwise.
        backdrop: (child) => WallpaperBackdrop.scene(picture: scene, child: child),
        scaffoldKey: _scaffold,
        endDrawer: beside
            ? null
            : Drawer(
                key: const ValueKey('tavern-stage-drawer'),
                width: (MediaQuery.sizeOf(context).width * 0.88).clamp(0, 380),
                backgroundColor: Colors.transparent,
                child: AppBackdrop(glow: false, child: SafeArea(child: stage())),
              ),
        header: _Chrome(
          key: const ValueKey('tavern-chrome-top'),
          hidden: _immersive,
          top: true,
          child: BotChatHeader(
            face: ClipOval(
              child: TavernPortrait(name: name, path: character?.avatarPath, radius: 0, initialSize: 16),
            ),
            title: name,
            status: status,
            tone: tone,
            scrolledUnder: _scrolled,
            // The title is the character's: its page; a group's, its settings.
            // The chat's own things are in 舞台 › 本局.
            onDetails: () {
              if (group != null) {
                unawaited(Navigator.of(context).push(TavernGroupPage.route(widget.chatId)));
              } else if (characterId != null) {
                unawaited(Navigator.of(context).push(TavernCharacterPage.route(characterId)));
              }
            },
            // 舞台 in place of ⓘ (the title opens the quick look); beside the story
            // on a wide screen, it needs no key.
            action: beside ? null : (AppIcons.sidebar, l10n.tavernStage, () => _scaffold.currentState?.openEndDrawer()),
          ),
        ),
        // The story under 酒馆设置's text size and spacing.
        body: _beside(
          beside ? stage(topInset: topInset) : null,
          TavernReading(
            accent: cardTheme?.accent,
            names: cardTheme?.names ?? const {},
            bodyFont: switch (cardTheme?.bodyFont) {
              final String path => ref.watch(tavernCardFontProvider(path)).value,
              null => null,
            },
            nameFont: switch (cardTheme?.nameFont) {
              final String path => ref.watch(tavernCardFontProvider(path)).value,
              null => null,
            },
            child: layout == TavernLayout.visualNovel
                ? ListenableBuilder(
                    listenable: _live,
                    builder: (context, _) => TavernVisualNovelView(
                      pages: [
                        ...tavernPages(
                          messages ?? const [],
                          streamNode: _streamNode,
                          streamText: _live.shown,
                          shown: (m) => shownText[m.nodeId] ?? m.text,
                        ),
                        if (_running &&
                            _live.shown.isNotEmpty &&
                            !(messages?.any((m) => m.nodeId == _streamNode) ?? false))
                          TavernPage(
                            TavernMessage(
                              nodeId: _streamNode ?? '',
                              role: TavernRole.character,
                              speaker: writer,
                              speakerCharacterId: speaking,
                              text: '',
                              at: DateTime(0),
                            ),
                            _live.shown,
                            streaming: true,
                          ),
                      ],
                      name: name,
                      avatarPath: character?.avatarPath,
                      sprites: tavernSprites(character?.assets),
                      castFor: group == null
                          ? null
                          : (id) => switch (characters?.where((c) => c.id == id).firstOrNull) {
                              final c? => (name: c.name, avatarPath: c.avatarPath, sprites: tavernSprites(c.assets)),
                              null => null,
                            },
                      stage: switch (live2d) {
                        final store? => CompanionStage(
                          key: ValueKey(store.root.path),
                          store: store,
                          controller: _stage,
                          events: _stageEvents,
                          bare: true,
                        ),
                        null => null,
                      },
                      onPage: _cue,
                      onReadingBack: _vnReadingBack,
                      revealRate: revealRate,
                      topInset: topInset,
                      onMenu: (m) => unawaited(_menu(m, last: m.nodeId == lastCharacter)),
                      footer: (m, lastPage) =>
                          lastPage &&
                              m.role == TavernRole.character &&
                              (m.nodeId == lastCharacter || m.siblingCount > 1)
                          ? _Alternatives(
                              message: m,
                              last: m.nodeId == lastCharacter,
                              busy: _running,
                              onSibling: (d) => unawaited(_sibling(m, d)),
                            )
                          : null,
                    ),
                  )
                : canvas
                ? ref.watch(tavernCanvasBuilderProvider)(
                    entries: [
                      for (final (i, m) in (messages ?? const <TavernMessage>[]).indexed)
                        if (!(_running && m.nodeId == _streamNode))
                          TavernCanvasEntry(
                            mesid: i,
                            nodeId: m.nodeId,
                            name: tavernSpeaker(context, m),
                            isUser: m.role == TavernRole.user,
                            isSystem: m.role == TavernRole.narrator || m.role == TavernRole.system,
                            html: tavernStoryHtml(tavernStripMarkers(shownText[m.nodeId] ?? m.text)),
                          ),
                    ],
                    streaming: _canvasStream,
                    onMenu: (node) {
                      final m = messages?.where((m) => m.nodeId == node).firstOrNull;
                      if (m != null) unawaited(_menu(m, last: m.nodeId == lastCharacter));
                    },
                    calls: _canvasCalls,
                  )
                // A reply growing (or older messages arriving) lengthens the
                // list without scrolling it: that is a metrics change, not a
                // scroll, and the header has to hear of it too, or the story
                // runs up under it unshaded.
                : NotificationListener<Notification>(
                    onNotification: (n) {
                      final metrics = switch (n) {
                        ScrollNotification(:final metrics) || ScrollMetricsNotification(:final metrics) => metrics,
                        _ => null,
                      };
                      if (metrics != null && metrics.axis == Axis.vertical) {
                        _scrolled.value = ((metrics.maxScrollExtent - metrics.pixels) / 24).clamp(0.0, 1.0);
                        _readingBack.value = metrics.pixels > 240;
                        if (n is ScrollNotification) {
                          if (novel) _immerse(n);
                          // The list runs newest first: what is left above is
                          // older. Only a scroll back asks for more.
                          if (metrics.extentAfter < 600) unawaited(_loadOlder());
                        }
                      }
                      return false;
                    },
                    child: GestureDetector(
                      // A tap on the story brings the header and the box back.
                      behavior: HitTestBehavior.translucent,
                      onTap: () => _immersive.value = false,
                      child: ListView(
                        key: const ValueKey('tavern-transcript'),
                        controller: _transcript,
                        reverse: true,
                        padding: EdgeInsets.fromLTRB(16, 12, 16, topInset + 8),
                        children: [
                          // Keyed by message: a new one below keeps each row's
                          // state with its message, not with its place.
                          for (final row in rows.reversed)
                            Padding(
                              key: row.key,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              // The message gone to, marked for a moment.
                              child: _jumpTarget != null && row.key == ValueKey<String>(_jumpTarget!)
                                  ? _JumpMark(key: _jumpKey, child: row)
                                  : row,
                            ),
                          if (_hasOlder)
                            const Padding(
                              key: ValueKey('tavern-older'),
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(child: QuietSpinner()),
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
        bottom: [
          _Chrome(
            key: const ValueKey('tavern-chrome-bottom'),
            hidden: _immersive,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // No key yet: say so before the first line, not after it fails.
                if (!preview && _error == null && ref.watch(tavernNeedsKeyProvider))
                  _KeyMissing(onAdd: _openKeySettings),
                // 视觉小说 and the canvas draw no message rows: the newest
                // reply's dice and what it asks to remember sit here instead.
                if ((layout == TavernLayout.visualNovel || canvas) && !_running)
                  if (_toolStrips(
                        lastCharacter ?? '',
                        toolTurns[lastCharacter] ?? const [],
                        onDecide: _decide,
                        onRetry: _submitDecision,
                      )
                      case final strips?)
                    // At most a third of the screen: the composer stays in view.
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height / 3),
                        child: SingleChildScrollView(child: strips),
                      ),
                    ),
                if (_error == null && scriptsWaiting > 0 && hintCharacter != null)
                  Padding(
                    key: const ValueKey('tavern-scripts-hint'),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _Notice(
                      message: l10n.tavernCardScriptsHint(scriptsWaiting),
                      action: (
                        label: l10n.tavernCardScriptsHintAction,
                        // For this card: its chats on the canvas, the rest as they were.
                        onPressed: () => unawaited(
                          ref.read(tavernCharacterRenderProvider(hintCharacter).notifier).set(TavernRender.canvas),
                        ),
                      ),
                      onDismiss: () => unawaited(
                        tavernPutScriptsHintAway(hintCharacter)
                            .then((_) => ref.invalidate(tavernScriptsHintOffProvider(hintCharacter))),
                      ),
                    ),
                  ),
                _ErrorSlot(
                  error: _error,
                  calm: _calm,
                  action: _action,
                  onDismiss: () => setState(() {
                    _error = null;
                    _action = null;
                  }),
                ),
                ListenableBuilder(
                  listenable: Listenable.merge([_readingBack, _focus, _input]),
                  builder: (context, _) => Composer(
                    hardwareEnterSends: ref.watch(settingsProvider.select((s) => s.hardwareEnterSends)),
                    // Nothing written: the character speaks next (engine send with no line).
                    sendWhenEmpty: messages != null && messages.isNotEmpty,
                    emptySendLabel: group != null ? l10n.tavernGroupSpeakNext : l10n.tavernSpeakNext(name),
                    controller: _input,
                    focusNode: _focus,
                    connected: messages != null,
                    running: _running,
                    onSend: _send,
                    // Long-pressing send, as the key beside it: the line another way.
                    onSendOptions: _input.text.isEmpty ? null : () => unawaited(_sendOptions()),
                    onStop: _stop,
                    voice: _voice,
                    placeholder: !preview && ref.watch(tavernNeedsKeyProvider)
                        ? l10n.tavernComposerNoKey
                        : l10n.tavernComposerHint(name),
                    leading: TavernPersonaKey(chatId: widget.chatId, enabled: !_running),
                    tray: !_running && messages != null && _input.text.trimLeft().startsWith('/')
                        // Typing a command: the commands there are.
                        ? _SlashRow(onPick: _pickSlash)
                        : !_running && messages != null && (!_readingBack.value || _focus.hasFocus)
                        ? _QuickReplyRow(
                            members: [
                              for (final m in group?.members ?? const <TavernGroupMember>[])
                                if (names[m.characterId] case final n?) (m.characterId, n),
                            ],
                            onSpeak: _speak,
                            directed: _directed,
                            onDirected: _suggest,
                            onDirectedSend: _sendQuick,
                            replies: ref.watch(tavernQuickRepliesProvider),
                            onSend: _sendQuick,
                            onEdit: _editQuick,
                            scriptButtons: scriptButtons,
                            onScriptButton: _pressScriptButton,
                            onDice: () => unawaited(_dice()),
                            onAll: () => unawaited(_allQuick()),
                          )
                        : null,
                    // While the box is empty: 帮我写 (an idea to start from) and, after
                    // a reply, 接着写 (it goes on).
                    accessory: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _input,
                      builder: (context, value, _) {
                        if (_running || messages == null) return const SizedBox.shrink();
                        // With a line written: other ways to send it.
                        if (value.text.isNotEmpty) {
                          return _ComposerKey(
                            key: const ValueKey('tavern-send-as'),
                            icon: AppIcons.more,
                            label: l10n.tavernSendOptions,
                            onPressed: () => unawaited(_sendOptions()),
                          );
                        }
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _ComposerKey(
                              key: const ValueKey('tavern-write-for-me'),
                              icon: AppIcons.write,
                              label: l10n.tavernWriteForMe,
                              onPressed: _impersonate,
                            ),
                            if (messages.lastOrNull?.role == TavernRole.character)
                              _ComposerKey(
                                key: const ValueKey('tavern-continue'),
                                icon: AppIcons.continueReply,
                                label: l10n.tavernContinueReply,
                                onPressed: _continueLast,
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether this chat's messages put their HTML in islands: the character's
/// own choice or 酒馆设置's, decided once by the page for every message.
class _IslandsScope extends InheritedWidget {
  const _IslandsScope({required this.islands, required super.child});

  final bool islands;

  static bool? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_IslandsScope>()?.islands;

  @override
  bool updateShouldNotify(_IslandsScope old) => old.islands != islands;
}

final _none = TavernMessage(nodeId: '', role: TavernRole.system, speaker: '', text: '', at: DateTime(0));

/// A quiet round key beside the composer's send key, the size of its others.
class _ComposerKey extends StatelessWidget {
  const _ComposerKey({super.key, required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkResponse(
          onTap: onPressed,
          radius: 22,
          child: SizedBox.square(
            dimension: 40,
            child: Icon(icon, size: 20, color: scheme.onSurface.withValues(alpha: 0.7)),
          ),
        ),
      ),
    );
  }
}

enum _MessageAction {
  copy,
  readAloud,
  edit,
  bookmark,
  regenerate,
  continueReply,
  inspect,
  branchHere,
  hide,
  deleteOne,
  delete,
}

/// A message on the path: the user's in a bubble, the character's as text;
/// the last character message carries its alternatives.
class _MessageRow extends StatelessWidget {
  const _MessageRow({
    super.key,
    required this.chatId,
    required this.message,
    required this.last,
    required this.busy,
    required this.onMenu,
    required this.onSibling,
    this.novel = false,
    this.indent = false,
    this.showUsage = false,
    this.lead = '',
    this.bookmarked = false,
    this.showName = false,
    this.tools = const [],
    this.onDecide,
    this.onRetryDecision,
  });

  /// What this reply's turns did with tools (a continuation is a turn of its
  /// own), oldest first; empty when there is nothing to show.
  final List<TavernToolTurnView> tools;
  final void Function(TavernMemoryProposalSnapshot proposal, TavernMemoryDecision decision)? onDecide;
  final void Function(TavernMemoryIntent intent)? onRetryDecision;

  /// The dice the model rolled and what it proposed to remember, under it.
  Widget? _tools() => message.role == TavernRole.character
      ? _toolStrips(message.nodeId, tools, onDecide: onDecide, onRetry: onRetryDecision)
      : null;

  final String chatId;
  final TavernMessage message;

  /// A group: each character's line says whose it is (bubbles too).
  final bool showName;

  /// Marked (书签): says so under it, as hidden does.
  final bool bookmarked;
  final bool last;
  final bool busy;
  final VoidCallback onMenu;
  final ValueChanged<int> onSibling;

  /// 小说 layout: every message full width under its speaker's name.
  final bool novel;

  /// 小说's paragraph indent (酒馆设置).
  final bool indent;

  /// A line of the tokens the reply took, under it.
  final bool showUsage;

  /// The tokens line, for a reply that has one to show.
  Widget? _usage() => switch (message.reportedUsage) {
    final usage? when showUsage && message.role == TavernRole.character => _UsageLine(
      key: ValueKey('tavern-usage-${message.nodeId}'),
      usage: usage,
      at: message.at,
    ),
    _ => null,
  };

  /// The chat's own character: their name in the accent, others' in their own colours.
  final String lead;

  @override
  Widget build(BuildContext context) {
    final drawn = novel ? _novel(context) : _bubble(context);
    // A reply with alternatives swipes sideways through them, like ‹ ›.
    final swipes = message.role == TavernRole.character && !busy && (last || message.siblingCount > 1);
    final body = swipes
        ? _SwipeToSwitch(
            key: ValueKey('tavern-swipe-${message.nodeId}'),
            canPrevious: message.siblingIndex > 0,
            canNext: message.siblingIndex + 1 < message.siblingCount || last,
            onSwitch: onSibling,
            child: drawn,
          )
        : drawn;
    if (!message.hidden && !bookmarked) return body;
    // Hidden from the model: still here for you, faded, and says so. Marked:
    // a bookmark under it.
    final end = !novel && message.role == TavernRole.user;
    return Column(
      crossAxisAlignment: end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (message.hidden) Opacity(opacity: 0.45, child: body) else body,
        const SizedBox(height: 4),
        Wrap(
          spacing: 12,
          children: [
            if (message.hidden) _HiddenTag(key: ValueKey('tavern-hidden-${message.nodeId}')),
            if (bookmarked) _BookmarkTag(key: ValueKey('tavern-bookmarked-${message.nodeId}')),
          ],
        ),
      ],
    );
  }

  Widget _bubble(BuildContext context) {
    if (message.role == TavernRole.user) {
      return GestureDetector(
        onLongPress: onMenu,
        child: _YourLine(
          child: _Shown(chatId: chatId, message: message),
        ),
      );
    }
    final alternatives = last || message.siblingCount > 1;
    // Only the newest reply carries ‹ ›; an older one with others shows how
    // many it has, and swipes like the newest.
    return GestureDetector(
      onLongPress: onMenu,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showName && message.role == TavernRole.character)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                tavernSpeaker(context, message),
                key: ValueKey('tavern-speaker-${message.nodeId}'),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: tavernNameColor(context, tavernSpeaker(context, message), lead: lead),
                  fontWeight: FontWeight.w600,
                  fontFamily: tavernNameFont(context),
                ),
              ),
            ),
          // Narration says so: it is no one's line.
          if (message.role == TavernRole.narrator)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                tavernSpeaker(context, message),
                key: ValueKey('tavern-narrator-${message.nodeId}'),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary),
              ),
            ),
          if (message.reasoning case final reasoning? when reasoning.isNotEmpty) ThinkingPill(reasoning: reasoning),
          _Shown(chatId: chatId, message: message),
          ?_usage(),
          ?_tools(),
          if (alternatives) ...[
            const SizedBox(height: 4),
            if (last)
              _Alternatives(message: message, last: last, busy: busy, onSibling: onSibling)
            else
              _AlternativesCount(message: message),
          ],
        ],
      ),
    );
  }

  Widget _novel(BuildContext context) {
    final theme = Theme.of(context);
    final user = message.role == TavernRole.user;
    final alternatives = !user && (last || message.siblingCount > 1);
    return GestureDetector(
      onLongPress: onMenu,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            user ? context.l10n.tavernYou : tavernSpeaker(context, message),
            style: theme.textTheme.labelMedium?.copyWith(
              color: user
                  ? DshColors.of(context).textTertiary
                  : tavernNameColor(context, tavernSpeaker(context, message), lead: lead),
              fontWeight: FontWeight.w600,
              fontFamily: user ? null : tavernNameFont(context),
            ),
          ),
          const SizedBox(height: 4),
          if (message.reasoning case final reasoning? when reasoning.isNotEmpty) ThinkingPill(reasoning: reasoning),
          Opacity(
            opacity: user ? 0.78 : 1,
            child: _Shown(chatId: chatId, message: message, indent: indent),
          ),
          ?_usage(),
          ?_tools(),
          if (alternatives) ...[
            const SizedBox(height: 4),
            if (last)
              _Alternatives(message: message, last: last, busy: busy, onSibling: onSibling)
            else
              _AlternativesCount(message: message),
          ],
        ],
      ),
    );
  }
}

/// The tokens a reply took, as the provider reported them (engine T24), and
/// for a DeepSeek model what that cost at its list prices when it was written
/// ([tavernReplyCost]); another model's is not guessed at.
class _UsageLine extends StatelessWidget {
  const _UsageLine({super.key, required this.usage, required this.at});

  final TavernUsage usage;
  final DateTime at;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = usage.cacheHitTokens > 0
        ? l10n.tavernUsageLineCached(usage.promptTokens, usage.cacheHitTokens, usage.completionTokens)
        : l10n.tavernUsageLine(usage.promptTokens, usage.completionTokens);
    final price = tavernModelPrice(usage.model);
    final cost = price == null ? null : tavernReplyCost(usage, price, at);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        cost == null ? tokens : '$tokens · ${tavernCostLabel(l10n, cost)}',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary),
      ),
    );
  }
}

/// While the box starts with a slash: the commands, each filling the box.
class _SlashRow extends StatelessWidget {
  const _SlashRow({required this.onPick});

  final ValueChanged<TavernSlash> onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String label(TavernSlash c) => switch (c) {
      TavernSlash.narrate => l10n.tavernNarrate,
      TavernSlash.sendOnly => l10n.tavernSendOnly,
      TavernSlash.continueReply => l10n.tavernContinueReply,
      TavernSlash.regenerate => l10n.tavernRegenerate,
      TavernSlash.impersonate => l10n.tavernWriteForMe,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: 36,
        child: ListView.separated(
          key: const ValueKey('tavern-slash-row'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          itemCount: TavernSlash.values.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final c = TavernSlash.values[i];
            return CapsuleChoiceChip(
              key: ValueKey('tavern-slash-${c.word}'),
              label: '/${c.word} ${label(c)}',
              selected: false,
              onSelected: () => onPick(c),
            );
          },
        ),
      ),
    );
  }
}

/// The capsules above the composer (§6): 快速回复 (tap sends, long-press puts
/// it in the box), the card's script buttons, then 掷骰.
class _QuickReplyRow extends StatelessWidget {
  const _QuickReplyRow({
    this.members = const [],
    this.onSpeak,
    this.directed = const [],
    this.onDirected,
    this.onDirectedSend,
    required this.replies,
    required this.onSend,
    required this.onEdit,
    this.scriptButtons = const [],
    this.onScriptButton,
    required this.onDice,
    required this.onAll,
  });

  /// The buttons the card's own scripts show, by script and name, as given.
  final List<(String, String)> scriptButtons;
  final void Function(String scriptId, String name)? onScriptButton;

  /// A group's members, before all else: a tap has that one speak next.
  final List<(String, String)> members;
  final ValueChanged<String>? onSpeak;

  /// The director's suggestions, first: a tap puts one in the box; a long
  /// press sends it as it is (docs/design/roleplay-ui.md §5).
  final List<String> directed;
  final ValueChanged<String>? onDirected;
  final ValueChanged<String>? onDirectedSend;

  final List<String> replies;
  final ValueChanged<String> onSend;
  final ValueChanged<String> onEdit;
  final VoidCallback onDice;

  /// 全部, last in the row while there are replies: every one, whole.
  final VoidCallback onAll;

  /// The first line, kept short enough for a capsule.
  static String _label(String reply) {
    final line = reply.trim().split('\n').first;
    return line.characters.length > 16 ? '${line.characters.take(16)}…' : line;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: SizedBox(
      height: 36,
      child: ListView.separated(
        key: const ValueKey('tavern-quick-replies'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: members.length + directed.length + replies.length + scriptButtons.length + (replies.isEmpty ? 1 : 2),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        // The director's suggestions arrive whenever it has them: each new
        // one fades in, a beat after the one before it.
        itemBuilder: (context, i) => i < members.length
            ? CapsuleChoiceChip(
                key: ValueKey('tavern-speak-${members[i].$1}'),
                icon: AppIcons.mention,
                label: members[i].$2,
                selected: false,
                onSelected: () => onSpeak?.call(members[i].$1),
              )
            : _directedOrReply(context, i - members.length),
      ),
    ),
  );

  Widget _directedOrReply(BuildContext context, int at) => at < directed.length
      ? TavernArrive(
          key: ValueKey(('tavern-directed-arrive', at, directed[at])),
          index: at,
          child: GestureDetector(
            onLongPress: onDirectedSend == null ? null : () => onDirectedSend!(directed[at]),
            child: CapsuleChoiceChip(
              key: ValueKey('tavern-directed-$at'),
              icon: AppIcons.askAi,
              label: _label(directed[at]),
              selected: false,
              onSelected: () => onDirected?.call(directed[at]),
            ),
          ),
        )
      : _item(context, at - directed.length);

  Widget _item(BuildContext context, int i) {
    if (i < replies.length) {
      return GestureDetector(
        key: ValueKey('tavern-qr-$i'),
        onLongPress: () => onEdit(replies[i]),
        child: CapsuleChoiceChip(label: _label(replies[i]), selected: false, onSelected: () => onSend(replies[i])),
      );
    }
    final at = i - replies.length;
    if (at < scriptButtons.length) {
      final (script, name) = scriptButtons[at];
      return CapsuleChoiceChip(
        key: ValueKey('tavern-script-button-$at'),
        icon: AppIcons.code,
        label: _label(name),
        selected: false,
        onSelected: () => onScriptButton?.call(script, name),
      );
    }
    return at == scriptButtons.length
        ? CapsuleChoiceChip(
            key: const ValueKey('tavern-dice'),
            label: context.l10n.tavernDice,
            selected: false,
            onSelected: onDice,
          )
        : CapsuleChoiceChip(
            key: const ValueKey('tavern-qr-all'),
            label: context.l10n.tavernQuickRepliesAll,
            selected: false,
            onSelected: onAll,
          );
  }
}

/// Swiping a reply sideways steps through its alternatives: left for the next
/// (past the last on the newest reply, a new one, as › does), right for the
/// previous. The reply follows the finger a little and springs back.
class _SwipeToSwitch extends StatefulWidget {
  const _SwipeToSwitch({
    super.key,
    required this.canPrevious,
    required this.canNext,
    required this.onSwitch,
    required this.child,
  });

  final bool canPrevious;
  final bool canNext;
  final ValueChanged<int> onSwitch;
  final Widget child;

  @override
  State<_SwipeToSwitch> createState() => _SwipeToSwitchState();
}

class _SwipeToSwitchState extends State<_SwipeToSwitch> {
  static const _distance = 64.0;
  static const _flick = 600.0;

  double _dx = 0;
  bool _dragging = false;

  void _update(DragUpdateDetails d) {
    final next = _dx + d.delta.dx;
    setState(() {
      _dragging = true;
      _dx = next.clamp(widget.canNext ? -160.0 : 0.0, widget.canPrevious ? 160.0 : 0.0);
    });
  }

  void _end(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (widget.canNext && (_dx <= -_distance || v <= -_flick)) {
      widget.onSwitch(1);
    } else if (widget.canPrevious && (_dx >= _distance || v >= _flick)) {
      widget.onSwitch(-1);
    }
    setState(() {
      _dragging = false;
      _dx = 0;
    });
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onHorizontalDragUpdate: _update,
    onHorizontalDragEnd: _end,
    onHorizontalDragCancel: () => setState(() {
      _dragging = false;
      _dx = 0;
    }),
    child: AnimatedContainer(
      duration: _dragging ? Duration.zero : AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
      // Half the finger's travel: it gives, but stays readable.
      transform: Matrix4.translationValues(_dx / 2, 0, 0),
      child: widget.child,
    ),
  );
}

/// 「模型看不到这条」 under a hidden message.
class _HiddenTag extends StatelessWidget {
  const _HiddenTag({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = DshColors.of(context).textTertiary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(AppIcons.hideSecret, size: 14, color: color),
        const SizedBox(width: 4),
        Text(context.l10n.tavernHiddenFromModel, style: theme.textTheme.labelSmall?.copyWith(color: color)),
      ],
    );
  }
}

/// Under a marked message: a bookmark and 书签.
class _BookmarkTag extends StatelessWidget {
  const _BookmarkTag({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary.withValues(alpha: 0.8);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(AppIcons.bookmarkActive, size: 14, color: color),
        const SizedBox(width: 4),
        Text(context.l10n.tavernBookmarks, style: theme.textTheme.labelSmall?.copyWith(color: color)),
      ],
    );
  }
}

/// ‹ 2/5 ›: the previous and next alternative; past the last one (on the last
/// reply) › writes a new one.
/// The story, with 舞台 at its right when there is room for both.
Widget _beside(Widget? stage, Widget story) => stage == null
    ? story
    : Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: story),
          SizedBox(width: _TavernChatPageState._stageWidth, child: stage),
        ],
      );

/// A message as shown (docs/design/roleplay-roadmap.md P0, engine T21): its
/// text through the display regex of the card, the preset and the library,
/// never stored. The text as written until that comes, or if it cannot.
final tavernShownTextProvider = FutureProvider.autoDispose.family<String, (String, String, String)>((ref, key) async {
  final (chatId, nodeId, text) = key;
  final shown = await ref.watch(tavernProvider).displayText(chatId, nodeId: nodeId, text: text);
  return shown.superseded ? text : shown.text;
});

/// The message gone to: a soft wash of the accent for a moment.
class _JumpMark extends StatelessWidget {
  const _JumpMark({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(AppShape.lg),
    ),
    child: child,
  );
}

/// A reply's tool turns, oldest first: each its dice and what it asks to
/// remember. Null when there are none.
Widget? _toolStrips(
  String nodeId,
  List<TavernToolTurnView> tools, {
  void Function(TavernMemoryProposalSnapshot proposal, TavernMemoryDecision decision)? onDecide,
  void Function(TavernMemoryIntent intent)? onRetry,
}) {
  if (tools.isEmpty) return null;
  Widget strip(TavernToolTurnView view, Key key) => TavernToolStrip(
    key: key,
    view: view,
    onDecide: (proposal, decision) => onDecide?.call(proposal, decision),
    onRetry: (intent) => onRetry?.call(intent),
  );
  final key = ValueKey('tavern-tools-$nodeId');
  if (tools case [final only]) return strip(only, key);
  return Column(
    key: key,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [for (final view in tools) strip(view, ValueKey('tavern-tools-${view.turn.logicalTurnId}'))],
  );
}

/// [message]'s text as [tavernShownTextProvider] shows it.
class _Shown extends ConsumerWidget {
  const _Shown({required this.chatId, required this.message, this.indent = false});

  final String chatId;
  final TavernMessage message;

  /// 小说's paragraph indent.
  final bool indent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Expression markers ([表情:x]) pick her picture; they are not words.
    final shown = tavernStripMarkers(
      ref.watch(tavernShownTextProvider((chatId, message.nodeId, message.text))).value ?? message.text,
    );
    Widget text(String markdown) =>
        MarkdownBody(text: indent ? tavernIndentParagraphs(markdown) : markdown, selectable: false);
    // HTML in it: those parts in islands of their own (酒馆设置 › 显示);
    // component tags (<dsh-letter>…) as cards, either way.
    final parts = tavernParts(
      shown,
      islands: _IslandsScope.of(context) ?? ref.watch(tavernSettingsProvider.select((s) => s.islands)),
    );
    if (parts case [TavernTextPart()]) return text(shown);
    final island = ref.watch(tavernIslandBuilderProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final part in parts)
          switch (part) {
            TavernTextPart(:final markdown) => text(markdown),
            TavernIslandPart(:final html) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: TavernIslandMessage(
                chatId: chatId,
                nodeId: message.nodeId,
                text: message.text,
                name: message.speaker,
                user: message.role == TavernRole.user,
                child: island(html),
              ),
            ),
            TavernComponentPart(:final component) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: TavernComponentView(component: component),
            ),
          },
      ],
    );
  }
}

/// Your line in the bubble layout: the app's bubble, with the story's
/// Markdown and colours inside (your *actions* in italics, as hers are).
class _YourLine extends StatelessWidget {
  const _YourLine({required this.child});

  /// The line, as shown.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surfaces = DshSurfaces.of(context);
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: LayoutBuilder(
        builder: (context, constraints) => ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.82),
          child: DecoratedBox(
            decoration: ShapeDecoration(color: surfaces.userBubble, shape: AppShape.bubble),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              // The bubble's own text colour for the narration.
              child: Theme(
                data: theme.copyWith(colorScheme: theme.colorScheme.copyWith(onSurface: surfaces.onUserBubble)),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An older reply's alternatives, as a count: switched by swiping.
class _AlternativesCount extends StatelessWidget {
  const _AlternativesCount({required this.message});

  final TavernMessage message;

  @override
  Widget build(BuildContext context) => Text(
    '${message.siblingIndex + 1}/${message.siblingCount}',
    key: ValueKey('tavern-alt-${message.nodeId}'),
    style: AppType.tabular(Theme.of(context).textTheme.labelSmall!.copyWith(color: DshColors.of(context).textTertiary)),
  );
}

class _Alternatives extends StatelessWidget {
  const _Alternatives({required this.message, required this.last, required this.busy, required this.onSibling});

  final TavernMessage message;
  final bool last;
  final bool busy;
  final ValueChanged<int> onSibling;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    final style = AppType.tabular(Theme.of(context).textTheme.labelSmall!.copyWith(color: dsh.textTertiary));
    final atEnd = message.siblingIndex >= message.siblingCount - 1;
    final canNext = !atEnd || last;
    // The keys' own padding would indent the row; line its ‹ up with the text.
    return Transform.translate(
      offset: const Offset(-10, 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('tavern-prev'),
            tooltip: l10n.tavernPrevious,
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            color: dsh.textTertiary,
            onPressed: busy || message.siblingIndex == 0 ? null : () => onSibling(-1),
            icon: Icon(AppIcons.keyLeft),
          ),
          Text('${message.siblingIndex + 1}/${message.siblingCount}', style: style),
          IconButton(
            key: const ValueKey('tavern-next'),
            tooltip: atEnd ? l10n.tavernRegenerate : l10n.tavernNext,
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            color: dsh.textTertiary,
            onPressed: busy || !canNext ? null : () => onSibling(1),
            icon: Icon(atEnd ? AppIcons.regenerate : AppIcons.keyRight),
          ),
        ],
      ),
    );
  }
}

/// From this many messages on, deleting asks first; fewer go at once.
const tavernDeleteAskFrom = 10;

/// How long a deletion's 撤销 stays up.
const tavernUndoWindow = Duration(seconds: 6);

/// What has arrived of the reply being written.
typedef _Streamed = ({String text, String reasoning});

const _Streamed _nothing = (text: '', reasoning: '');

/// The reply being written, rebuilt alone as each piece arrives: its text
/// as [live] shows it, through the display regex.
class _StreamingReply extends StatelessWidget {
  const _StreamingReply({
    super.key,
    required this.stream,
    required this.live,
    required this.thinking,
    this.indent = false,
    this.speaker,
    this.lead = '',
  });

  /// A group: who is writing it, over it.
  final String? speaker;
  final String lead;

  /// 小说's paragraph indent, as the reply will have once written.
  final bool indent;

  final ValueListenable<_Streamed> stream;
  final TavernLiveDisplay live;

  /// How long the model has thought, beside the pill.
  final ValueListenable<int?> thinking;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([stream, live]),
    builder: (context, _) {
      final (:text, :reasoning) = stream.value;
      final shown = live.shown;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (speaker case final who? when who.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                who,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: tavernNameColor(context, who, lead: lead),
                  fontWeight: FontWeight.w600,
                  fontFamily: tavernNameFont(context),
                ),
              ),
            ),
          if (reasoning.isNotEmpty)
            ThinkingPill(
              reasoning: reasoning,
              active: text.isEmpty,
              streaming: true,
              meta: _ThinkingClock(seconds: thinking),
            ),
          if (text.isEmpty && reasoning.isEmpty)
            const Align(alignment: Alignment.centerLeft, child: TypingIndicator())
          else if (shown.isNotEmpty)
            // Component tags turn into cards once the reply is in; while it
            // is written, only their words.
            MarkdownBody(
              text: indent
                  ? tavernIndentParagraphs(tavernComponentTagsOut(tavernStripMarkers(shown)))
                  : tavernComponentTagsOut(tavernStripMarkers(shown)),
              streaming: true,
              selectable: false,
            ),
        ],
      );
    },
  );
}

/// How long the model has thought: from the first second, after the label;
/// it stops counting when the reply starts and stays until the reply is in.
class _ThinkingClock extends StatelessWidget {
  const _ThinkingClock({required this.seconds});

  final ValueListenable<int?> seconds;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: seconds,
    builder: (context, seconds, _) => switch (seconds) {
      final s? when s > 0 => Row(
        key: const ValueKey('tavern-thinking-clock'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const StreamDot(),
          Text(context.l10n.tavernThinkingSeconds(s), style: StreamRow.detail(context)),
        ],
      ),
      _ => const SizedBox.shrink(),
    },
  );
}

/// The header or the bottom of the chat, stepping aside while [hidden]: the
/// header slides up, the bottom folds away, so the story has the room.
class _Chrome extends StatelessWidget {
  const _Chrome({super.key, required this.hidden, required this.child, this.top = false});

  final ValueListenable<bool> hidden;
  final Widget child;
  final bool top;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: hidden,
    child: child,
    builder: (context, hidden, child) {
      final duration = AppMotion.of(context, AppMotion.standard);
      final shown = AnimatedOpacity(opacity: hidden ? 0 : 1, duration: duration, child: child);
      return IgnorePointer(
        ignoring: hidden,
        child: top
            ? AnimatedSlide(offset: hidden ? const Offset(0, -1.2) : Offset.zero, duration: duration, child: shown)
            : ClipRect(
                child: AnimatedAlign(
                  alignment: Alignment.topCenter,
                  heightFactor: hidden ? 0 : 1,
                  duration: duration,
                  curve: AppMotion.std,
                  child: shown,
                ),
              ),
      );
    },
  );
}

/// Over the composer while no DeepSeek key is set: what is missing, and where
/// it goes.
class _KeyMissing extends StatelessWidget {
  const _KeyMissing({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassSurface(
        key: const ValueKey('tavern-key-missing'),
        tier: GlassTier.card,
        borderRadius: AppShape.radiusLg,
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            Icon(AppIcons.noApiKey, size: 18, color: dsh.textTertiary),
            const SizedBox(width: 10),
            Expanded(child: Text(l10n.tavernKeyMissing, style: theme.textTheme.bodySmall)),
            TextButton(onPressed: onAdd, child: Text(l10n.tavernKeyMissingAction)),
          ],
        ),
      ),
    );
  }
}

/// The last turn's error over the composer, with 「重试」 when it can retry;
/// or, [calm], how it ended (cut short, filtered) with the way on.
class _ErrorSlot extends StatelessWidget {
  const _ErrorSlot({required this.error, this.calm = false, required this.action, required this.onDismiss});

  final String? error;
  final bool calm;
  final ({String label, VoidCallback onPressed})? action;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => SmoothSize(
    duration: AppMotion.of(context, AppMotion.standard),
    curve: AppMotion.std,
    alignment: Alignment.bottomCenter,
    child: error == null
        ? const SizedBox(width: double.infinity)
        : Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: calm
                ? _Notice(message: error!, action: action, onDismiss: onDismiss)
                : ErrorBanner(
                    key: const ValueKey('tavern-error'),
                    message: error!,
                    onDismiss: onDismiss,
                    action: action,
                  ),
          ),
  );
}

/// A word over the composer that is not an error: quiet glass, as
/// [_KeyMissing], with its button and a way to put it away.
class _Notice extends StatelessWidget {
  const _Notice({required this.message, required this.action, required this.onDismiss});

  final String message;
  final ({String label, VoidCallback onPressed})? action;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    final theme = Theme.of(context);
    final words = Text(message, style: theme.textTheme.bodySmall);
    return GlassSurface(
      key: const ValueKey('tavern-notice'),
      tier: GlassTier.card,
      borderRadius: AppShape.radiusLg,
      padding: const EdgeInsets.fromLTRB(14, 6, 2, 6),
      child: Row(
        children: [
          Icon(AppIcons.info, size: 18, color: dsh.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: switch (action) {
              null => words,
              final action => LayoutBuilder(
                builder: (context, box) {
                  final button = TextButton(onPressed: action.onPressed, child: Text(action.label));
                  // Beside the words while they keep over half the row; under
                  // them when a long label on a narrow screen or in large text
                  // would squeeze them into a column of short lines.
                  final label = TextPainter(
                    text: TextSpan(text: action.label, style: theme.textTheme.labelLarge),
                    textDirection: Directionality.of(context),
                    textScaler: MediaQuery.textScalerOf(context),
                    maxLines: 1,
                  )..layout();
                  final beside = box.maxWidth - (label.width + 24) >= box.maxWidth * 0.55;
                  label.dispose();
                  if (beside) {
                    return Row(
                      children: [
                        Expanded(child: words),
                        button,
                      ],
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: SizedBox(width: double.infinity, child: words),
                      ),
                      button,
                    ],
                  );
                },
              ),
            },
          ),
          IconButton(
            onPressed: onDismiss,
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            icon: Icon(AppIcons.close, size: 16, color: dsh.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// How long a pause in 小说 starts a new chapter.
const tavernChapterGap = Duration(hours: 6);

/// A chapter's start in 小说: a hairline each side of when it picks up.
class TavernChapterBreak extends StatelessWidget {
  const TavernChapterBreak({super.key, required this.at});

  final DateTime at;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final now = DateTime.now();
    final hm = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final day = at.year == now.year ? context.l10n.monthDay(at) : '${at.year}/${at.month}/${at.day}';
    final line = Expanded(child: Divider(color: dsh.textTertiary.withValues(alpha: 0.3), height: 1));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(
        children: [
          line,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '$day $hm',
              style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: dsh.textTertiary)),
            ),
          ),
          line,
        ],
      ),
    );
  }
}
