// 伙伴小屋: a whole page for the companion (docs/design/companion.md). She fills
// the screen in a WebView; on top of it, in Flutter, her words and a small input.
// Both modes share the room's presentation. In full mode the Host session
// supplies live assistant words, tools, questions and approvals.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../companion/companion_residency.dart';
import '../../companion/companion_adapt.dart';
import '../../companion/companion_agent.dart';
import '../../companion/companion_agent_task_ui.dart';
import '../../companion/companion_always_on.dart' show companionAlwaysOnOwnerProvider;
import '../../companion/companion_float.dart' show companionPackNameProvider;
import '../../state/companion_agent_state.dart';
import '../../companion/companion_initiative.dart';
import '../../companion/companion_initiative_owner.dart';
import '../../companion/companion_memory.dart';
import '../../companion/companion_host_tasks.dart';
import '../../companion/companion_maps.dart';
import '../../companion/companion_late_use.dart';
import '../../companion/companion_moves.dart';
import '../../companion/companion_light.dart';
import '../../companion/companion_pack.dart';
import '../../companion/companion_reply.dart';
import '../../companion/companion_signal_consent.dart';
import '../../companion/companion_signals.dart';
import '../../companion/companion_state.dart';
import '../../companion/companion_voice.dart';
import '../../companion/companion_voice_source.dart';
import '../../companion/companion_widget.dart';
import '../../l10n/l10n.dart';
import '../../links/launcher_entries.dart';
import '../../notify/chat_alerts.dart' show CompanionAlertDelivery, companionHostKey;
import '../../pets/pet_mood.dart' show PetEvent, PetEventKind;
import '../../pets/pet_signals.dart' show petEventBusProvider;
import '../../pets/pet_state.dart';
import '../../speech/speech_settings.dart';
import '../../speech/voice_cloud.dart';
import '../../state/android_features.dart' show operatingSystemProvider;
import '../../state/app_mode_state.dart';
import '../../state/android_features.dart';
import '../../state/chat_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/models_state.dart';
import '../../state/phone_state.dart' show phoneChannelProvider;
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/voice_model_state.dart';
import '../../state/voice_settings.dart';
import '../../state/voice_state.dart';
import '../../state/workshop_catalog_state.dart' show WorkshopKindFilter, workshopCatalogProvider;
import '../../usage/usage_stats.dart';
import '../chat/model_sheet.dart';
import '../chat/voice/voice_controller.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/discard_guard.dart';
import '../common/empty_view.dart';
import '../common/sheet_title_bar.dart';
import '../modes/mode_switch.dart';
import '../settings/settings_widgets.dart';
import '../theme/accent.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/semantic_colors.dart';
import '../theme/motion.dart';
import '../theme/surfaces.dart';
import '../shell/page_frame.dart';
import '../workshop/workshop_screen.dart';
import '../workspace/directory_picker.dart';
import 'companion_ask.dart';
import 'companion_chrome.dart';
import 'companion_assistant_settings.dart';
import 'companion_draft_inputs.dart';
import 'companion_receipt_inputs.dart';
import 'companion_log.dart';
import 'companion_memory_page.dart';
import 'companion_memory_model_dialog.dart';
import 'companion_notices_page.dart';
import 'companion_persona_page.dart';
import 'companion_room_panel.dart';
import '../../companion/companion_lines.dart';
import '../../companion/companion_call.dart';
import '../../companion/companion_roster.dart';
import '../speech/voice_call_page.dart' show openVoiceCall;
import 'companion_voice_page.dart';
import 'companion_stage.dart';
import 'companion_tasks_page.dart';

/// The person removed her pack: the one inside the app waits to be asked for.
const _packRemovedKey = 'companion_pack_removed';
const _hintDoneKey = 'companion_touch_hint_done';
const _homeHintDoneKey = 'companion_home_hint_done';

enum _Phase { checking, setup, stage, failed }

typedef CompanionStageBuilder = Widget Function(CompanionStageController controller, CompanionStageEvents events);

/// The rooms open now, oldest first.
final _openRooms = Provider((_) => <_CompanionPageState>[]);

Future<void> openCompanionAssistant(BuildContext context, WidgetRef ref, CompanionAssistantEntry entry) async {
  if (ref.read(_openRooms).reversed.any((room) => room._receiveAssistant(entry))) return;
  await Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => CompanionPage(assistantEntry: entry)));
}

/// Back after a phone task asked for in her room: the room still open, as
/// the person left it and her reply in it, comes out from under anything
/// opened over it. Only when none is open (closed meanwhile) does a new one
/// come up.
Future<void> showCompanionRoom(BuildContext context, WidgetRef ref) async {
  final rooms = ref.read(_openRooms);
  if (rooms.isNotEmpty) return rooms.last._comeForward();
  await Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute<void>(builder: (_) => const CompanionPage(sections: true)));
}

class CompanionPage extends ConsumerStatefulWidget {
  const CompanionPage({
    super.key,
    this.storeOverride,
    this.stageBuilder,
    this.stageController,
    this.bundledPack,
    this.sections = false,
    this.assistantEntry,
  });

  /// The whole 伙伴小屋 section: her room, what she remembers, what you asked
  /// her to do and her own page, under one bar along the bottom. Without it,
  /// just the room with its ⋯ panel.
  final bool sections;
  final CompanionAssistantEntry? assistantEntry;

  /// Tests point this at a temporary folder.
  final CompanionPackStore? storeOverride;

  /// The pack inside the app. Tests bring their own; with a test folder and
  /// none given, there is none.
  final Future<Uint8List?> Function()? bundledPack;

  /// Tests have no WebView.
  final CompanionStageBuilder? stageBuilder;
  final CompanionStageController? stageController;

  @override
  ConsumerState<CompanionPage> createState() => _CompanionPageState();
}

class _CompanionPageState extends ConsumerState<CompanionPage>
    implements CompanionInitiativeRoom, CompanionAgentRoomUi, CompanionFallbackUi {
  void _update(VoidCallback change) => setState(change);

  late final _stage = widget.stageController ?? CompanionStageController();
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _random = Random();
  late final VoiceInputController _voice;
  late final List<_CompanionPageState> _rooms;
  bool _assistantVoicePending = false;
  bool _assistantReturnToApp = false;
  String? _assistantPage;

  CompanionPackStore? _store;
  String? _characterSourceKey;
  String? _affinityCharacter;
  int _bondTier = 0;
  Object? _affinitySettledDay;
  CompanionCharacter _character = const CompanionCharacter();
  _Phase _phase = _Phase.checking;

  /// Counts entries into the stage phase. It keys the stage, so coming back after a failure
  /// or a new pack always builds a fresh one: a retired stage has no server and never restarts.
  int _stageRun = 0;
  String? _failure;

  /// The failed screen offers 重试: her pack is still on the phone.
  bool _failedWithPack = false;
  bool _stageReady = false;
  bool _greetingPending = true;
  bool _installing = false;

  /// This app carries a pack, and the first one is unpacking while she arrives.
  bool _bundledHere = false;
  bool _arriving = false;
  String? _installError;
  bool _showTouchHint = false;

  /// After the first touch: her shell, bubble and cushion can be tapped too.
  bool _showHomeHint = false;
  bool _homeHintDone = true;

  // The process Agent owns conversation and receipts. This window retains its
  // original attachment, including while a newer room is already present.
  late final CompanionAgent _agent;
  late final Future<Directory> _packRoot;
  late final CompanionAgentAttachment _attachment;
  int _bindingEpoch = 0;
  late bool _boundLight;
  String? get _sessionId => ref.read(companionSessionsProvider.notifier).ofCharacter(ref.read(activeHostProvider), _characterSourceKey)?.sessionId;
  bool _sending = false;
  bool _running = false;
  bool _needsAttention = false;
  bool _asleep = false;

  /// The backlog is over her (companion_log.dart).
  bool _logOpen = false;
  bool _phoneLog = false;
  ({(CompanionMemoryStore, int, int, String?, String) key, List<CompanionLogEntry> entries})? _savedLightLog;

  /// What she's doing in her corner (the stage's word for it).
  String _home = 'idle';
  String? _baselineUser;
  bool _baselineSet = false;
  int _marksHandled = 0;
  int _wordsSpoken = 0;
  String _replyWords = '';

  /// The reply [_onReply] last read, for the frames that show it.
  ({String text, bool streaming, CompanionReply reply})? _lastReply;
  ({String? user, CompanionMoves moves, CompanionReplyStream reader})? _replyStream;

  // The log can still display the phone's pre-Agent history. New messages in
  // both modes use the original SQLite phone conversation.
  CompanionLightHistory? _lightHistory;
  CompanionMemoryOwner? get _memoryOwner => _attachment.memory;
  CompanionSnapshot? _vitals;

  // What's on screen.
  final _bubbleWords = ValueNotifier<String?>(null);
  String? get _bubble => _bubbleWords.value;
  set _bubble(String? text) => _bubbleWords.value = text;
  String? _bubbleReplyId;
  var _bubbleTextKey = GlobalKey();
  List<({String taskId, String placeName})> _lookupResults = const [];
  List<String> _notesResults = const [];
  List<String> _mapResults = const [];
  late final CompanionMapHandoff _mapHandoff;
  bool _mapChoosing = false;
  bool _bubbleIsError = false;
  String? _myLine;
  String? _lastLine;
  Timer? _bubbleTimer;
  String? _memoryFollowupTicket;
  Timer? _settleTimer;
  Timer? _objectTimer;

  /// What this model brings of its own (companion_moves.dart), once it has loaded.
  CompanionMoves _moves = const CompanionMoves();

  /// What the model is (companion_adapt.dart), from the stage.
  CompanionProbe? _probe;

  /// Her own AI is fitting the model to her.
  bool _adapting = false;

  /// Whose moves these are: their names and choices are kept per character.
  /// Whose moves the saved labels and AI switches are: this very model (its
  /// moc3), so another model that happens to share a name never inherits them.
  String _movesKey = 'default';
  int _movesEpoch = 0;

  /// A fitting offered for this model, waiting for the person's yes (the first
  /// time anything would be sent on its own).
  CompanionProbe? _adaptOffer;

  // Her other work: conversations on the hosts that finish, fail or wait on
  // the person while they're here. The pill is the way there; what she says
  // about it comes only through the signal gate below.
  StreamSubscription<PetEvent>? _agentEvents;
  ({String sessionId, String label})? _agentPill;
  Timer? _agentPillTimer;

  // What she may bring up (Pro C902): one gate for this page, fed by the
  // active host's alert lane and, late at night, by time spent in this room.
  // Only her own short lines come out of it; nothing reaches a model.
  late final CompanionSignalGate _signals;
  late final CompanionInitiativeClock Function() _clock;
  String? _signalContext;
  CompanionSignalSource? _hostSignals;
  late final CompanionSignalSource _roomSignals = CompanionSignalSource.local(
    owner: this,
    isAttached: () => mounted && !_leaving,
  );
  StreamSubscription<CompanionAlertDelivery>? _taskSignals;
  CompanionSignalIngress? _lateUseIngress;
  DshClient? _watchedClient;
  StreamSubscription<MuxGeneration>? _muxGenerations;
  StreamSubscription<DshConnectionState>? _muxStates;
  final _lateUse = CompanionLateUseTracker();
  Timer? _lateUseTimer;

  // Her voice (companion_voice.dart): what is queued, and how far into the
  // current reply she has read aloud. Her mouth follows the engine when it
  // reports what it is reading, else the text's own rhythm.
  late final CompanionSpeaker _speaker;
  StreamSubscription<CompanionVoiceEvent>? _ttsEvents;
  String? _voiceNotice;
  Timer? _voiceNoticeTimer;
  bool _fallbackNoted = false;
  bool _ttsReady = false;
  CompanionVoiceSource? _ttsSource;
  bool _ttsRanges = false;
  int _ttsSerial = 0;
  String _spokenPrefix = '';
  final Map<String, int> _ttsPending = {};
  // Phone steps of the current reply seen so far, and, while she is on the
  // phone, a stop from the island or pill that also stops her voice.
  int _phoneSteps = 0;
  StreamSubscription<void>? _phoneStops;
  bool _replyClearedWidget = false;

  // Her invitation to rest (Pro C451/C452): the installation's owner decides,
  // this page shows it and says what the person really does.
  static int _pages = 0;
  final int _page = ++_pages;
  late final CompanionInitiative _initiative;
  late final AppLifecycleListener _lifecycle;
  int _stageEpoch = 0;
  CompanionInitiativeDisplay? _invite;
  int? _inviteEnds;

  /// The invitation shown, until it is answered or the page moves on.
  String? _inviteOpen;
  bool _routeShown = true;

  /// The erase question last actually put in front of the person.
  String? _rawEraseOffered;

  /// Marks [id] offered once its card has been drawn: only then does its
  /// five minutes start, and only a card on screen counts.
  void _offerRawErase(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _rawEraseOffered == id || !_attachment.isAttached) return;
      if (_attachment.pendingRawErase?.id != id) return;
      _rawEraseOffered = id;
      try {
        _attachment.markRawEraseOffered(id);
      } on Object {
        return;
      }
      setState(() {});
    });
  }

  String _rawEraseQuestion(L10n l10n, CompanionPendingRawErase erase) {
    final preview = erase.previewText.trim();
    final quote = preview.runes.length > 18 ? '${String.fromCharCodes(preview.runes.take(18))}…' : preview;
    return erase.rawMessageCount > 1
        ? l10n.companionRawEraseAskMany(quote, erase.rawMessageCount)
        : l10n.companionRawEraseAsk(quote);
  }

  /// The person's own answer: only a tap on 删掉 erases, and she says what happened.
  void _answerRawErase(CompanionPendingRawErase? pending, {required bool erase}) {
    if (pending == null || !_attachment.isAttached) return;
    _acted();
    final l10n = context.l10n;
    final CompanionRawEraseResult result;
    try {
      result = erase ? _attachment.confirmRawErase(pending.id) : _attachment.declineRawErase(pending.id);
    } on Object {
      _say(l10n.companionRawEraseGone);
      return;
    }
    setState(() {});
    _say(switch (result.state) {
      'confirmed' => l10n.companionRawErased,
      'declined' => l10n.companionRawKept,
      _ => l10n.companionRawEraseGone,
    });
  }

  /// Which of the section's pages shows ([CompanionPage.sections]).
  _CompanionTab _tab = _CompanionTab.room;

  /// What she remembers, opened once for the section's pages.
  Future<CompanionMemoryOwner>? _sectionMemory;

  /// A context under the room's own theme, for the sheets that belong to her room.
  BuildContext? _themedContext;

  void _selectTab(_CompanionTab tab) {
    if (_tab == tab || !mounted) return;
    _acted();
    if (tab != _CompanionTab.room) {
      _hush();
      _focus.unfocus();
      // Dictation belongs to the room's composer, which is hidden now.
      if (_voice.active) _voice.stop();
    }
    setState(() => _tab = tab);
  }

  int _notesForegroundEpoch = 0;
  final _notesSelectionRoutes = <ModalRoute<Object?>>{};
  bool _accessible = false;
  bool _leaving = false;
  bool _observeQueued = false;

  @override
  void initState() {
    super.initState();
    _mapHandoff = CompanionMapHandoff(ref.read(companionMapsProvider));
    // Anonymous usage statistics: the room was opened once more.
    ref.read(usageStatsProvider.notifier).count(UsageCount.room);
    _initiative = ref.read(companionInitiativeProvider);
    // How often she may speak up: the person's pick, followed as it changes.
    // The gate keeps the owner's clocks, so a line's deadline means the same to both.
    _clock = ref.read(companionInitiativeClockProvider);
    _signals = CompanionSignalGate(
      monotonicMs: () => _clock().monoMs,
      utcNow: () => DateTime.fromMillisecondsSinceEpoch(_clock().wallMs, isUtc: true),
    );
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) {
          _notesForegroundEpoch++;
          _mapHandoff.close();
          if (state == AppLifecycleState.paused && (_assistantPage != null || _assistantReturnToApp)) {
            setState(() {
              _assistantPage = null;
              _assistantReturnToApp = false;
              _assistantVoicePending = false;
            });
          }
        } else if (mounted) {
          // A reply can finish while this window is paused. Its next actual
          // frame, even without another Agent notification, may present it.
          setState(() {});
          scheduleMicrotask(_startAssistantVoice);
        }
        _observeInitiative();
        _observeLateUse();
      },
    );
    _lateUseTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _observeLateUse();
      _observeInitiative();
    });
    ref.listenManual(companionSignalConsentProvider, (_, _) => _syncSignals());
    _boundLight = _light;
    _voice = VoiceInputController(
      input: _input,
      bridge: ref.read(voiceBridgeProvider),
      mode: () => ref.read(voiceSettingsProvider.notifier).ready(),
      cloud: (mode) => ref.read(voiceCloudProvider)(mode),
      cloudLikely: () => ref.read(voiceCloudLikelyProvider)(),
      modelReady: () =>
          mounted &&
          (ref.read(activeConnectionProvider).value?.isLocal ?? false) &&
          ref.read(voiceModelProvider).status == VoiceModelStatus.ready,
      client: () => mounted ? ref.read(activeConnectionProvider).value?.client : null,
      onRecognized: () {
        final current = _currentRoom();
        scheduleMicrotask(() {
          if (current() && _input.text.trim().isNotEmpty) unawaited(_send());
        });
      },
    );
    // What dictation has to say (a notice, why it failed) comes in her bubble, not aloud.
    _voice.onMessage = (message) => _say(message.text, aloud: false);
    _voice.addListener(_voiceChanged);
    _agentEvents = ref.read(petEventBusProvider).events.listen(_onAgentEvent);
    _speaker = ref.read(companionSpeakerProvider);
    _ttsEvents = _speaker.events.listen(_onTts);
    _agent = ref.read(companionAgentProvider);
    _packRoot = widget.storeOverride != null
        ? Future.value(widget.storeOverride!.root)
        : getApplicationSupportDirectory().then((directory) => Directory('${directory.path}/companion'));
    _attachment = _agent.attach(
      root: _packRoot,
      character: _character,
      moves: _moves,
      ui: this,
      mapHandoff: _mapHandoff,
    );
    _agent.addListener(_onAgentChanged);
    if (_attachment.replyId != null) _onAgentChanged();
    ref.listenManual(companionEffectiveVoiceProvider, (_, settings) {
      if (settings != null) unawaited(_prepareVoice(settings));
    }, fireImmediately: true);
    _focus.addListener(_refreshMood);
    _input.addListener(_inputChanged);
    _rooms = ref.read(_openRooms)..add(this);
    if (widget.assistantEntry case final entry?) {
      _assistantVoicePending = true;
      _assistantPage = entry.page;
      _assistantReturnToApp = entry.returnToApp;
    }
    unawaited(_prepare());
  }

  bool _receiveAssistant(CompanionAssistantEntry entry) {
    if (_leaving || !_attachment.isAttached || ModalRoute.of(context)?.isCurrent != true) return false;
    _selectTab(_CompanionTab.room);
    _closeLog();
    setState(() {
      _assistantPage = entry.page;
      _assistantReturnToApp = entry.returnToApp;
      _assistantVoicePending = true;
    });
    _startAssistantVoice();
    return true;
  }

  /// Closes what was opened over this room (her tasks, her page, the
  /// workshop…) so the room itself shows, kept as it was. Unsaved edits up
  /// there are asked about first, as on any way back to the chat.
  Future<void> _comeForward() async {
    final route = ModalRoute.of(context);
    if (_leaving || route == null || route.isCurrent) return;
    if (!await DiscardGuard.confirmLeave(context) || !mounted) return;
    Navigator.of(context).popUntil((other) => other == route);
  }

  void _startAssistantVoice() {
    if (!mounted ||
        !_assistantVoicePending ||
        _phase != _Phase.stage ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _assistantVoicePending = false;
    if (_input.text.isNotEmpty || _attachment.preparing) return;
    _acted();
    _retireGreeting();
    _hush();
    unawaited(_voice.start());
  }

  Future<void> _prepare() async {
    final store = widget.storeOverride ?? CompanionPackStore(await _packRoot);
    final installed = await store.installed();
    final identity = await store.characterIdentity();
    final bundled = await _hasBundled();
    final removed = (await SharedPreferences.getInstance()).getBool(_packRemovedKey) ?? false;
    if (!mounted || !_attachment.isAttached) return;
    setState(() {
      _store = store;
      _setCharacter(identity.character, identity.key);
      _bundledHere = bundled;
      _phase = installed ? _Phase.stage : _Phase.setup;
    });
    _attachment.updateCharacter(_character, _moves, sourceKey: _characterSourceKey);
    unawaited(_prepareMemory());
    // The first time, the pack inside the app is unpacked while she swims over.
    // After the person removed it, it waits on the setup screen to be asked for.
    if (!installed && bundled && !removed) await _installBundled(arriving: true);
    _startAssistantVoice();
  }

  Future<bool> _hasBundled() async {
    final own = widget.bundledPack;
    if (own != null) return await own() != null;
    return widget.storeOverride == null && await hasBundledCompanionPack();
  }

  Future<Uint8List?> _bundled() =>
      widget.bundledPack?.call() ??
      (widget.storeOverride == null ? loadBundledCompanionPack() : Future<Uint8List?>.value());

  @override
  void dispose() {
    _rooms.remove(this);
    _mapHandoff.close();
    // Leaving her: no invitation follows, and nothing comes back to this page.
    _leaving = true;
    _agent.removeListener(_onAgentChanged);
    _attachment.detach();
    _lifecycle.dispose();
    _bubbleTimer?.cancel();
    _settleTimer?.cancel();
    _objectTimer?.cancel();
    unawaited(_agentEvents?.cancel());
    _lateUseTimer?.cancel();
    unawaited(_taskSignals?.cancel());
    unawaited(_muxGenerations?.cancel());
    unawaited(_muxStates?.cancel());
    _signals.leave();
    unawaited(_ttsEvents?.cancel());
    unawaited(_phoneStops?.cancel());
    _voiceNoticeTimer?.cancel();
    _agentPillTimer?.cancel();
    _voice.removeListener(_voiceChanged);
    _voice.dispose();
    _focus.dispose();
    _input.dispose();
    _bubbleWords.dispose();
    super.dispose();
  }

  Future<void> _openMemories() async {
    try {
      final memory = await _openMemory();
      if (!mounted || !_attachment.isAttached) return;
      final characterId = _attachment.characterId;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CompanionMemoryPage(memory: memory, characterId: characterId),
        ),
      );
    } on Object {
      if (mounted && _attachment.isAttached) _notice(context.l10n.companionMemoryLoadFailed);
    }
  }

  Future<void> _openTasks() async {
    try {
      final memory = await _openMemory();
      if (!mounted || !_attachment.isAttached) return;
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => CompanionTasksPage(memory: memory, allSessions: true)));
    } on Object {
      if (mounted && _attachment.isAttached) _notice(context.l10n.companionMemoryLoadFailed);
    }
  }

  Future<void> _openMemorySearch() async {
    try {
      final memory = await _openMemory();
      if (!mounted || !_attachment.isAttached) return;
      await showCompanionMemoryModelDialog(context, memory.embeddings);
    } on Object {
      if (mounted && _attachment.isAttached) _notice(context.l10n.companionMemoryLoadFailed);
    }
  }

  Future<void> _prepareMemory() async {
    try {
      await _openMemory();
    } on Object {
      if (mounted && _attachment.isAttached) _notice(context.l10n.companionMemoryLoadFailed);
    }
  }

  Future<CompanionMemoryOwner> _openMemory() => _attachment.openMemory();

  void _onAgentChanged() {
    if (!mounted || !_attachment.isAttached) return;
    _sending = _attachment.preparing;
    _syncAffinity();
    final id = _attachment.replyId;
    if (id == null) {
      setState(() {});
      return;
    }
    _onReply(
      id,
      _attachment.text,
      running: _attachment.running,
      attention: _attachment.waitingForOwner,
      error: _attachment.error == null ? null : _failureText(_attachment.error!),
    );
    _queueObserve();
  }

  @override
  bool get stageReady => _stageReady;
  @override
  String get forgottenNotice => context.l10n.companionMemoryForgotten;
  @override
  CompanionInitiativeRoom get initiativeRoom => this;
  @override
  CompanionInitiativeView get initiativeView => _initiativeView();
  @override
  bool get hasInvitation => _invite != null || _memoryFollowupTicket != null;
  @override
  CompanionAgentTaskUi tasks({required bool Function() isCurrent}) => _CompanionPageTaskUi(this, isCurrent);
  @override
  void committed(String raw) {
    if (!mounted || !_attachment.isAttached) return;
    _replyClearedWidget = false;
    if (_input.text == raw) _input.clear();
    _retireGreeting();
  }

  @override
  void continuedOnPhone(String sourceId) => _notice(context.l10n.companionContinuedOnPhone);

  @override
  void failed(Object error, {String? retry}) {
    _call?.done();
    if (!mounted || !_attachment.isAttached) return;
    if (retry != null && _input.text.isEmpty) _input.text = retry;
    _stage.command('emotion', {'name': 'worried', 'hold': 3000});
    // The line did not become her conversation: it must not stay above her.
    _myLine = null;
    _showBubble(_failureText(error), hold: const Duration(seconds: 6), error: true, clearTasks: false);
  }

  @override
  void controlChanged({required bool own}) {
    if (!mounted || !_attachment.isAttached) return;
    _replyClearedWidget = true;
    _lastLine = null;
    if (!own) setState(_resetConversation);
  }

  @override
  void connectionChanged() {
    if (!mounted || !_attachment.isAttached) return;
    _notesForegroundEpoch++;
    _boundLight = _light;
    setState(_resetConversation);
  }

  @override
  void detached() {
    // Retire this window while it still owns the speaker queue. A later
    // dispose must not stop the shared speaker after another visit attached.
    _notesForegroundEpoch++;
    _mapHandoff.close();
    _hush();
    _ttsReady = false;
    _voice.removeListener(_voiceChanged);
    unawaited(_voice.cancel());
  }

  @override
  void widgetClearPending() => _notice(context.l10n.companionMemoryWidgetPending);
  @override
  void vitalsChanged(CompanionSnapshot snapshot) => _applyVitals(snapshot);
  @override
  Future<void> greet(DateTime? lastVisit, bool Function() isCurrent) => _greet(lastVisit, isCurrent);
  @override
  bool presentFollowup(CompanionInitiativeDisplay display, String line) {
    if (!mounted || !_attachment.isAttached) return false;
    _say(line, widgetLine: false);
    _memoryFollowupTicket = display.ticket.id;
    return true;
  }

  @override
  void hideFollowup(String ticketId) => _hideMemoryFollowup(ticketId);

  // ── Stage events ─────────────────────────────────────────────────────────

  void _onReady() {
    setState(() {
      _stageReady = true;
      // A new view of her: nothing shown on the last one carries over.
      _stageEpoch++;
    });
    // A stage started again under the open log is under its blur too.
    if (_logOpen) _stage.command('covered', {'on': true});
    unawaited(_arrive());
    unawaited(_loadHint());
    _syncSignals();
  }

  /// Light or full (docs/design/companion.md §7). Until the person picks one:
  /// full when a host is connected, light otherwise.
  bool get _light {
    final mode = ref.read(companionModeProvider);
    return mode == CompanionMode.light || (mode == null && ref.read(activeConnectionProvider).value == null);
  }

  Future<void> _loadHint() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final touchDone = prefs.getBool(_hintDoneKey) ?? false;
    _homeHintDone = prefs.getBool(_homeHintDoneKey) ?? false;
    setState(() {
      _showTouchHint = !touchDone;
      _showHomeHint = touchDone && !_homeHintDone;
    });
  }

  /// Her state first (it knows when the person was last here, on any phone),
  /// then the greeting, then this visit.
  Future<void> _arrive({bool greet = true}) => _attachment.arrive(greet: greet);

  void _applyVitals(CompanionSnapshot snapshot) {
    _vitals = snapshot;
    final v = snapshot.vitals;
    _stage.command('vitals', {'valence': v.valence, 'energy': v.energy, 'closeness': _stageCloseness});
    _stage.command('activity', {'name': v.activity, 'remainingMs': snapshot.activityLeft.inMilliseconds});
    _widgetUpdate();
  }

  // These are display-only projections for the existing stage (0..1) and
  // widget (four dots), never another score or source of relationship growth.
  double get _stageCloseness => const [0.0, 0.03, 0.03, 0.10, 0.10, 0.30][_bondTier];
  int get _widgetBond => const [0, 1, 1, 2, 2, 3][_bondTier];

  void _syncAffinity() {
    final role = _attachment.characterId;
    final affinity = _attachment.affinity;
    final tier = affinity?.tier ?? 0;
    final settledDay = affinity?.settledDay;
    final previousRole = _affinityCharacter;
    final previousTier = _bondTier;
    final previousDay = _affinitySettledDay;
    if (role == previousRole && tier == previousTier && settledDay == previousDay) return;
    _affinityCharacter = role;
    _bondTier = tier;
    _affinitySettledDay = settledDay;
    if (role != null &&
        role == previousRole &&
        tier > previousTier &&
        settledDay != null &&
        settledDay != previousDay) {
      _closer(tier);
    }
    if (_vitals case final snapshot?) {
      final vitals = snapshot.vitals;
      _stage.command('vitals', {'valence': vitals.valence, 'energy': vitals.energy, 'closeness': _stageCloseness});
    }
    _widgetUpdate();
  }

  void _closer(int step) {
    _stage.command('emotion', {'name': 'happy', 'hold': 3200});
    _stage.command('action', {'name': 'hop'});
    _remember('pet', '你觉得和对方又亲近了一些');
    if (!mounted || _attachment.running || _attachment.preparing || _ttsPending.isNotEmpty) return;
    final l10n = context.l10n;
    _say(switch (step) {
      1 => l10n.companionCloser1,
      2 => l10n.companionCloser2,
      3 => l10n.companionCloser3,
      4 => l10n.companionCloser4,
      _ => l10n.companionCloser5,
    });
  }

  /// One event at a time, against the state last read. A conflict reads again;
  /// it never sends the same event twice.
  void _event(String type) => _attachment.event(type);

  /// A later intent owns this visit's response, even before it has words.
  void _retireGreeting() => _greetingPending = false;

  bool _takeGreeting(bool Function() current) {
    if (!current() || !_greetingPending) return false;
    _greetingPending = false;
    return !_running && !_sending;
  }

  Future<void> _greet(DateTime? lastVisit, bool Function() current) async {
    final now = DateTime.now();
    final greeting = companionGreeting(now, lastVisit ?? await companionLastSeen());
    unawaited(companionMarkSeen(now));
    if (!mounted || !_takeGreeting(current)) return;
    final l10n = context.l10n;
    final (line, emotion, action) = switch (greeting) {
      CompanionGreeting.firstTime => (_firstHello(l10n), 'shy', 'wave'),
      CompanionGreeting.morning => (l10n.companionGreetMorning, 'happy', 'wave'),
      CompanionGreeting.noon => (l10n.companionGreetNoon, 'calm', 'tilt'),
      CompanionGreeting.afternoon => (l10n.companionGreetAfternoon, 'calm', 'nodSmall'),
      CompanionGreeting.evening => (l10n.companionGreetEvening, 'happy', 'wave'),
      CompanionGreeting.lateNight => (l10n.companionGreetLate, 'worried', 'tilt'),
      CompanionGreeting.longAbsence => (l10n.companionGreetLong, 'surprised', 'hop'),
      CompanionGreeting.justNow => (l10n.companionGreetBack, 'calm', 'nodSmall'),
    };
    _stage.command('emotion', {'name': emotion, 'hold': 3200});
    _stage.command('action', {'name': action});
    _say(line);
  }

  void _onTouch(String zone, String kind) {
    _initiative.activate(this);
    _retireGreeting();
    if (_showTouchHint) {
      setState(() {
        _showTouchHint = false;
        _showHomeHint = !_homeHintDone;
      });
      unawaited(SharedPreferences.getInstance().then((p) => p.setBool(_hintDoneKey, true)));
    }
    final l10n = context.l10n;
    // At the v2 Close tier she has a fonder word too.
    final close = _bondTier >= 3;
    final lines = switch ((zone, kind)) {
      (_, 'hug') => [
        ..._linesFor('hug', [l10n.companionHug1, l10n.companionHug2, l10n.companionHug3]),
        if (close) ..._linesFor('hugClose', [l10n.companionHugClose]),
      ],
      (_, 'tease') => _linesFor('tease', [l10n.companionTease1, l10n.companionTease2, l10n.companionTease3]),
      (_, 'shake') => _linesFor('shake', [
        l10n.companionShake1,
        if (_ownWhale) ...[l10n.companionShake2, l10n.companionShake3] else l10n.companionShakeDizzy,
      ]),
      (_, 'pat') => [
        ..._linesFor('pat', [l10n.companionPat1, l10n.companionPat2, l10n.companionPat3]),
        if (close) ..._linesFor('patClose', [l10n.companionPatClose]),
      ],
      ('head', _) => _linesFor('tapHead', [l10n.companionTapHead1, l10n.companionTapHead2]),
      ('face', _) => _linesFor('tapFace', [l10n.companionTapFace1, l10n.companionTapFace2, l10n.companionTapFace3]),
      ('tail', _) => _linesFor('tapTail', [
        if (_ownWhale) l10n.companionTapTail1,
        l10n.companionTapTail2,
        if (_ownWhale) l10n.companionTapTail3,
      ]),
      ('legs', _) => _linesFor('tapLegs', [l10n.companionTapLegs1, l10n.companionTapLegs2]),
      _ => _linesFor('tapBody', [
        l10n.companionTapBody1,
        l10n.companionTapBody2,
        if (_ownWhale) l10n.companionTapBody3,
      ]),
    };
    // A hug is affection the way a pat is: the same event for her state.
    if (kind == 'pat' || kind == 'hug') _event('pet');
    _remember('pet', switch ((zone, kind)) {
      (_, 'hug') => '对方刚才抱了抱你',
      (_, 'tease') => '对方刚才连着戳你',
      (_, 'shake') => '对方刚才摇晃手机，把你晃晕了',
      (_, 'pat') => '对方刚才摸了摸你的头',
      ('tail', _) => '对方刚才碰了你的尾巴',
      ('face', _) => '对方刚才戳了戳你的脸',
      _ => null,
    });
    if (_running || _sending) return; // Her words first.
    final line = _pick(lines);
    _say(line);
  }

  /// How long an activity lasts when this host can't keep it (the bridge's
  /// own durations, docs/design/companion.md).
  static const _localActivity = {
    'snack': Duration(seconds: 45),
    'play': Duration(seconds: 90),
    'rest': Duration(minutes: 15),
  };

  /// A tap on one of her things.
  void _onObject(String id) {
    _initiative.activate(this);
    _useObject(id);
  }

  /// One of her things, from a tap or because she asked and the person said
  /// yes ([invited]): the same entry, so the cushion is the cushion either way.
  void _useObject(String id, {bool invited = false}) {
    _retireGreeting();
    if (!_homeHintDone) {
      _homeHintDone = true;
      setState(() => _showHomeHint = false);
      unawaited(SharedPreferences.getInstance().then((p) => p.setBool(_homeHintDoneKey, true)));
    }
    // The interaction belongs to her memory even while activity state is unavailable.
    _event(id);
    if (_vitals == null) {
      // Keep the same visible activity fallback when no snapshot is available.
      _stage.command('activity', {'name': id, 'remainingMs': _localActivity[id]!.inMilliseconds});
    }
    _remember(id == 'snack' ? 'feed' : 'pet', switch (id) {
      _ when invited => '你邀请对方陪你在海草软垫上歇一会儿，对方答应了',
      'snack' => '对方刚才给你吃了一块点心',
      'play' => '对方刚才陪你玩了泡泡球',
      _ => '对方刚才让你在海草软垫上歇一会儿',
    });
    if (_running || _sending) return;
    final l10n = context.l10n;
    final lines = switch (id) {
      _ when invited => [l10n.companionInviteYes1, l10n.companionInviteYes2],
      'snack' => _linesFor('snack', [l10n.companionSnack1, if (_ownWhale) l10n.companionSnack2, l10n.companionSnack3]),
      'play' => _linesFor('play', [l10n.companionPlay1, l10n.companionPlay2, l10n.companionPlay3]),
      _ => _linesFor('rest', [l10n.companionRest1, l10n.companionRest2]),
    };
    final line = _pick(lines);
    // After the snack has reached her, not before.
    _objectTimer?.cancel();
    _objectTimer = Timer(Duration(milliseconds: id == 'snack' ? 1700 : 900), () {
      if (mounted && !_running && !_sending) _say(line);
    });
  }

  /// A conversation of the person's (not hers) ended its turn, failed, or waits
  /// on them: when it is on the host in front, a pill offers the way there.
  /// Nothing more from here. Separately admitted task metadata reaches her
  /// Agent through _onTaskSignal; sharing task details still needs the person's
  /// consent for that item through the original signal gate.
  void _onAgentEvent(PetEvent event) {
    if (!mounted || _leaving || !_stageReady || event.sessionId == _sessionId) return;
    // Stopped is the person's own doing.
    if (event.kind == PetEventKind.stopped || event.host != ref.read(activeHostProvider)) return;
    final l10n = context.l10n;
    final title = _shortTitle(event.title);
    _agentPillTimer?.cancel();
    setState(() {
      _agentPill = (
        sessionId: event.sessionId,
        label: title == null ? l10n.companionTaskOpen : '${l10n.companionTaskOpen} · $title',
      );
    });
    _agentPillTimer = Timer(const Duration(seconds: 15), () {
      if (mounted) setState(() => _agentPill = null);
    });
  }

  // ── Signals (Pro C902) ───────────────────────────────────────────────────

  /// The gate follows this room (page, mode, binding, view of her) and the
  /// active connection's live generation; consents come from the person's
  /// settings. Any change retires what the old ones let in, and the listeners
  /// are installed again, each with the ingress current at that moment.
  void _syncSignals() {
    if (_leaving) return;
    final room = mounted && _stageReady && _phase == _Phase.stage ? _initiativeContext : null;
    if (room != _signalContext) {
      _signalContext = room;
      if (room == null) {
        _signals.leave();
      } else {
        _signals.enter(recipientContext: Object(), ownerEpoch: room);
      }
    }
    final connection = mounted ? ref.read(activeConnectionProvider).value : null;
    final client = connection?.client;
    if (!identical(client, _watchedClient)) {
      // A reconnect keeps the client but not the generation the source was made for.
      _watchedClient = client;
      unawaited(_muxGenerations?.cancel());
      unawaited(_muxStates?.cancel());
      _muxGenerations = client?.mux.generations.listen((_) => _syncSignals());
      _muxStates = client?.mux.states.listen((_) => _syncSignals());
    }
    final generation = client?.mux.generation;
    final old = _hostSignals;
    if (old == null || !identical(old.connection, connection) || !identical(old.generation, generation)) {
      if (old != null) _signals.retireSource(old);
      _hostSignals = null;
      if (connection != null && client != null && generation != null) {
        // The alert tracker's key for this connection: 本机 is local whatever host is picked.
        final hostKey = companionHostKey(connection.isLocal ? HostRef.local : ref.read(activeHostProvider));
        try {
          late final CompanionSignalSource source;
          source = CompanionSignalSource.dsh(
            hostKey: hostKey,
            client: client,
            connection: connection,
            isAttached: () =>
                mounted &&
                !_leaving &&
                identical(_hostSignals, source) &&
                identical(ref.read(activeConnectionProvider).value, connection),
          );
          _hostSignals = source;
        } on ArgumentError {
          // Not a ready connection after all: no signals from it.
        }
      }
    }
    final consent = ref.read(companionSignalConsentProvider) ?? const CompanionSignalConsent();
    final host = _hostSignals;
    if (host != null) _signals.setConsent(host, consent);
    _signals.setConsent(_roomSignals, consent);
    unawaited(_taskSignals?.cancel());
    _taskSignals = null;
    final ingress = host == null ? null : _signals.openIngress(host);
    if (ingress != null) {
      _taskSignals = ref
          .read(petEventBusProvider)
          .companionSignals
          .listen((delivery) => _onTaskSignal(delivery, ingress));
    }
    _lateUseIngress = _signals.openIngress(_roomSignals);
    // Retire a held preparation after a consent/source change through the
    // existing post-frame observer, never by presenting synchronously here.
    _queueObserve();
  }

  /// One of the active host's metadata signals (a turn ended, a request
  /// waits), through the ingress captured when the listener was installed.
  void _onTaskSignal(CompanionAlertDelivery delivery, CompanionSignalIngress ingress) {
    if (!mounted || _leaving) return;
    final session = delivery.signal.sessionId;
    // Her own turns are her own words, not news from elsewhere.
    if (session != null &&
        (session == _sessionId || ref.read(companionSessionFilterProvider)(ref.read(activeHostProvider), session))) {
      return;
    }
    if (delivery.receive(_signals, ingress) == CompanionSignalAdmission.accepted) _speakSignal(delivery.signal);
  }

  /// Late at night, time really spent here: a quarter of an hour with recent
  /// touches, and she may remind the person to rest (C902 late-use, night care).
  /// Touches only count; the minute tick and app lifecycle bring the reminder.
  void _observeLateUse({bool interaction = false}) {
    if (!mounted || _leaving) return;
    final now = _clock();
    final payload = _lateUse.observe(
      wallMs: now.wallMs,
      monoMs: now.monoMs,
      offsetMinutes: now.offsetMinutes,
      resumed: WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      interaction: interaction,
    );
    final ingress = _lateUseIngress;
    if (interaction || payload == null || ingress == null) return;
    if (!(ref.read(companionSignalConsentProvider)?.nightCare ?? false)) return;
    final CompanionSignalV1 signal;
    try {
      signal = CompanionSignalV1.fromJson({
        'v': 1,
        // A fresh id each minute: one not shown yet may still be, once a night.
        'id': 'late-use:${payload['nightKey']}:${now.monoMs ~/ 60000}',
        'kind': 'app.late_use',
        'source': {'type': 'device'},
        'observedAt': DateTime.fromMillisecondsSinceEpoch(now.wallMs, isUtc: true).toIso8601String(),
        'freshness': 'live',
        'payload': payload,
      });
    } on FormatException {
      return;
    }
    if (_signals.receive(ingress, signal) == CompanionSignalAdmission.accepted) _speakSignal(signal);
  }

  /// An admitted signal becomes at most one short line of hers, through the
  /// invitation owner: its quiet, its hours and its shared daily quota.
  void _speakSignal(CompanionSignalV1 signal) {
    final slot = _signals.slots.where((s) => identical(s.signal, signal)).firstOrNull;
    if (slot == null || !mounted) return;
    final language = Localizations.localeOf(context).languageCode == 'zh' ? 'zh' : 'en';
    final speech = _signals.speechCandidate(slot, language: language);
    final line = speech == null ? null : _signalLine(signal);
    if (speech == null || line == null) return;
    final contextKey = _initiativeContext;
    if (signal.kind == 'task.terminal') {
      _attachment.offerTaskSignal(
        speech,
        language: language,
        isCurrent: () => mounted && !_leaving && contextKey == _initiativeContext && _signals.speechCurrent(speech),
        present: (display, text) =>
            _presentSignal(display, speech, (line: text, emotion: line.emotion, action: line.action)),
      );
      return;
    }
    final candidate = CompanionInitiativeSignal(
      id: speech.id,
      contextKey: contextKey,
      expiresAtMonoMs: speech.expiresAtMonoMs,
      nightKey: speech.nightKey,
    );
    _initiative.requestSignal(
      this,
      _initiativeView(),
      candidate,
      isCurrent: () =>
          mounted && !_leaving && candidate.contextKey == _initiativeContext && _signals.speechCurrent(speech),
      present: (display) => _presentSignal(display, speech, line),
      // Her line keeps its own time on screen; there is nothing else to take down.
      hide: (_) {},
      nightCareEnabled: speech.nightCare,
    );
  }

  /// Task and night-care words stay local. Task phases supply the original
  /// visual style; the admitted signal supplies its local speech text.
  ({String line, String emotion, String action})? _signalLine(CompanionSignalV1 signal) {
    final l10n = context.l10n;
    return switch (signal.kind) {
      'task.terminal' => switch (signal.payload['phase']) {
        'completed' || 'output_limit' => (line: l10n.companionTaskDoneUntitled, emotion: 'happy', action: 'nodSmall'),
        'failed' => (line: l10n.companionTaskFailedUntitled, emotion: 'worried', action: 'tilt'),
        // Stopped is the person's own doing; an unclear end is not hers to guess at.
        _ => null,
      },
      'app.late_use' => (line: l10n.companionSignalLateUse, emotion: 'worried', action: 'tilt'),
      _ => null,
    };
  }

  /// True only once she has really said it (and with her voice only if the
  /// person allowed that too).
  bool _presentSignal(
    CompanionInitiativeDisplay display,
    CompanionSignalSpeech speech,
    ({String line, String emotion, String action}) say,
  ) {
    if (!mounted || _leaving || display.ticket.contextKey != _initiativeContext || !_signals.speechCurrent(speech)) {
      return false;
    }
    _stage.command('emotion', {'name': say.emotion, 'hold': 2600});
    _stage.command('action', {'name': say.action});
    _say(say.line, aloud: speech.voice);
    return true;
  }

  static String? _shortTitle(String? title) {
    final text = title?.trim();
    if (text == null || text.isEmpty) return null;
    return text.characters.length > 14 ? '${text.characters.take(13)}…' : text;
  }

  void _openAgent(String sessionId) {
    _agentPillTimer?.cancel();
    setState(() => _agentPill = null);
    ref.read(currentSessionProvider.notifier).select(sessionId);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _onActivity(String name) {
    if (mounted && name != _home) setState(() => _home = name);
  }

  void _onMood(String mood) {
    final asleep = mood == 'sleeping';
    if (asleep != _asleep && mounted) setState(() => _asleep = asleep);
  }

  /// Something that just happened, for her next turn (C905 kinds: pet, feed,
  /// task-finished, renamed). Kept for half an hour, eight at most.
  void _remember(String kind, String? note) => _attachment.remember(kind, note);

  /// Present one short line. [aloud]: with her voice, when it is on.
  void _say(String line, {bool aloud = true, bool widgetLine = true}) {
    if (!mounted || !_attachment.isAttached) return;
    _objectTimer?.cancel();
    if (!aloud || !_speakAloud(line, flush: true)) _stage.command('say', {'chars': line.length});
    _showBubble(line, hold: Duration(milliseconds: 2400 + line.length * 90));
    if (widgetLine) _widgetUpdate(line: line);
  }

  /// The home-screen widget: who she is, what she's doing, how well she knows
  /// the person, and [line] when she has just said something.
  void _widgetUpdate({String? line}) {
    if (!mounted || !_attachment.isAttached) return;
    final l10n = context.l10n;
    final snapshot = _vitals;
    final activity = snapshot?.vitals.activity ?? _home;
    unawaited(
      ref.read(companionWidgetProvider).update({
        if (_memoryOwner case final memory?) ...{
          'memoryArchiveId': memory.store.archive['id'],
          'memoryControlRevision': memory.store.archive['control_revision'],
        },
        'name': _name(l10n),
        'activity': activity,
        'status': switch (activity) {
          'snack' => l10n.companionStatusSnacking,
          'play' => l10n.companionStatusPlaying,
          'rest' => l10n.companionStatusResting,
          _ => l10n.companionStatusIdle,
        },
        'untilMs': snapshot == null
            ? null
            : DateTime.now().millisecondsSinceEpoch + snapshot.activityLeft.inMilliseconds,
        'statusAsleep': l10n.companionStatusSleeping,
        'statusWaiting': l10n.companionWidgetWaiting,
        'bond': _affinityCharacter == null ? null : _widgetBond,
        if (line != null) ...{'line': line, 'saidAt': DateTime.now().millisecondsSinceEpoch},
      }),
    );
  }

  /// Her name: the one the person gave her, else her pack's, else just "her".
  String _name(L10n l10n) => ref.read(companionNameProvider) ?? _character.name ?? l10n.companionDefaultName;

  /// Introducing herself, by the name she goes by (if she has one).
  String _firstHello(L10n l10n) => switch (ref.read(companionNameProvider) ?? _character.name) {
    final name? => l10n.companionGreetFirst(name),
    null => l10n.companionGreetFirstNameless,
  };

  /// A model that still needs judgement gets fitted once, on its own, with
  /// the person's model; after that only when they ask (menu).
  void _onProbe(CompanionProbe probe) {
    // An offer for the model she had before goes with it.
    if (_adaptOffer != null && _adaptOffer!.moc != probe.moc) setState(() => _adaptOffer = null);
    _probe = probe;
    if (probe.adapted) unawaited(_checkAdapter(probe));
    if (_adapting || companionAdaptWanted(probe).isEmpty) return;
    unawaited(_autoAdapt(probe));
  }

  Future<void> _autoAdapt(CompanionProbe probe) async {
    final store = _store;
    if (store == null || !await companionAdaptAuto()) return;
    // Nothing to ask with: the menu says how to get it.
    if (ref.read(settingsProvider).apiKey.trim().isEmpty) return;
    final fingerprint = await companionMocFingerprint(store.pack, probe) ?? probe.moc;
    if (await companionAdaptTried(fingerprint)) return;
    // Nothing goes out on its own until the person has said yes once.
    if (!await companionAdaptConsented()) {
      if (mounted && _probe == probe) setState(() => _adaptOffer = probe);
      return;
    }
    await companionAdaptMarkTried(fingerprint);
    if (!mounted || _probe != probe) return;
    await _adapt();
  }

  /// The adapter she wears says which model it was written for (its moc3
  /// fingerprint): one written for another model is taken off, and this one
  /// is looked at afresh.
  Future<void> _checkAdapter(CompanionProbe probe) async {
    final store = _store;
    if (store == null) return;
    final adapter = await companionAdapterRead(store.pack);
    final meant = adapter?['moc'];
    if (meant is! String || meant.isEmpty) return;
    final actual = await companionMocFingerprint(store.pack, probe);
    if (actual == null || actual == meant || !mounted || _probe != probe) return;
    await companionAdapterRemove(store.pack);
    if (mounted) _stage.command('adapter');
  }

  Future<void> _answerAdaptOffer({required bool yes}) async {
    final probe = _adaptOffer;
    final store = _store;
    if (probe == null || store == null) return;
    _acted();
    setState(() => _adaptOffer = null);
    await companionAdaptMarkTried(await companionMocFingerprint(store.pack, probe) ?? probe.moc);
    if (!yes) return;
    await companionAdaptSetConsented(true);
    if (mounted && _probe == probe) await _adapt();
  }

  /// Asks her own AI for an adapter, checks it, and she wears it at once.
  /// [note]: what the person said is off, for another go.
  Future<void> _adapt({String? note}) async {
    final store = _store;
    final probe = _probe;
    if (store == null || probe == null || _adapting) return;
    final l10n = context.l10n;
    final key = ref.read(settingsProvider).apiKey.trim();
    if (key.isEmpty) {
      _say(l10n.companionAdaptNoKey);
      return;
    }
    setState(() => _adapting = true);
    _say(l10n.companionAdaptStart);
    _stage.command('mood', {'mood': 'thinking'});
    final client = ref.read(companionLightClientProvider)();
    try {
      final adapter = await companionAdaptAsk(
        client: client,
        apiKey: key,
        probe: probe,
        note: note,
        current: probe.adapted ? await companionAdapterRead(store.pack) : null,
        onUsage: (usage) {
          final input = usage.reportedInputTokens;
          if (mounted && (input != null || usage.outputTokens != null)) {
            // Add only reported components; zero here means no telemetry
            // increment. The usage receipt retains unknown fields as null.
            ref.read(usageStatsProvider.notifier).tokens(input ?? 0, usage.outputTokens ?? 0);
          }
        },
        onUsageSettled: (usage, {required partial}) {
          if (mounted) {
            ref.read(usageStatsProvider.notifier).tokenUsage(UsageTokenSource.companion, usage, partial: partial);
          }
        },
      );
      await companionAdapterWrite(store.pack, probe, adapter);
      if (!mounted) return;
      _stage.command('adapter');
      _stage.command('mood', {'mood': 'idle'});
      _stage.command('emotion', {'name': 'happy', 'hold': 3200});
      _stage.command('action', {'name': 'hop'});
      final notes = adapter['notes'];
      _say(notes is String && notes.isNotEmpty ? l10n.companionAdaptDoneNote(notes) : l10n.companionAdaptDone);
    } on Object catch (error) {
      if (!mounted) return;
      _stage.command('mood', {'mood': 'idle'});
      _say(switch (error) {
        CompanionLightError(failure: CompanionLightFailure.noKey) => l10n.companionAdaptNoKey,
        CompanionLightError(failure: CompanionLightFailure.badKey) => l10n.companionLightBadKey,
        CompanionLightError(failure: CompanionLightFailure.busy) => l10n.companionLightBusy,
        CompanionAdaptError(reason: 'empty') => l10n.companionAdaptFailed(l10n.companionAdaptEmpty),
        CompanionAdaptError() => l10n.companionAdaptFailed(l10n.companionAdaptUnreadable),
        _ => l10n.companionAdaptFailed(l10n.companionAdaptNetwork),
      });
    } finally {
      client.close();
      if (mounted) setState(() => _adapting = false);
    }
  }

  Future<void> _undoAdapt() async {
    final store = _store;
    if (store == null) return;
    if (_probe case final probe?) {
      await companionAdaptMarkTried(await companionMocFingerprint(store.pack, probe) ?? probe.moc);
    }
    await companionAdapterRemove(store.pack);
    if (!mounted) return;
    _stage.command('adapter');
    _say(context.l10n.companionAdaptUndone);
  }

  void _openAdapt() {
    unawaited(
      showAppSheet<void>(
        context,
        isScrollControlled: true,
        builder: (sheet) => _AdaptSheet(
          adapted: _probe?.adapted ?? false,
          onRun: (note) {
            Navigator.of(sheet).pop();
            setState(() => _adaptOffer = null);
            unawaited(companionAdaptSetConsented(true));
            unawaited(_adapt(note: note));
          },
          onUndo: () {
            Navigator.of(sheet).pop();
            unawaited(_undoAdapt());
          },
        ),
      ),
    );
  }

  Future<void> _onModel(CompanionModelInfo info) async {
    final epoch = ++_movesEpoch;
    final store = _store;
    final probe = _probe;
    final fingerprint = store == null || probe == null ? null : await companionMocFingerprint(store.pack, probe);
    final key = fingerprint == null ? (_character.name ?? 'default') : 'moc:$fingerprint';
    final saved = await companionMovesSaved(key);
    if (!mounted || epoch != _movesEpoch) return;
    _movesKey = key;
    setState(() {
      _moves = CompanionMoves.from(info, saved);
      _rebaseMarks();
    });
    _attachment.updateCharacter(_character, _moves, sourceKey: _characterSourceKey);
  }

  /// Her own moves just became known: marks already in the reply on screen
  /// that only now read as marks were said before, not news to play.
  void _rebaseMarks() {
    if (!_baselineSet) return;
    final text = _attachment.text;
    final reply = parseCompanionReply(
      text,
      streaming: _running,
      emotions: _moves.emotionLabels,
      actions: _moves.actionLabels,
    );
    _marksHandled = reply.marks.length;
  }

  void _changeMove(CompanionMove next) {
    setState(() => _moves = _moves.replaced(next));
    _attachment.updateCharacter(_character, _moves, sourceKey: _characterSourceKey);
    unawaited(companionMovesSave(_movesKey, _moves));
  }

  /// Renamed in 她的设定: back in the room, she answers to it.
  void _renamedTo(String name) {
    if (!mounted || !_stageReady) return;
    final l10n = context.l10n;
    _remember('renamed', '对方刚给你起了新名字「$name」');
    _stage.command('emotion', {'name': 'happy', 'hold': 3200});
    _stage.command('action', {'name': 'hop'});
    _say(l10n.companionRenamed(name));
  }

  /// Her model's own expressions and motions: try one on her, rename it, and
  /// say whether the AI may use it. A sheet, so she stays in view and plays them.
  void _openMoves() {
    unawaited(
      showAppSheet<void>(
        context,
        builder: (sheet) => StatefulBuilder(
          builder: (sheet, setSheet) {
            final l10n = sheet.l10n;
            void change(CompanionMove next) {
              _changeMove(next);
              setSheet(() {});
            }

            Widget row(CompanionMove move) => SettingsTile(
              tinted: false,
              title: move.label,
              subtitle: move.label == move.raw ? null : move.raw,
              chevron: false,
              onTap: () async {
                final label = await showAppDialog<String>(
                  context: sheet,
                  builder: (_) => _LabelDialog(initial: move.label, hint: companionMoveLabel(move.raw)),
                );
                if (label != null && label.trim().isNotEmpty) change(move.copyWith(label: label.trim()));
              },
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: l10n.companionMovesTry,
                    icon: const Icon(AppIcons.play, size: 20),
                    onPressed: () => move.kind == CompanionMoveKind.expression
                        ? _stage.command('emotion', {'name': move.raw, 'hold': 2600, 'native': true})
                        : _stage.command('action', {'name': move.raw, 'native': true}),
                  ),
                  Switch(
                    value: move.ai,
                    onChanged: (ai) => change(move.copyWith(ai: ai)),
                  ),
                ],
              ),
            );

            return SafeArea(
              top: false,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SheetTitleBar(l10n.companionMenuMoves),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 12),
                      child: Text(
                        _moves.isEmpty ? l10n.companionMovesNone : l10n.companionMovesHint,
                        style: Theme.of(sheet).textTheme.bodySmall,
                      ),
                    ),
                    if (_moves.expressions.isNotEmpty)
                      SheetGroup(
                        margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                        children: [for (final move in _moves.expressions) row(move)],
                      ),
                    if (_moves.motions.isNotEmpty)
                      SheetGroup(
                        margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                        children: [for (final move in _moves.motions) row(move)],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ── Voice ────────────────────────────────────────────────────────────────

  /// On a call the call reads her words; the room itself stays quiet.
  bool get _voiceOn => _call == null && _ttsReady && (ref.read(companionEffectiveVoiceProvider)?.on ?? false);

  /// Ready to speak with [settings] (or silent when they are off).
  Future<void> _prepareVoice(CompanionVoiceSettings settings) async {
    final current = _currentRoom();
    if (!current()) return;
    if (!settings.on) {
      _ttsReady = false;
      _hush();
      return;
    }
    final previous = _ttsSource;
    _ttsSource = settings.source;
    final preparing = _speaker.ready(settings);
    // ready's source setter already stops the old queue. Retire this page's
    // IDs too, including fetched lines that never reached the native player.
    if (previous != null && previous != settings.source && _ttsPending.isNotEmpty) {
      _ttsPending.clear();
      _stage.command('quiet');
    }
    final ready = await preparing;
    if (current()) _ttsReady = ready;
  }

  /// Reads [text] aloud when her voice is on; false when it isn't (then her
  /// mouth keeps the text's rhythm). [flush] replaces whatever she is saying.
  bool _speakAloud(String text, {bool flush = false}) {
    if (!_attachment.isAttached || !_voiceOn || text.trim().isEmpty) return false;
    if (flush) _ttsPending.clear();
    // Native completion can follow the old window's stop after a new window
    // speaks. Reuse the room identity so its receipt cannot consume our ID.
    final parts = _ttsSource == CompanionVoiceSource.system ? companionSystemSpeechParts(text) : [text];
    var replace = flush;
    for (final part in parts) {
      final id = 'v$_page-${++_ttsSerial}';
      _ttsPending[id] = part.length;
      _speaker.speak(id, part, flush: replace);
      replace = false;
    }
    return true;
  }

  /// While she works on the phone, the person stopping it from the island or
  /// pill (the room is often behind another app then) stops her voice too.
  void _watchPhoneStops(bool onPhone) {
    if (onPhone) {
      _phoneStops ??= companionPhoneUserStops(ref.read(phoneChannelProvider).statusChanges).listen((_) => _hush());
    } else if (_phoneStops != null) {
      unawaited(_phoneStops!.cancel());
      _phoneStops = null;
    }
  }

  /// She stops talking at once: the person is typing, talking, stopping her or leaving.
  void _hush() {
    if (_ttsPending.isEmpty) return;
    _ttsPending.clear();
    _speaker.stop();
    _stage.command('quiet');
  }

  void _onTts(CompanionVoiceEvent event) {
    if (!mounted || !_attachment.isAttached || !_ttsPending.containsKey(event.id)) return;
    switch (event.type) {
      case CompanionVoiceEventType.start:
        final external = ref.read(companionEffectiveVoiceProvider)?.source != CompanionVoiceSource.system;
        if (event.loudness case final levels?) {
          // Fetched WAV: her mouth opens with the voice's own loudness.
          _stage.command('loudness', {'levels': levels, 'frameMs': 40});
        } else if (!_ttsRanges || external) {
          // Engines that don't say what they're reading: the whole line's rhythm.
          _stage.command('say', {'chars': _ttsPending[event.id]});
        }
      case CompanionVoiceEventType.fallback:
        // Once per visit: the external voice didn't answer, the phone's stood in.
        if (_fallbackNoted) return;
        _fallbackNoted = true;
        _voiceNoticeTimer?.cancel();
        setState(() => _voiceNotice = context.l10n.companionVoiceFallback);
        _voiceNoticeTimer = Timer(const Duration(seconds: 6), () {
          if (mounted) setState(() => _voiceNotice = null);
        });
      case CompanionVoiceEventType.range:
        _ttsRanges = true;
        _stage.command('say', {'chars': max(1, (event.end ?? 0) - (event.start ?? 0))});
      case CompanionVoiceEventType.done || CompanionVoiceEventType.stopped || CompanionVoiceEventType.error:
        setState(() => _ttsPending.remove(event.id));
    }
  }

  void _showBubble(String text, {Duration? hold, bool error = false, bool clearTasks = true, String? replyId}) {
    _retireGreeting();
    _bubbleTimer?.cancel();
    _memoryFollowupTicket = null;
    setState(() {
      // AnimatedSwitcher can still retain the outgoing words while a new
      // bubble arrives. Never give those two Text elements the same GlobalKey.
      if (_bubble == null) _bubbleTextKey = GlobalKey();
      _bubble = text;
      _bubbleReplyId = replyId;
      _bubbleIsError = error;
      if (clearTasks) {
        _lookupResults = const [];
        _notesResults = const [];
        _mapResults = const [];
      }
    });
    if (hold != null) {
      _bubbleTimer = Timer(hold, () {
        // The owner still owns any pending speech until its ticket ends.
        if (mounted) setState(() => _bubble = null);
      });
    }
  }

  // ── Mood ─────────────────────────────────────────────────────────────────

  void _refreshMood() {
    if (_running || _sending) return;
    _stage.command('mood', {'mood': _focus.hasFocus || _voice.active ? 'listening' : 'idle'});
    if (mounted) setState(() {});
  }

  void _voiceChanged() {
    if (!mounted) return;
    setState(() {});
    _refreshMood();
  }

  /// Text changes tell only the initiative gate; the composer rebuilds itself (companion_chrome.dart).
  void _inputChanged() {
    if (mounted) _queueObserve();
  }

  CompanionActivity get _activity {
    if (_asleep) return CompanionActivity.sleeping;
    if (_sending || (_running && _bubble == null)) return CompanionActivity.thinking;
    if (_running) return CompanionActivity.speaking;
    if (_focus.hasFocus || _voice.active) return CompanionActivity.listening;
    return switch (_home) {
      'snack' => CompanionActivity.snacking,
      'play' => CompanionActivity.playing,
      'rest' => CompanionActivity.resting,
      _ => CompanionActivity.idle,
    };
  }

  // ── Invitations (Pro C451/C452) ──────────────────────────────────────────

  /// This page, this mode and binding, this view of her. A change retires
  /// whatever was shown for the one before (C452 §3).
  String get _initiativeContext => '$_page/${_boundLight ? 'light' : 'full'}/$_bindingEpoch/$_stageEpoch';

  /// Everything that decides whether she may ask now. Anything unsure blocks.
  CompanionInitiativeView _initiativeView() => CompanionInitiativeView.room(
    routeVisible: _routeShown,
    stageReady: _stageReady && _phase == _Phase.stage,
    resumed: WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    // While she voices a memory follow-up, the keyboard coming up must not
    // withdraw it; nothing new is offered while it is shown anyway.
    inputBusy: _memoryFollowupTicket == null && (_focus.hasFocus || _input.text.trim().isNotEmpty),
    generating: _sending || _running || (_agent.running && _attachment.preparingSignalId == null),
    // Her mouth still settling counts: the words may still be on their way out.
    audioBusy:
        _voice.active || (_settleTimer?.isActive ?? false) || (_ttsPending.isNotEmpty && _memoryFollowupTicket == null),
    activityBusy: _home != 'idle' || _asleep || (_objectTimer?.isActive ?? false),
    approvalPending: _needsAttention,
    // The "take a look" pill is not here: it comes with the very signal she may
    // mention, and would drop it. It still keeps invitations away (canPresent).
    externalPromptBusy:
        (_bubble != null && _memoryFollowupTicket == null) || _myLine != null || _logOpen || _adaptOffer != null,
    quietHoursBlocked: false,
    enabled: ref.read(companionInitiativeEnabledProvider) ?? false,
    accessible: _accessible,
    contextKey: _initiativeContext,
  );

  bool _presentable(CompanionInitiativeView view) => view.visible && view.resumed && !view.blocked && view.enabled;

  /// After this frame: the owner hears what the page now looks like.
  void _queueObserve() {
    if (_observeQueued) return;
    _observeQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _observeQueued = false;
      _observeInitiative();
    });
  }

  void _observeInitiative() {
    if (!mounted || _leaving || !_attachment.isAttached) return;
    _attachment.observe(_initiativeView());
  }

  void _hideMemoryFollowup(String ticketId) {
    if (_memoryFollowupTicket != ticketId) return;
    _memoryFollowupTicket = null;
    _bubbleTimer?.cancel();
    _hush();
    _stage.command('quiet');
    if (mounted) setState(() => _bubble = null);
  }

  /// Something the person really did here: no invitation this visit.
  void _acted() {
    // A failed preparation may try again after a real new interaction, never
    // once per idle tick while the same room opportunity stays unchanged.
    _attachment.acted();
    _observeLateUse(interaction: true);
  }

  @override
  bool canPresent(CompanionInitiativeTicket ticket) {
    final preparing = _attachment.preparingSignalId;
    final ownPreparation =
        preparing != null && ticket.kind == CompanionPromptKind.signal && ticket.signalId == preparing;
    return mounted &&
        !_leaving &&
        // She greets in her own words when the person arrives; only invitations
        // and signal lines come here.
        ticket.kind != CompanionPromptKind.greeting &&
        // No invitation while the pill to another conversation is up.
        (ticket.kind != CompanionPromptKind.invite || _agentPill == null) &&
        ticket.contextKey == _initiativeContext &&
        (!_agent.running || ownPreparation) &&
        _presentable(_initiativeView());
  }

  @override
  void show(CompanionInitiativeDisplay display) {
    if (!mounted || _leaving) return;
    setState(() {
      _invite = display;
      _inviteEnds = display.expiresAtMono;
      _inviteOpen = display.ticket.id;
    });
    // She looks over at the cushion, and a few bubbles rise from it. No words.
    _stage.command('glance', {'prop': 'rest', 'ms': 1800});
    _stage.command('beckon', {'prop': 'rest'});
  }

  @override
  void hide(String ticketId) {
    if (!mounted || _leaving || _invite?.ticket.id != ticketId) return;
    setState(() => _invite = null);
    _stage.command('beckon', {'prop': null});
  }

  @override
  void retime(String ticketId, int? expiresAtMono) {
    if (!mounted || _leaving || _invite?.ticket.id != ticketId) return;
    setState(() => _inviteEnds = expiresAtMono);
  }

  @override
  void rest(CompanionInitiativeEffect intent) {
    // Only the invitation this page showed, in the room it showed it in, once.
    if (!mounted || _leaving || intent.ticketId != _inviteOpen || intent.contextKey != _initiativeContext) return;
    _inviteOpen = null;
    // The cushion gives under her as if tapped; what lasts is the rest itself.
    _stage.command('prop', {'name': 'rest'});
    _useObject('rest', invited: true);
  }

  void _answerInvite({required bool yes}) {
    final invite = _invite;
    if (invite == null) return;
    final view = _initiativeView();
    final id = invite.ticket.id;
    if (yes) {
      _initiative.accept(this, id, view);
    } else if (_initiative.decline(this, id, view) && mounted) {
      // Fine by her: a small nod, nothing said.
      _stage.command('action', {'name': 'nodSmall'});
    }
  }

  // ── Talking ──────────────────────────────────────────────────────────────

  /// Work belongs to this visit to this host and client, even after A→B→A.
  bool Function() _currentRoom() => _attachment.captureCurrent();

  /// Her lines written in her own voice, for this character and persona.
  CompanionLines? _ownLines;
  String? _ownLinesFor;

  /// Whether she is the app's own whale girl as written, whose built-in lines
  /// (her apron, her tail, seaweed) are hers.
  bool get _ownWhale =>
      _characterSourceKey != null &&
      companionIsWhale(_characterSourceKey, _character.name) &&
      ref.read(companionPersonaProvider).custom.trim().isEmpty;

  /// What she says for [moment]: her pack's words, else her own written set,
  /// else the app's [fallback]. Asking also starts finding her own set.
  List<String> _linesFor(String moment, List<String> fallback) {
    final own = _character.lines?[moment];
    if (own != null) return own;
    if (_ownWhale) return fallback;
    unawaited(_refreshLines());
    return _ownLines?[moment] ?? fallback;
  }

  /// One of [lines], not the one she just said unless it is all she has.
  String _pick(List<String> lines) {
    final fresh = lines.where((l) => l != _lastLine).toList();
    final choices = fresh.isEmpty ? lines : fresh;
    return _lastLine = choices[_random.nextInt(choices.length)];
  }

  /// Her own lines kept for the current character and persona, if written.
  /// A pack that brings lines needs none.
  Future<void> _refreshLines() async {
    if (_character.lines != null) return;
    final (:character, :fingerprint, :key) = _linesKey();
    if (_ownLinesFor == key) return;
    _ownLinesFor = key;
    _ownLines = null;
    final cached = await companionLinesCached(character, fingerprint);
    if (mounted && _ownLinesFor == key) _ownLines = cached;
  }

  ({String character, String fingerprint, String key}) _linesKey() {
    final persona = ref.read(companionPersonaProvider);
    final name = ref.read(companionNameProvider) ?? _character.name;
    final character = _characterSourceKey ?? name ?? '';
    final fingerprint = '${persona.fingerprint}:${name ?? ''}:${context.l10n.localeName}';
    return (character: character, fingerprint: fingerprint, key: '$character|$fingerprint');
  }

  /// Once she is someone new (another character moved in, her persona or name
  /// changed): her own set, written with the person's key unless one is kept.
  Future<void> _writeLines() async {
    if (!mounted || _character.lines != null || _ownWhale) return;
    final (:character, :fingerprint, :key) = _linesKey();
    final cached = await companionLinesCached(character, fingerprint);
    if (!mounted) return;
    if (cached != null) {
      _ownLinesFor = key;
      _ownLines = cached;
      return;
    }
    final persona = ref.read(companionPersonaProvider);
    final name = ref.read(companionNameProvider) ?? _character.name;
    final locale = context.l10n.localeName;
    final apiKey = ref.read(settingsProvider).apiKey.trim();
    if (apiKey.isEmpty) return;
    final client = ref.read(companionLightClientProvider)();
    try {
      final written = await companionLinesWrite(
        client: client,
        apiKey: apiKey,
        character: character,
        fingerprint: fingerprint,
        persona: companionPersonaPart(
          custom: persona.custom,
          name: name,
          callMe: persona.callMe,
          whale: companionIsWhale(_characterSourceKey, _character.name),
        ),
        language: locale.startsWith('zh') ? 'zh' : 'en',
      );
      if (mounted && written != null && _linesKey().key == key) {
        _ownLinesFor = key;
        _ownLines = written;
      }
    } on Object {
      // The app's lines stand in; the next change tries again.
    } finally {
      client.close();
    }
  }

  void _setCharacter(CompanionCharacter character, String? sourceKey) {
    // Another character moved in: her name and persona come with her, the
    // last one's are kept for when she's back.
    if (sourceKey != null && sourceKey != _characterSourceKey) {
      unawaited(
        companionAdoptIdentity(ref, sourceKey).then((swapped) {
          if (swapped) unawaited(_writeLines());
        }),
      );
    }
    if (_characterSourceKey != sourceKey) {
      _affinityCharacter = null;
      _affinitySettledDay = null;
      _bondTier = 0;
      _resetConversation();
    }
    if (_character.name != character.name) ref.invalidate(companionPackNameProvider);
    final changed = _characterSourceKey != sourceKey;
    if (changed || _character.name != character.name) {
      _ownLines = null;
      _ownLinesFor = null;
    }
    _character = character;
    _characterSourceKey = sourceKey;
    if (changed && _rosterWanted) scheduleMicrotask(() => unawaited(_loadRoster()));
  }

  /// Everyone on this phone: her in the room first, then the others. Read
  /// once her page or panel is open, not before: reading holds the pack store.
  List<CompanionRosterEntry> _roster = const [];
  bool _rosterWanted = false;
  int _rosterLoads = 0;

  Future<void> _loadRoster() async {
    final store = _store;
    if (store == null) return;
    try {
      final roster = await store.roster();
      // A cover's path stays the same when another moves in or she's updated,
      // so each roster decodes its covers afresh, in rows made anew.
      for (final CompanionRosterEntry(:cover) in roster) {
        if (cover != null) unawaited(companionRosterCover(cover).evict());
      }
      if (mounted) {
        setState(() {
          _roster = roster;
          _rosterLoads++;
        });
      }
    } on Object {
      // Shown again on the next change.
    }
  }

  /// Brings [entry] into the room; whoever was here goes on the shelf.
  Future<void> _switchTo(CompanionRosterEntry entry) async {
    final store = _store;
    if (store == null || _installing || entry.active) return;
    _hush();
    if (_voice.active || _voice.cancelling) await _voice.cancel();
    if (!mounted) return;
    setState(() {
      _installing = true;
      _installError = null;
      _stageReady = false;
    });
    try {
      await store.activate(entry.key);
      final identity = await store.characterIdentity();
      if (!mounted) return;
      setState(() {
        _setCharacter(identity.character, identity.key);
        _failure = null;
        _stageRun++;
        _phase = _Phase.stage;
      });
      _attachment.updateCharacter(_character, _moves, sourceKey: _characterSourceKey);
      if (widget.sections) _selectTab(_CompanionTab.room);
    } on CompanionPackException catch (error) {
      if (mounted) _notice(_problemText(error.problem));
    } on Object {
      if (mounted) _notice(context.l10n.companionPackStorage);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  /// One of the others, off the phone (asked first: her files go with her).
  Future<void> _removeShelved(CompanionRosterEntry entry) async {
    final l10n = context.l10n;
    final name = entry.character.name ?? l10n.companionDefaultName;
    final ok = await _confirm(l10n.companionRosterRemove, l10n.companionRosterRemoveConfirm(name));
    if (!ok || !mounted) return;
    try {
      await _store?.removeShelved(entry.key);
      unawaited(companionForgetIdentity(ref, entry.key));
    } on Object {
      if (mounted) _notice(l10n.companionPackStorage);
    }
    await _loadRoster();
  }

  /// What can be done with [entry] from her row.
  Future<void> _rosterMore(CompanionRosterEntry entry) async {
    final l10n = context.l10n;
    final choice = await showAppSheet<String>(
      context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!entry.active)
              SettingsTile(
                icon: AppIcons.home,
                tinted: false,
                title: l10n.companionRosterBring,
                onTap: () => Navigator.pop(sheet, 'bring'),
              ),
            SettingsTile(
              icon: AppIcons.delete,
              tinted: false,
              danger: true,
              title: entry.active ? l10n.companionMenuRemovePack : l10n.companionRosterRemove,
              onTap: () => Navigator.pop(sheet, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'bring':
        await _switchTo(entry);
      case 'remove' when entry.active:
        await _removePack();
      case 'remove':
        await _removeShelved(entry);
    }
  }

  /// Another companion: from a file, or from 创意工坊.
  Future<void> _addCompanion() async {
    final l10n = context.l10n;
    final workshop = ref.read(workshopAvailableProvider);
    final choice = await showAppSheet<String>(
      context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SettingsTile(
              icon: AppIcons.folder,
              tinted: false,
              title: l10n.companionSetupImport,
              onTap: () => Navigator.pop(sheet, 'file'),
            ),
            if (workshop)
              SettingsTile(
                icon: AppIcons.workshop,
                tinted: false,
                title: l10n.companionSetupWorkshop,
                onTap: () => Navigator.pop(sheet, 'workshop'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'file':
        await _import();
        if (mounted && widget.sections) _selectTab(_CompanionTab.room);
      case 'workshop':
        ref.read(workshopCatalogProvider.notifier).setKind(WorkshopKindFilter.companion);
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WorkshopScreen()));
        await _afterRosterWorkshop();
    }
  }

  /// Back from 创意工坊: whoever it put in the room moves in.
  Future<void> _afterRosterWorkshop() async {
    final store = _store;
    if (store == null || !mounted) return;
    final identity = await store.characterIdentity();
    if (!mounted) return;
    if (identity.key != _characterSourceKey) {
      setState(() {
        _setCharacter(identity.character, identity.key);
        _failure = null;
        _stageReady = false;
        _stageRun++;
        _phase = _Phase.stage;
      });
      _attachment.updateCharacter(_character, _moves, sourceKey: _characterSourceKey);
      if (widget.sections) _selectTab(_CompanionTab.room);
    } else {
      await _loadRoster();
      // The same character updated: her stage was stopped for it.
      await _afterWorkshop();
    }
  }

  void _resetConversation() {
    _mapHandoff.close();
    _bindingEpoch++;
    _greetingPending = true;
    _hush();
    // A stop of the old room's phone work must not silence the new one.
    _watchPhoneStops(false);
    if (_voice.active) unawaited(_voice.cancel());
    _bubbleTimer?.cancel();
    _settleTimer?.cancel();
    _objectTimer?.cancel();
    _vitals = null;
    _sending = false;
    _running = false;
    _needsAttention = false;
    _baselineSet = false;
    _replyStream = null;
    _marksHandled = 0;
    _wordsSpoken = 0;
    _replyWords = '';
    _bubble = null;
    _memoryFollowupTicket = null;
    _myLine = null;
    _home = 'idle';
    _asleep = false;
    _stage.command('quiet');
    _stage.command('activity', {'name': 'idle', 'remainingMs': 0});
    _stage.command('vitals', {'valence': 0.25, 'energy': 0.75, 'closeness': _stageCloseness});
    _refreshMood();
    // A new room for the gate: what the old one let in goes with it.
    _syncSignals();
  }

  /// The current text owns the subtitle, even when a failed attempt is
  /// replaced by fewer words. Fresh progress also permits a later identical line.
  void _showReplyWords(String words, int fresh) {
    if (fresh <= 0 && words == _replyWords) return;
    _replyWords = words;
    if (words.isEmpty) {
      _bubbleTimer?.cancel();
      _bubble = null;
      _bubbleIsError = false;
    } else {
      _myLine = null;
      _showBubble(words, clearTasks: false, replyId: _baselineUser);
    }
  }

  /// Her reply so far to the person's latest line [user] (any key that changes
  /// with each line), in either mode: marks once each, words into the bubble
  /// and her mouth, the mood while it runs and after.
  void _onReply(
    String? user,
    String text, {
    required bool running,
    bool attention = false,
    String? error,
    bool loading = false,
  }) {
    final steps = _attachment.phoneSteps;
    if (!_baselineSet) {
      // What's already in the conversation has been said; only news moves her.
      if (loading) return;
      _baselineSet = true;
      _baselineUser = user;
      final old = parseCompanionReply(text, emotions: _moves.emotionLabels, actions: _moves.actionLabels);
      _marksHandled = old.marks.length;
      _wordsSpoken = old.words.length;
      _spokenPrefix = old.words;
      _phoneSteps = steps;
      _replyWords = old.words;
      if (!running) {
        setState(() => _needsAttention = attention);
        return;
      }
    }

    if (user != _baselineUser) {
      _retireGreeting();
      _baselineUser = user;
      _marksHandled = 0;
      _wordsSpoken = 0;
      _spokenPrefix = '';
      _phoneSteps = 0;
    }
    // She starts a phone step: what she said before it is a whole line.
    final stepped = steps > _phoneSteps;
    _phoneSteps = steps;
    _watchPhoneStops(running && steps > 0);

    var stream = _replyStream;
    // A retry gets a new replyId, even for the same user line.
    if (stream == null || stream.user != user || !identical(stream.moves, _moves)) {
      stream = _replyStream = (
        user: user,
        moves: _moves,
        reader: CompanionReplyStream(emotions: _moves.emotionLabels, actions: _moves.actionLabels),
      );
    }
    final reply = stream.reader.read(text, streaming: running);
    // Behind her panel only the subtitle changes while this same request
    // extends already visible words. Phone words keep both history actions
    // available, and a phone tool round with a prefix takes the normal path.
    // The Host joins its tool steps into one growing reply; behind it the
    // panel catches up when the turn ends.
    final subtitleOnly = _tab == _CompanionTab.her &&
        running && _running && attention == _needsAttention && _bubble != null && _bubbleReplyId == user &&
        (identical(text, _attachment.pendingText) || _agent.hasSessionReply) &&
        text.length > (_lastReply?.text.length ?? 0) &&
        reply.words.isNotEmpty && reply.words != _bubble;
    _lastReply = (text: text, streaming: running, reply: reply);
    for (final mark in reply.marks.skip(_marksHandled)) {
      _retireGreeting();
      switch (mark.kind) {
        case CompanionMarkKind.emotion:
          _stage.command('emotion', {'name': mark.name, if (mark.native) 'native': true});
        case CompanionMarkKind.action:
          _stage.command('action', {'name': mark.name, if (mark.native) 'native': true});
      }
    }
    _marksHandled = reply.marks.length;
    if (_call case final call? when user != _callBaseline) call.reply(reply.words, running: running);

    final fresh = reply.words.length - _wordsSpoken;
    final aloud = _voiceOn && error == null;
    if (fresh > 0) {
      // Read aloud, her mouth follows the voice instead of the text.
      if (!aloud) _stage.command('say', {'chars': fresh});
      if (companionSentenceEnd.hasMatch(reply.words.substring(_wordsSpoken))) _stage.command('beat');
    }
    _wordsSpoken = reply.words.length;
    if (aloud) {
      // A durable Session message can correct a sentence already queued for
      // speech. Retire that voice and its callbacks before reading the correction.
      if (!reply.words.startsWith(_spokenPrefix)) {
        _hush();
        _spokenPrefix = '';
      }
      // Whole sentences as they complete, the rest once she acts on the phone
      // or the reply is in.
      final (sentences, to) = companionSpeakable(reply.words, _spokenPrefix.length, final_: !running || stepped);
      if (to != _spokenPrefix.length) _spokenPrefix = reply.words.substring(0, to);
      // On the phone her next line can come before the last is out: rather
      // than fall behind what she is doing, she goes on with the newest.
      if (sentences.isNotEmpty) _speakAloud(sentences, flush: steps > 0 && _ttsPending.length > 1);
    }
    if (subtitleOnly) {
      _bubble = _replyWords = reply.words;
    } else {
      _showReplyWords(reply.words, fresh);
    }

    if (running) {
      _retireGreeting();
      _settleTimer?.cancel();
      _stage.command('mood', {'mood': reply.words.isEmpty ? 'thinking' : 'speaking'});
    } else if (_running) {
      // Her mouth keeps going for a moment after the text is in.
      _settleTimer?.cancel();
      _settleTimer = Timer(Duration(milliseconds: min(4000, 600 + max(fresh, 0) * 90)), _refreshMood);
      _myLine = null;
      if (error != null) {
        _showBubble(error, hold: const Duration(seconds: 6), error: true, clearTasks: false);
      } else if (reply.words.isNotEmpty) {
        if (!_replyClearedWidget) {
          _widgetUpdate(line: reply.words.length > 80 ? '${reply.words.substring(0, 79)}…' : reply.words);
        }
        _bubbleTimer?.cancel();
        _bubbleTimer = Timer(Duration(milliseconds: 9000 + reply.words.length * 60), () {
          if (mounted) setState(() => _bubble = null);
        });
      }
    }

    if (!subtitleOnly) {
      setState(() {
        _running = running;
        _needsAttention = attention;
      });
    }
  }

  /// Capture the reply rendered by this frame. Returning to this room can
  /// show words whose Agent notifications all finished while it was hidden.
  void _queueReplyPresentation() {
    final attachment = _attachment;
    final user = attachment.replyId;
    final text = attachment.text;
    if (!attachment.isAttached || user == null || _baselineUser != user || attachment.error != null) return;
    final running = attachment.running;
    final last = _lastReply;
    // Every build and every frame of the bubble's rise lands here; the words
    // and their offsets do not depend on the mark labels.
    final reply = last != null && last.streaming == running && last.text == text
        ? last.reply
        : parseCompanionReply(text, streaming: running);
    if (reply.words.isEmpty || _bubbleReplyId != user || _bubbleIsError || _bubble != reply.words) return;
    final current = attachment.captureCurrent();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          current() &&
          identical(_attachment, attachment) &&
          _notesForegroundHere &&
          _phase == _Phase.stage &&
          _stageReady &&
          _baselineUser == user &&
          _bubbleReplyId == user &&
          attachment.error == null &&
          !_bubbleIsError &&
          _bubble == reply.words) {
        final sources = _visibleReplySources(attachment, reply);
        if (sources.isNotEmpty) attachment.presentedReply(user, text, sourceIds: sources);
      }
    });
    // Scroll metrics may arrive after a frame, without an Agent notification.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Set<String> _visibleReplySources(CompanionAgentAttachment attachment, CompanionReply reply) {
    final pending = attachment.pendingReplyRanges;
    if (pending.isEmpty) return const {};
    final textObject = _bubbleTextKey.currentContext?.findRenderObject();
    if (textObject == null || !textObject.attached) return const {};
    RenderParagraph? findParagraph(RenderObject object) {
      if (object is RenderParagraph) return object;
      RenderParagraph? found;
      object.visitChildren((child) {
        found ??= findParagraph(child);
      });
      return found;
    }

    // Text may have a selection/semantics wrapper. Search only that Text's
    // render subtree, never another bubble or another page's paragraph.
    final paragraph = findParagraph(textObject);
    if (paragraph == null ||
        !paragraph.attached ||
        !paragraph.hasSize ||
        paragraph.size.isEmpty ||
        paragraph.text.toPlainText() != reply.words) {
      return const {};
    }
    final RenderBox viewport;
    switch (RenderAbstractViewport.maybeOf(paragraph)) {
      case final RenderBox box when box.attached && box.hasSize && !box.size.isEmpty:
        viewport = box;
      default:
        return const {};
    }
    var visible = MatrixUtils.transformRect(
      viewport.getTransformTo(null),
      Offset.zero & viewport.size,
    ).intersect(Offset.zero & MediaQuery.sizeOf(context));
    RenderObject child = paragraph;
    for (var parent = child.parent; parent != null; parent = child.parent) {
      // A nonzero transform does not prove that an offstage/zero-opacity child
      // was painted. Respect the actual render parents before reading boxes.
      if (!parent.paintsChild(child)) return const {};
      if (parent is RenderAnimatedOpacity && Color.getAlphaFromOpacity(parent.opacity.value) == 0) return const {};
      final clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        visible = visible.intersect(MatrixUtils.transformRect(parent.getTransformTo(null), clip));
      }
      child = parent;
    }
    if (!visible.isFinite || visible.isEmpty) return const {};
    final transform = paragraph.getTransformTo(null);
    final sources = <String>{};
    for (final entry in pending.entries) {
      for (final range in reply.wordRangesFrom(entry.value.start, entry.value.end)) {
        final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: range.start, extentOffset: range.end));
        if (boxes.any((box) => !MatrixUtils.transformRect(transform, box.toRect()).intersect(visible).isEmpty)) {
          sources.add(entry.key);
          break;
        }
      }
    }
    return sources;
  }

  Future<void> _send() async {
    final raw = _input.text;
    if (raw.trim().isEmpty || _attachment.preparing || !_attachment.isAttached) return;
    final page = _assistantPage;
    final returnToApp = _assistantReturnToApp;
    _acted();
    _hush();
    _retireGreeting();
    if (_voice.active || _voice.cancelling) {
      final current = _currentRoom();
      await _voice.cancel();
      if (!mounted || !current() || _attachment.preparing) return;
    }
    _notesSelectionRoutes.clear();
    _bubbleTimer?.cancel();
    _objectTimer?.cancel();
    setState(() {
      _assistantPage = null;
      _assistantReturnToApp = false;
      _bubble = null;
      _myLine = raw.trim();
      _lookupResults = const [];
      _notesResults = const [];
      _mapResults = const [];
    });
    _stage.command('mood', {'mood': 'thinking'});
    await _attachment.submit(raw, assistantPage: page, returnToApp: returnToApp);
  }

  /// 语音通话 with her: the call page over the room, her as its backdrop,
  /// each thing said sent the way a typed line is.
  CompanionCallConversation? _call;
  String? _callBaseline;

  Future<void> _openCall() async {
    _acted();
    _hush();
    _objectTimer?.cancel();
    _focus.unfocus();
    if (_voice.active || _voice.cancelling) await _voice.cancel();
    if (!mounted) return;
    final call = _call = CompanionCallConversation((text) async {
      if (!mounted || _attachment.preparing || !_attachment.isAttached) return false;
      _callBaseline = _baselineUser;
      _retireGreeting();
      setState(() {
        _bubble = null;
        _myLine = text.trim();
      });
      _stage.command('mood', {'mood': 'thinking'});
      await _attachment.submit(text, voiceCall: true);
      return true;
    }, _stop,
        fullMode: () => mounted && !_light,
        session: () => mounted && !_light ? _sessionId : null,
        waitingForOwner: () => _attachment.waitingForOwner);
    await openVoiceCall(context, title: _name(context.l10n), conversation: call, backdrop: CallBackdrop.companion);
    if (identical(_call, call)) _call = null;
  }

  void _checkNotesSelectionRoute() {
    // Ordinary route widgets also report their observed current/ticker state.
    // Owned sheet/browser coverage is latched synchronously in selectionRoute;
    // this fallback is not proof of transitions with no intervening build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          (!TickerMode.valuesOf(context).enabled || !(ModalRoute.of(context)?.isCurrent ?? false)) &&
          !_notesSelectionRoutes.any((route) => route.isActive && route.isCurrent)) {
        _notesForegroundEpoch++;
      }
    });
  }

  bool get _notesForegroundHere =>
      mounted &&
      !_leaving &&
      !_logOpen &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? false);

  bool get _mapHere =>
      mounted &&
      !_leaving &&
      _routeShown &&
      !_logOpen &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  /// A word from the app (not from her) in the pill above her words.
  void _notice(String text) {
    if (!mounted) return;
    _voiceNoticeTimer?.cancel();
    setState(() => _voiceNotice = text);
    _voiceNoticeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _voiceNotice = null);
    });
  }

  String _failureText(Object error) {
    final l10n = context.l10n;
    final local = ref.read(activeHostProvider).isLocal;
    return switch (error) {
      CompanionHostError(hostFailure: CompanionHostFailure.deviceConflict, detail: 'companion/device-connection-replaced') =>
        l10n.companionPhoneConnectionReplaced,
      CompanionHostError(hostFailure: CompanionHostFailure.deviceConflict, detail: 'companion/device-session-unavailable') =>
        l10n.companionPhoneSessionUnavailable,
      CompanionHostError(hostFailure: CompanionHostFailure.deviceConflict) => l10n.companionPhoneToolsConflict,
      CompanionHostError(hostFailure: CompanionHostFailure.retryClosed) => l10n.companionAgentRetryClosed,
      CompanionHostError(hostFailure: CompanionHostFailure.selectionChanged) => l10n.companionHostSelectionChanged,
      CompanionHostError(hostFailure: CompanionHostFailure.disconnected) when local => l10n.companionLocalDisconnected,
      CompanionHostError(hostFailure: CompanionHostFailure.unavailable) when local => l10n.companionLocalUnavailable,
      CompanionHostError(hostFailure: CompanionHostFailure.modelUnavailable) when local => l10n.companionLocalModelUnavailable,
      CompanionHostError(hostFailure: CompanionHostFailure.disconnected) => l10n.companionNotConnectedTryLight,
      CompanionHostError(hostFailure: CompanionHostFailure.modelUnavailable) => l10n.companionHostModelUnavailable,
      CompanionHostError(hostFailure: CompanionHostFailure.unavailable) => l10n.companionHostUnavailable,
      CompanionLightError(failure: CompanionLightFailure.noKey) => l10n.companionLightNoKey,
      CompanionLightError(failure: CompanionLightFailure.badKey) => l10n.companionLightBadKey,
      CompanionLightError(failure: CompanionLightFailure.busy) => l10n.companionLightBusy,
      DshRemoteException(code: 'companion/agent-retry-closed') => l10n.companionAgentRetryClosed,
      DshRemoteException(code: 'companion/phone-run-stopped') => l10n.companionPhoneRunStopped,
      DshRemoteException(code: 'companion/cleanup-source-unknown') => l10n.companionMemoryCleanupUnknown,
      // Full mode only because nobody picked a mode yet: light would work without a host.
      DshClosedException() when ref.read(companionModeProvider) == null => l10n.companionNotConnectedTryLight,
      DshClosedException() => l10n.companionNotConnected,
      _ => l10n.companionSendFailed,
    };
  }

  Future<void> _stop() async {
    _acted();
    _hush();
    _attachment.stop();
  }

  /// The backlog over her: this room's whole conversation, in either mode.
  Future<void> _openLog({bool phone = false}) async {
    _notesForegroundEpoch++;
    _mapHandoff.close();
    _acted();
    if (_store != null) {
      final history = _lightHistory ??= CompanionLightHistory.at(_store!.root);
      await history.load();
    }
    if (!mounted) return;
    _focus.unfocus();
    setState(() {
      _phoneLog = phone;
      _logOpen = true;
    });
    // Under the log's blur she's barely seen: her stage draws slowly meanwhile.
    _stage.command('covered', {'on': true});
  }

  void _closeLog() {
    if (!mounted || !_logOpen) return;
    setState(() {
      _logOpen = false;
      _savedLightLog = null;
    });
    _stage.command('covered', {'on': false});
  }

  List<CompanionLogEntry> get _visibleLightEntries {
    List<CompanionLogEntry> read(List<CompanionLine> lines, {bool legacy = false, String? speaking}) => [
      for (final entry in companionLogFromLight(lines, speaking: speaking))
        if (legacy && entry.speaker == CompanionLogSpeaker.her)
          CompanionLogEntry.her(entry.text, who: context.l10n.companionLegacyConversation)
        else
          entry,
    ];
    List<CompanionLogEntry> saved() {
      final store = _memoryOwner?.store;
      if (store == null) return const [];
      final role = _attachment.characterId;
      List<CompanionLogEntry> project() => [
        for (final row in store.messages())
          if ((row['session_id']! as String).startsWith('light:') &&
              (row['character_id'] == null || row['character_id'] == role))
            ...read([
              row['role'] == 'user'
                  ? CompanionLine.user(row['text']! as String)
                  : CompanionLine.her(row['text']! as String),
            ], legacy: row['character_id'] == null),
      ];
      if (!_logOpen) return project();
      // New/edited messages advance next_seq. Forget can remove older messages
      // under an existing sequence and advances control_revision instead.
      final archive = store.archive;
      final key = (
        store,
        archive['next_seq']! as int,
        archive['control_revision']! as int,
        role,
        context.l10n.companionLegacyConversation,
      );
      final previous = _savedLightLog;
      if (previous != null && previous.key == key) return previous.entries;
      final entries = project();
      _savedLightLog = (key: key, entries: entries);
      return entries;
    }

    return [
      ...read(_lightHistory?.lines ?? const [], legacy: true),
      ...saved(),
      ...read(const [], speaking: _attachment.pendingText),
    ];
  }

  Widget _log(String name) {
    final id = _sessionId;
    if (!_phoneLog && !_light && id != null) {
      final chat = ref.watch(chatProvider(id));
      return CompanionLog(
        key: ValueKey('log-host:$id'),
        entries: companionLogFromChat(chat.items, emotions: _moves.emotionLabels, actions: _moves.actionLabels),
        name: name,
        onClose: _closeLog,
        onOpenChat: _openFullChat,
        onLoadOlder: chat.hasMoreHistory ? ref.read(chatProvider(id).notifier).loadOlder : null,
        loadingOlder: chat.loadingOlder,
        history: chat.items.length,
      );
    }
    return CompanionLog(
      key: const ValueKey('log-phone'),
      entries: _visibleLightEntries,
      name: name,
      onClose: _closeLog,
      onOpenChat: id == null ? null : _openFullChat,
    );
  }

  void _openFullChat() {
    final id = _sessionId;
    if (id == null) return;
    ref.read(currentSessionProvider.notifier).select(id);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  // ── Setup ────────────────────────────────────────────────────────────────

  /// A pack the person picks.
  Future<void> _import() => _installFrom((claim) async {
    final picked = await FilePicker.pickFile();
    if (picked == null) return null;
    // Picks may be content URIs: bring it somewhere the unzipper can seek.
    final temp = claim(
      '${(await getTemporaryDirectory()).path}/companion-import-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    final sink = temp.openWrite();
    try {
      await sink.addStream(picked.readAsByteStream());
    } finally {
      await sink.close();
    }
    return temp;
  });

  /// The pack inside the app, through the same checks as any other.
  /// [arriving]: the first time, she swims over while it unpacks.
  Future<void> _installBundled({bool arriving = false}) => _installFrom(
    (claim) async {
      final bytes = await _bundled();
      if (bytes == null) throw const CompanionPackException(CompanionPackProblem.notAPack);
      final zip = claim('${_store!.root.parent.path}/companion-bundled-${DateTime.now().microsecondsSinceEpoch}.zip');
      await zip.writeAsBytes(bytes, flush: true);
      return zip;
    },
    arriving: arriving,
    builtIn: true,
  );

  /// [bring] makes the zip to install, through `claim` for its temporary
  /// file: claimed before anything is written, so a write that fails halfway
  /// is cleaned up too (Pro C542).
  Future<void> _installFrom(
    Future<File?> Function(File Function(String path) claim) bring, {
    bool arriving = false,
    bool builtIn = false,
  }) async {
    final store = _store;
    if (store == null || _installing) return;
    setState(() {
      _installing = true;
      _arriving = arriving;
      _installError = null;
    });
    File? temp;
    try {
      final zip = await bring((path) => temp = File(path));
      if (zip == null) return;
      try {
        if (builtIn) {
          await store.installBundled(zip.path);
        } else {
          await store.install(zip.path);
        }
      } on CompanionPackException catch (error) {
        // A model on its own needs the runtime, which the pack inside the app
        // brings: unpack that first, then the model over it.
        final bundled = error.problem == CompanionPackProblem.noRuntime ? await _bundled() : null;
        if (bundled == null) rethrow;
        final runtime = File(
          '${store.root.parent.path}/companion-runtime-${DateTime.now().microsecondsSinceEpoch}.zip',
        );
        try {
          await runtime.writeAsBytes(bundled, flush: true);
          await store.installBundled(runtime.path);
        } finally {
          if (await runtime.exists()) await runtime.delete();
        }
        if (builtIn) {
          await store.installBundled(zip.path);
        } else {
          await store.install(zip.path);
        }
      }
      final identity = await store.characterIdentity();
      // She's back: the pack inside the app may come by itself again.
      unawaited(SharedPreferences.getInstance().then((p) => p.remove(_packRemovedKey)));
      if (!mounted) return;
      setState(() {
        _setCharacter(identity.character, identity.key);
        _failure = null;
        _stageReady = false;
        _stageRun++;
        _phase = _Phase.stage;
      });
      _attachment.updateCharacter(_character, _moves, sourceKey: _characterSourceKey);
    } on CompanionPackException catch (error) {
      if (mounted) setState(() => _installError = _problemText(error.problem));
    } on Object {
      if (mounted) setState(() => _installError = context.l10n.companionPackBroken);
    } finally {
      try {
        await temp?.delete();
      } on FileSystemException {
        // Temp folder; the system clears it.
      }
      if (mounted) {
        setState(() {
          _installing = false;
          _arriving = false;
        });
      }
    }
  }

  /// The stage failed: whether trying again makes sense is the pack's to say.
  Future<void> _checkRetry() async {
    final here = await _store?.installed() ?? false;
    if (mounted && _phase == _Phase.failed) setState(() => _failedWithPack = here);
  }

  /// 重试 on the failed screen: a new stage (the failed one left the tree), for
  /// whoever is in the pack now.
  Future<void> _retryStage() async {
    final store = _store;
    if (store == null) return;
    final identity = await store.characterIdentity();
    if (!mounted || _phase != _Phase.failed) return;
    setState(() {
      _setCharacter(identity.character, identity.key);
      _failure = null;
      _stageReady = false;
      _stageRun++;
      _phase = _Phase.stage;
    });
    _attachment.updateCharacter(_character, _moves, sourceKey: _characterSourceKey);
  }

  /// No companion yet: one from 创意工坊, opened on its companions. Whoever
  /// comes back installed moves straight in.
  Future<void> _workshopFromSetup() async {
    ref.read(workshopCatalogProvider.notifier).setKind(WorkshopKindFilter.companion);
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WorkshopScreen()));
    final store = _store;
    if (!mounted || _phase != _Phase.setup || store == null || !await store.installed()) return;
    final identity = await store.characterIdentity();
    if (!mounted || _phase != _Phase.setup) return;
    setState(() {
      _setCharacter(identity.character, identity.key);
      _failure = null;
      _installError = null;
      _stageReady = false;
      _stageRun++;
      _phase = _Phase.stage;
    });
    _attachment.updateCharacter(_character, _moves, sourceKey: _characterSourceKey);
  }

  /// Back from the workshop. A companion installed or uninstalled there
  /// changed the pack under her and the stage left: show whoever is in the
  /// pack now, or the setup screen when nobody is.
  Future<void> _afterWorkshop() async {
    if (!mounted || _phase != _Phase.failed || _failure != companionStagePackChanged) return;
    final here = await _store?.installed() ?? false;
    if (!mounted || _phase != _Phase.failed || _failure != companionStagePackChanged) return;
    if (here) {
      await _retryStage();
      return;
    }
    setState(() {
      _phase = _Phase.setup;
      _failure = null;
      _stageReady = false;
      _setCharacter(const CompanionCharacter(), null);
    });
    _attachment.updateCharacter(_character, _moves, sourceKey: _characterSourceKey);
    _syncSignals();
  }

  /// Why she couldn't load, in words: a model too new for the runtime says so.
  String _loadFailureText(L10n l10n) {
    final why = _failure ?? '';
    // The stage's own reasons for leaving are not the person's to read.
    if (why == companionStageRendererGone || why == companionStagePackChanged) return l10n.companionFailedBodyPlain;
    final version = RegExp(r'moc-version (\d+)/(\d+)').firstMatch(why);
    if (version != null) return l10n.companionFailedMocVersion(version[1]!, version[2]!);
    return l10n.companionFailedBody(why);
  }

  String _problemText(CompanionPackProblem problem) {
    final l10n = context.l10n;
    return switch (problem) {
      CompanionPackProblem.runtimeMismatch => l10n.companionPackRuntimeMismatch,
      CompanionPackProblem.noRuntime => l10n.companionPackNoRuntime,
      CompanionPackProblem.noModel => l10n.companionPackNoModel,
      CompanionPackProblem.legacyModel => l10n.companionPackLegacyModel,
      CompanionPackProblem.forbiddenFile || CompanionPackProblem.unsafePath => l10n.companionPackUnsafe,
      CompanionPackProblem.tooLarge => l10n.companionPackTooLarge,
      CompanionPackProblem.storage => l10n.companionPackStorage,
      CompanionPackProblem.notAPack => l10n.companionPackBroken,
    };
  }

  // ── Menu ─────────────────────────────────────────────────────────────────

  void _chooseMode() {
    final l10n = context.l10n;
    final light = _light;
    unawaited(
      showAppSheet<void>(
        context,
        builder: (sheet) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.companionMenuMode),
              SheetGroup(
                margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                children: [
                  for (final (mode, icon, title, hint) in [
                    (
                      CompanionMode.light,
                      AppIcons.engineStarting,
                      l10n.companionModeLight,
                      l10n.companionModeLightHint,
                    ),
                    (CompanionMode.full, AppIcons.engine, l10n.companionModeFull, l10n.companionModeFullHint),
                  ])
                    SettingsTile(
                      icon: icon,
                      tinted: false,
                      title: title,
                      subtitle: hint,
                      chevron: false,
                      trailing: (mode == CompanionMode.light) == light ? const Icon(AppIcons.selected, size: 20) : null,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(ref.read(companionModeProvider.notifier).choose(mode));
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 她多主动: off, or one of the paces. Off is the old 「主动邀请」 switch, so
  /// an earlier no stays a no.
  static List<(CompanionInitiativePace?, String, String)> _paceChoices(L10n l10n) => [
    (null, l10n.companionPaceQuiet, l10n.companionPaceQuietHint),
    (CompanionInitiativePace.rare, l10n.companionPaceRare, l10n.companionPaceRareHint),
    (CompanionInitiativePace.often, l10n.companionPaceOften, l10n.companionPaceOftenHint),
    (CompanionInitiativePace.chatty, l10n.companionPaceChatty, l10n.companionPaceChattyHint),
  ];

  static CompanionInitiativePace? _paceChoice(WidgetRef ref) =>
      (ref.watch(companionInitiativeEnabledProvider) ?? false) ? ref.watch(companionInitiativePaceProvider) : null;

  void _choosePace() {
    unawaited(
      showAppSheet<void>(
        context,
        builder: (sheet) => Consumer(
          builder: (sheet, ref, _) {
            final l10n = sheet.l10n;
            final chosen = _paceChoice(ref);
            final ready = ref.watch(companionInitiativeEnabledProvider) != null;
            return SafeArea(
              top: false,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SheetTitleBar(l10n.companionMenuPace),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 12),
                      child: Text(l10n.companionPaceHint, style: Theme.of(sheet).textTheme.bodySmall),
                    ),
                    SheetGroup(
                      margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                      children: [
                        for (final (pace, title, hint) in _paceChoices(l10n))
                          SettingsTile(
                            tinted: false,
                            title: title,
                            subtitle: hint,
                            chevron: false,
                            trailing: pace == chosen ? const Icon(AppIcons.selected, size: 20) : null,
                            onTap: !ready
                                ? null
                                : () {
                                    Navigator.of(sheet).pop();
                                    unawaited(ref.read(companionInitiativeEnabledProvider.notifier).set(pace != null));
                                    if (pace != null) {
                                      unawaited(ref.read(companionInitiativePaceProvider.notifier).set(pace));
                                    }
                                  },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 她会提起什么: the four consents of the signal gate. Each one below needs
  /// the one above it; all of it stays in this room.
  void _openSignals() {
    unawaited(
      showAppSheet<void>(
        context,
        builder: (sheet) => Consumer(
          builder: (sheet, ref, _) {
            final l10n = sheet.l10n;
            final read = ref.watch(companionSignalConsentProvider);
            final consent = read ?? const CompanionSignalConsent();
            ValueChanged<bool>? change(bool allowed, CompanionSignalConsent Function(bool on) next) =>
                read == null || !allowed
                ? null
                : (on) => unawaited(ref.read(companionSignalConsentProvider.notifier).set(next(on)));
            final speaks = consent.state && consent.optionalSpeech;
            return SafeArea(
              top: false,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SheetTitleBar(l10n.companionMenuSignals),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 12),
                      child: Text(l10n.companionSignalsHint, style: Theme.of(sheet).textTheme.bodySmall),
                    ),
                    SheetGroup(
                      margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                      children: [
                        SettingsSwitchTile(
                          tinted: false,
                          title: l10n.companionSignalState,
                          subtitle: l10n.companionSignalStateHint,
                          value: consent.state,
                          onChanged: change(true, (on) => consent.copyWith(state: on)),
                        ),
                        SettingsSwitchTile(
                          tinted: false,
                          title: l10n.companionSignalSpeech,
                          subtitle: l10n.companionSignalSpeechHint,
                          value: consent.optionalSpeech,
                          onChanged: change(consent.state, (on) => consent.copyWith(optionalSpeech: on)),
                        ),
                        SettingsSwitchTile(
                          tinted: false,
                          title: l10n.companionSignalVoice,
                          subtitle: l10n.companionSignalVoiceHint,
                          value: consent.voice,
                          onChanged: change(speaks, (on) => consent.copyWith(voice: on)),
                        ),
                        SettingsSwitchTile(
                          tinted: false,
                          title: l10n.companionSignalNight,
                          subtitle: l10n.companionSignalNightHint,
                          value: consent.nightCare,
                          onChanged: change(speaks, (on) => consent.copyWith(nightCare: on)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 陪你看屏幕: the resident observer's settings. Native state is the authority;
  /// the sheet only mirrors it and sends changes back.
  void _openScreen() {
    final screen = ref.read(companionAlwaysOnOwnerProvider).screen;
    unawaited(screen.refresh());
    unawaited(
      showAppSheet<void>(
        context,
        builder: (sheet) => ValueListenableBuilder<Map<String, Object?>>(
          valueListenable: screen.state,
          builder: (sheet, state, _) {
            final l10n = sheet.l10n;
            final enabled = state['enabled'] == true;
            final canSee = state['accessibility'] == true || state['projection_active'] == true;
            final visionEnabled = state['vision_enabled'] == true;
            final visionSelection = ModelSelection.fromJson(state['vision_selection']);
            final frequency = state['frequency'] as String? ?? 'normal';
            final perHour = state['serious_per_hour'] as int? ?? 0;
            final cost = (state['today_estimated_cny'] as num?)?.toDouble() ?? 0;
            final caption = Theme.of(sheet).textTheme.bodySmall;
            // A channel failure leaves the mirrored state as it was.
            void send(Future<void> change) => unawaited(change.catchError((Object _) {}));
            return SafeArea(
              top: false,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SheetTitleBar(l10n.companionScreen),
                    SheetGroup(
                      margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                      children: [
                        SettingsSwitchTile(
                          tinted: false,
                          title: l10n.companionScreen,
                          subtitle: enabled && !canSee ? l10n.companionScreenNeedsAccess : l10n.companionScreenHint,
                          value: enabled,
                          onChanged: (on) => send(screen.configure(enabled: on)),
                        ),
                        if (enabled && !canSee)
                          SettingsTile(
                            tinted: false,
                            title: l10n.companionScreenAllowProjection,
                            onTap: () => send(screen.requestProjection()),
                          ),
                        if (state['usage_access'] == false)
                          SettingsTile(
                            tinted: false,
                            title: l10n.companionScreenUsageAccess,
                            onTap: () => send(screen.requestUsageAccess()),
                          ),
                        SettingsSwitchTile(
                          tinted: false,
                          title: l10n.companionScreenVision,
                          subtitle: !visionEnabled
                              ? l10n.companionScreenVisionHint
                              : state['image_capture_supported'] != true
                              ? l10n.companionScreenVisionTextOnly
                              : switch (state['vision_status']) {
                                  'available' => l10n.companionScreenVisionAvailable,
                                  'checking' || 'unchecked' => l10n.companionScreenVisionChecking,
                                  _ => l10n.companionScreenVisionUnavailable,
                                },
                          value: visionEnabled,
                          onChanged: (on) => send(screen.configure(visionEnabled: on)),
                        ),
                        // Also what she looks at album photos with, screen pictures on or off.
                        SettingsTile(
                          tinted: false,
                          title: l10n.companionScreenVisionModel,
                          subtitle: visionSelection == null
                              ? l10n.companionScreenVisionChoose
                              : '${visionSelection.provider} / ${visionSelection.model}',
                          onTap: () {
                            final scope = ref.read(modelSelectionScopeProvider);
                            final host = companionHostKey(ref.read(activeHostProvider));
                            unawaited(
                              showModelSheet(
                                sheet,
                                current: state['vision_host'] == host ? visionSelection : null,
                                onSelected: (selection) {
                                  if (!mounted || !identical(scope, ref.read(modelSelectionScopeProvider))) {
                                    return;
                                  }
                                  send(screen.configure(visionSelection: selection.toJson(), visionHost: host));
                                },
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 8),
                      child: Text(l10n.companionScreenFrequency, style: caption),
                    ),
                    SheetGroup(
                      margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                      children: [
                        for (final (value, title, hint) in [
                          ('quiet', l10n.companionScreenQuiet, l10n.companionScreenQuietHint),
                          ('normal', l10n.companionScreenNormal, l10n.companionScreenNormalHint),
                          ('chatty', l10n.companionScreenChatty, l10n.companionScreenChattyHint),
                          ('live', l10n.companionScreenLive, l10n.companionScreenLiveHint),
                        ])
                          SettingsTile(
                            tinted: false,
                            title: title,
                            subtitle: hint,
                            chevron: false,
                            trailing: value == frequency ? const Icon(AppIcons.selected, size: 20) : null,
                            onTap: value == frequency ? null : () => send(screen.configure(frequency: value)),
                          ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 8),
                      child: Text(l10n.companionScreenPerHour, style: caption),
                    ),
                    SheetGroup(
                      margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                      children: [
                        // 0 is no limit, the default.
                        for (final value in const [0, 10, 30, 60])
                          SettingsTile(
                            tinted: false,
                            title: value == 0 ? l10n.companionScreenPerHourNone : '$value',
                            chevron: false,
                            trailing: value == perHour ? const Icon(AppIcons.selected, size: 20) : null,
                            onTap: value == perHour ? null : () => send(screen.configure(seriousPerHour: value)),
                          ),
                      ],
                    ),
                    if (cost > 0)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 16),
                        child: Text(l10n.companionScreenCost(cost.toStringAsFixed(2)), style: caption),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _openMenu() {
    _acted();
    // Inside the room's sections her own page has all of this.
    if (widget.sections) {
      _selectTab(_CompanionTab.her);
      return;
    }
    unawaited(
      showAppSheet<void>(
        // The room's water theme, not the app's: the sheet is part of her room.
        _themedContext ?? context,
        isScrollControlled: true,
        // Scrolls on a short screen instead of overflowing.
        builder: (sheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _panelHeader(context.l10n),
                ..._panel(context.l10n, (action, {stage = false}) {
                  Navigator.of(sheet).pop();
                  action();
                }, tiles: true),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Her name, how she talks and how close you are: the top of her panel and of her page.
  Widget _panelHeader(L10n l10n) => CompanionPanelHeader(
    name: ref.read(companionNameProvider) ?? _character.name ?? l10n.companionTitle,
    mode: '${l10n.companionMenuMode} · ${_light ? l10n.companionModeLight : l10n.companionModeFull}',
    bondTitle: _affinityCharacter == null ? null : l10n.companionBondTitle,
    bondLabel: _affinityCharacter == null
        ? null
        : switch (_bondTier) {
            0 => l10n.companionBond0,
            1 => l10n.companionBond1,
            2 => l10n.companionBond2,
            3 => l10n.companionBond3,
            4 => l10n.companionBond4,
            _ => l10n.companionBond5,
          },
    bondStep: _bondTier,
  );

  /// Everything about her and the room, in named groups. [run] does one row's
  /// action: the sheet closes first; her page goes back to the room first when
  /// the action plays out on her stage ([stage]). [tiles]: the shortcut tiles
  /// for 记忆 and 交代的事, which the sections already have as pages.
  List<Widget> _panel(L10n l10n, void Function(VoidCallback action, {bool stage}) run, {required bool tiles}) {
    final light = _light;
    late final hasLightEntries = _visibleLightEntries.isNotEmpty;
    final credit = [
      if (_character.author case final author?) l10n.companionCreditAuthor(author),
      ?_character.license,
      ?_character.source,
    ].join(' · ');
    const groupMargin = EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 14);
    if (!_rosterWanted) {
      _rosterWanted = true;
      scheduleMicrotask(() => unawaited(_loadRoster()));
    }
    return [
      CompanionPanelTiles(
        tiles: [
          if (tiles) ...[
            (
              icon: AppIcons.bookmark,
              label: l10n.companionMemoryTitle,
              onTap: () => run(() => unawaited(_openMemories())),
            ),
            (icon: AppIcons.reminder, label: l10n.companionTasksTitle, onTap: () => run(() => unawaited(_openTasks()))),
          ],
          if (_sessionId != null || hasLightEntries)
            (icon: AppIcons.history, label: l10n.companionLogTitle, onTap: () => run(_openLog, stage: true)),
          if (!_light && _sessionId != null && hasLightEntries)
            (icon: AppIcons.history, label: l10n.companionLogOnDevice, onTap: () => run(() => _openLog(phone: true), stage: true)),
          (
            icon: AppIcons.companionVoice,
            label: l10n.companionMenuVoice,
            onTap: () => run(
              () => unawaited(
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CompanionVoicePage())),
              ),
            ),
          ),
          if (!tiles)
            (
              icon: AppIcons.edit,
              label: l10n.companionMenuPersona,
              onTap: () => run(
                () => unawaited(
                  Navigator.of(context)
                      .push(
                        MaterialPageRoute<void>(
                          builder: (_) => CompanionPersonaPage(
                            packName: _character.name,
                            whale: companionIsWhale(_characterSourceKey, _character.name),
                          ),
                        ),
                      )
                      .then((_) => _writeLines()),
                ),
              ),
            ),
        ],
      ),
      // 伙伴: everyone on this phone, and a way to bring in another.
      SheetGroup(
        title: l10n.companionRosterTitle,
        margin: groupMargin,
        children: [
          for (final entry in _roster)
            CompanionRosterRow(
              key: ValueKey('roster-${entry.key}-$_rosterLoads'),
              name: entry.active ? _name(l10n) : entry.character.name ?? l10n.companionDefaultName,
              active: entry.active,
              cover: entry.cover,
              subtitle: entry.active ? l10n.companionRosterHere : entry.character.author,
              onTap: () => run(() => unawaited(_switchTo(entry))),
              onMore: () => unawaited(_rosterMore(entry)),
            ),
          SettingsTile(
            icon: AppIcons.add,
            tinted: false,
            title: l10n.companionRosterAdd,
            onTap: () => run(() => unawaited(_addCompanion())),
          ),
        ],
      ),
      // 陪伴: how much she's around, in and out of the room.
      SheetGroup(
        title: l10n.companionPanelCompany,
        margin: groupMargin,
        children: [
          Consumer(
            builder: (context, ref, _) {
              final status = ref.watch(companionResidencyProvider);
              if (!status.available) return const SizedBox.shrink();
              return SettingsSwitchTile(
                icon: AppIcons.pet,
                tinted: false,
                title: l10n.companionAlwaysOn,
                subtitle: switch (status) {
                  CompanionAlwaysOnStatus(failure: _?) => l10n.companionAlwaysOnFailed,
                  CompanionAlwaysOnStatus(enabled: true, notificationAvailable: false) =>
                    l10n.companionAlwaysOnNoNotify,
                  CompanionAlwaysOnStatus(enabled: true, running: true) => l10n.companionAlwaysOnRunning,
                  _ => l10n.companionAlwaysOnHint,
                },
                value: status.enabled,
                onChanged: (on) => unawaited(ref.read(companionResidencyProvider.notifier).setEnabled(on)),
              );
            },
          ),
          Consumer(
            builder: (context, ref, _) {
              final status = ref.watch(companionResidencyProvider);
              if (!status.available || !status.enabled || !status.running) return const SizedBox.shrink();
              return SettingsTile(
                icon: AppIcons.preview,
                tinted: false,
                title: l10n.companionScreen,
                onTap: () => run(_openScreen),
              );
            },
          ),
          // 她会留意你的通知: only Android has a notification listener.
          if (ref.read(operatingSystemProvider) == 'android')
            SettingsTile(
              key: const ValueKey('companion-notices'),
              icon: AppIcons.mail,
              tinted: false,
              title: l10n.companionNotices,
              onTap: () => run(
                () => unawaited(
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CompanionNoticesPage())),
                ),
              ),
            ),
          Consumer(
            builder: (context, ref, _) => SettingsTile(
              icon: AppIcons.companionInvite,
              tinted: false,
              title: l10n.companionMenuPace,
              value: Text(_paceChoices(l10n).firstWhere((c) => c.$1 == _paceChoice(ref)).$2),
              onTap: () => run(_choosePace),
            ),
          ),
          SettingsTile(
            icon: AppIcons.notifications,
            tinted: false,
            title: l10n.companionMenuSignals,
            onTap: () => run(_openSignals),
          ),
        ],
      ),
      // 她: who she is and how she moves.
      SheetGroup(
        title: l10n.companionPanelHer,
        margin: groupMargin,
        children: [
          if (tiles)
            SettingsTile(
              icon: AppIcons.edit,
              tinted: false,
              title: l10n.companionMenuPersona,
              value: Text(_name(l10n)),
              onTap: () => run(
                () => unawaited(
                  Navigator.of(context)
                      .push(
                        MaterialPageRoute<void>(
                          builder: (_) => CompanionPersonaPage(
                            packName: _character.name,
                            whale: companionIsWhale(_characterSourceKey, _character.name),
                          ),
                        ),
                      )
                      .then((_) => _writeLines()),
                ),
              ),
            ),
          SettingsTile(
            icon: AppIcons.generating,
            tinted: false,
            title: l10n.companionMenuMoves,
            value: Text('${_moves.expressions.length + _moves.motions.length}'),
            onTap: () => run(_openMoves, stage: true),
          ),
          SettingsTile(
            icon: AppIcons.configure,
            tinted: false,
            title: l10n.companionMenuAdapt,
            value: _adapting
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: () => run(_openAdapt, stage: true),
          ),
          // 创意工坊: companions other people made. Only where this build has one to open.
          if (ref.read(workshopAvailableProvider))
            SettingsTile(
              icon: AppIcons.workshop,
              tinted: false,
              title: l10n.workshopTitle,
              subtitle: l10n.workshopEntrySubtitle,
              onTap: () => run(
                () => unawaited(
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WorkshopScreen())).then((_) {
                    // She may have been updated there, her cover with her.
                    if (_rosterWanted) unawaited(_loadRoster());
                    return _afterWorkshop();
                  }),
                ),
              ),
            ),
        ],
      ),
      // 对话: where her words go and what she can look back on.
      SheetGroup(
        title: l10n.companionPanelTalk,
        margin: groupMargin,
        children: [
          if (ref.watch(operatingSystemProvider) == 'android')
            SettingsTile(
              icon: AppIcons.companionVoice,
              tinted: false,
              title: l10n.companionSystemAssistant,
              onTap: () => run(() => unawaited(showCompanionAssistantSettings(context))),
            ),
          SettingsTile(
            icon: light ? AppIcons.engineStarting : AppIcons.engine,
            tinted: false,
            title: l10n.companionMenuMode,
            value: Text(light ? l10n.companionModeLight : l10n.companionModeFull),
            onTap: () => run(_chooseMode),
          ),
          SettingsTile(
            icon: AppIcons.search,
            tinted: false,
            title: l10n.companionMemorySearchTitle,
            onTap: () => run(() => unawaited(_openMemorySearch())),
          ),
          if (hasLightEntries || (!light && _sessionId != null))
            SettingsTile(
              icon: AppIcons.newChat,
              tinted: false,
              title: l10n.companionMenuRestart,
              subtitle: l10n.companionMenuRestartLightHint,
              onTap: () => run(() => unawaited(_restart()), stage: true),
            ),
        ],
      ),
      SheetGroup(
        title: l10n.companionPanelMore,
        margin: groupMargin,
        children: [
          // 模式: 工作 or 酒馆 from here, and which one a launch opens.
          SettingsTile(
            key: const ValueKey('companion-mode'),
            icon: AppIcons.modes,
            tinted: false,
            title: l10n.modeSheetTitle,
            value: Text(l10n.modeCompanionShort),
            onTap: () => run(() => unawaited(showModeSheet(context, current: AppMode.companion))),
          ),
          SettingsTile(
            icon: AppIcons.delete,
            tinted: false,
            title: l10n.companionMenuRemovePack,
            onTap: () => run(() => unawaited(_removePack()), stage: true),
          ),
        ],
      ),
      if (credit.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 12),
          child: Text(
            credit,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
          ),
        ),
    ];
  }

  Future<bool> _confirm(String action, String message, {String? confirm}) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(action),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(dialog.l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(confirm ?? action)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _restart() async {
    final l10n = context.l10n;
    final ok = await _confirm(l10n.companionMenuRestart, l10n.companionMenuRestartLightConfirm);
    if (!ok || !mounted || !_attachment.isAttached) return;
    _hush();
    _settleTimer?.cancel();
    await _attachment.restart();
    if (!mounted || !_attachment.isAttached) return;
    setState(() {
      _running = false;
      _myLine = null;
    });
    _refreshMood();
    _say(_firstHello(l10n));
  }

  Future<void> _removePack() async {
    final l10n = context.l10n;
    final ok = await _confirm(
      l10n.companionMenuRemovePack,
      _bundledHere ? l10n.companionMenuRemoveConfirmBundled : l10n.companionMenuRemoveConfirm,
    );
    if (!ok || !mounted) return;
    // Removed on purpose: the pack inside the app doesn't come back by itself.
    unawaited(SharedPreferences.getInstance().then((p) => p.setBool(_packRemovedKey, true)));
    setState(() {
      _phase = _Phase.setup;
      _stageReady = false;
      _adaptOffer = null;
      _probe = null;
    });
    _syncSignals();
    try {
      await _store?.remove();
      if (!mounted || !_attachment.isAttached) return;
      // What the person called her and wrote for her goes with her.
      if (_characterSourceKey case final key?) unawaited(companionForgetIdentity(ref, key));
      setState(() => _setCharacter(const CompanionCharacter(), null));
      _attachment.updateCharacter(_character, _moves, sourceKey: _characterSourceKey);
    } on CompanionPackException catch (error) {
      // Something still reads her files (a floating window that wouldn't let
      // go): they stay, and the setup screen says so.
      if (mounted) setState(() => _installError = _problemText(error.problem));
    } on Object {
      if (mounted) setState(() => _installError = context.l10n.companionPackStorage);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Keep the process provider active while this real window is attached.
    // Host/mode business listeners live in the Agent visit; this only refreshes
    // the original signal lane's window rendering.
    ref.watch(companionAgentProvider);
    ref.listen(activeHostProvider, (_, _) => _syncSignals());
    ref.listen(activeConnectionProvider.select((value) => value.value), (_, _) => _syncSignals());
    // What her invitation depends on that only a build can see: this page in
    // front (a sheet or another page over her isn't), a screen reader, the switch.
    // Another of the section's pages over her room hides it like a page on top.
    final routeShown =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true) &&
        (!widget.sections || _tab == _CompanionTab.room);
    if (_routeShown && !routeShown) {
      _checkNotesSelectionRoute();
    }
    if (_routeShown && !routeShown && !_mapChoosing) {
      _mapHandoff.close();
    }
    _routeShown = routeShown;
    _accessible = MediaQuery.accessibleNavigationOf(context);
    ref.watch(companionInitiativeEnabledProvider);
    ref.watch(companionNameProvider);
    ref.listen(companionRenamedProvider, (_, name) {
      if (name == null) return;
      ref.read(companionRenamedProvider.notifier).set(null);
      // After the page over her has gone.
      Timer(const Duration(milliseconds: 450), () => _renamedTo(name));
    });
    _queueObserve();
    final surfaces = DshSurfaces.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      // The water is dark at every hour, whatever the app's own theme.
      child: Theme(
        data: _darkTheme(surfaces.accent, surfaces.blurEnabled),
        child: PopScope(
          canPop: !_logOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _closeLog();
          },
          // Her top bar, words and input blur what's behind them once between
          // them (they never overlap), not once each, each time her stage draws.
          child: BackdropGroup(child: Builder(builder: _buildSections)),
        ),
      ),
    );
  }

  Widget _buildSections(BuildContext context) {
    // The memory, task and her pages query the store as they build. This page
    // builds for each of her streamed words and the room for each frame of the
    // keyboard, so they are made again only for another tab, memory or
    // character. The task and her pages in front still are: times move, and
    // her settings change under her own page.
    if (widget.sections) _visited.add(_tab);
    if (_sectionPagesKey != _sectionPagesFor) _sectionPages.clear();
    for (final tab in _visited) {
      if (tab == _CompanionTab.memory || tab != _CompanionTab.room && _tab != tab) {
        _sectionPages.putIfAbsent(tab, () => _sectionPage(context, tab));
      }
    }
    _sectionPagesFor = _sectionPagesKey;
    return Builder(builder: (context) => _buildPage(context, _sectionPages));
  }

  final _sectionPages = <_CompanionTab, Widget>{};
  Object? _sectionPagesFor;
  Object get _sectionPagesKey => (_tab, _sectionMemory, _attachment.characterId);

  Widget _buildPage(BuildContext context, Map<_CompanionTab, Widget> pages) {
    final l10n = context.l10n;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final padding = MediaQuery.paddingOf(context);
    final store = _store;
    final showStage = _phase == _Phase.stage && store != null;
    if (showStage && _stageReady) _queueReplyPresentation();
    final name = _name(l10n);
    // Her conversation on the host, when there is one: a key to it on the bar.
    final chatId = ref.watch(companionCharacterChatIdProvider(_characterSourceKey));
    // Shown only while it still belongs here and nothing else has the floor,
    // in this very frame (the owner hears about it right after).
    final invite = _invite;
    final inviting =
        invite != null && invite.ticket.contextKey == _initiativeContext && _presentable(_initiativeView());
    final inviteLeft = switch (_inviteEnds) {
      final ends? when inviting => Duration(
        milliseconds: max(0, ends - ref.read(companionInitiativeClockProvider)().monoMs),
      ),
      _ => null,
    };
    // Her question about erasing original words, while her room is what's on screen.
    final rawErase = showStage && _stageReady && _routeShown && !_logOpen && _attachment.isAttached
        ? _attachment.pendingRawErase
        : null;
    if (rawErase != null && _rawEraseOffered != rawErase.id) _offerRawErase(rawErase.id);
    final rawEraseLeft = switch (rawErase?.expiresAtUtcMs) {
      final ends? => Duration(milliseconds: max(0, ends - DateTime.now().millisecondsSinceEpoch)),
      _ => null,
    };
    final events = CompanionStageEvents(
      onReady: _onReady,
      onFailed: (why) {
        // A stage already on its way out (her pack being removed) has no say.
        if (!mounted || _phase != _Phase.stage) return;
        setState(() {
          _phase = _Phase.failed;
          _failure = why;
          _failedWithPack = false;
        });
        _syncSignals();
        unawaited(_checkRetry());
      },
      onTouch: _onTouch,
      onWake: () => _say(l10n.companionWake),
      onMood: _onMood,
      onObject: _onObject,
      onActivity: _onActivity,
      onModel: (info) => unawaited(_onModel(info)),
      onProbe: _onProbe,
    );
    _themedContext = context;
    // The section's bar, over every page but a keyboard or her log.
    final navShown =
        widget.sections &&
        insets == 0 &&
        !(_logOpen && _tab == _CompanionTab.room) &&
        // Her memories and errands stay reachable with no pack yet; only
        // while she's arriving does the room keep the whole screen.
        (_tab != _CompanionTab.room || (showStage ? _stageReady : _phase != _Phase.checking && !_arriving));
    final navSpace = navShown ? CompanionSectionNav.height + 10 : 0.0;
    final room = Stack(
      fit: StackFit.expand,
      children: [
        if (showStage)
          // A finger landing on her already counts, before the stage knows
          // whether it was a tap, a pat or nothing (C452 §5.1).
          Listener(
            onPointerDown: (_) => _acted(),
            child: ExcludeSemantics(
              child:
                  widget.stageBuilder?.call(_stage, events) ??
                  CompanionStage(
                    key: ValueKey(_stageRun),
                    store: store,
                    controller: _stage,
                    events: events,
                    viewKey: _characterSourceKey ?? '',
                  ),
            ),
          ),
        if ((showStage && !_stageReady) || (_phase == _Phase.setup && _arriving))
          const CompanionWater(child: CompanionArriving())
        else if (_phase == _Phase.setup)
          CompanionWelcome(
            title: l10n.companionSetupTitle,
            message: _bundledHere ? l10n.companionSetupBodyBundled : l10n.companionSetupBody,
            action: _bundledHere ? l10n.companionSetupBundled : l10n.companionSetupImport,
            busy: _installing,
            error: _installError,
            onAction: _bundledHere ? _installBundled : _import,
            secondary: _bundledHere ? l10n.companionSetupImportOther : null,
            onSecondary: _import,
            tertiary: ref.read(workshopAvailableProvider) ? l10n.companionSetupWorkshop : null,
            onTertiary: () => unawaited(_workshopFromSetup()),
          ),
        if (_phase == _Phase.failed)
          CompanionWelcome(
            title: l10n.companionFailedTitle,
            message: _loadFailureText(l10n),
            action: l10n.companionSetupImport,
            state: PetStateName.error,
            busy: _installing,
            error: _installError,
            onAction: _import,
            secondary: _failedWithPack ? l10n.commonRetry : null,
            onSecondary: () => unawaited(_retryStage()),
          ),
        Positioned(
          top: padding.top + 8,
          left: companionEdge,
          right: companionEdge,
          child: Row(
            children: [
              CompanionRoundButton(
                icon: AppIcons.back,
                label: MaterialLocalizations.of(context).backButtonTooltip,
                grouped: true,
                onTap: () {
                  _acted();
                  unawaited(Navigator.of(context).maybePop());
                },
              ),
              // In the section her page is on the bar, so no ⋯ here: one key each side.
              if (!widget.sections) const SizedBox(width: 52),
              // Her conversation's key on the right: the same room on the left keeps her name centred.
              if (_stageReady && chatId != null) const SizedBox(width: 52),
              Expanded(
                child: Center(
                  child: _stageReady ? CompanionNamePlate(name: name, activity: _activity) : const SizedBox.shrink(),
                ),
              ),
              if (_stageReady) ...[
                if (chatId != null) ...[
                  CompanionRoundButton(
                    icon: AppIcons.conversations,
                    label: l10n.companionLogOpenChat,
                    grouped: true,
                    onTap: _openFullChat,
                  ),
                  const SizedBox(width: 8),
                ],
                CompanionRoundButton(
                  icon: AppIcons.history,
                  label: l10n.companionLogTitle,
                  grouped: true,
                  onTap: _openLog,
                ),
                if (!widget.sections) ...[
                  const SizedBox(width: 8),
                  CompanionRoundButton(icon: AppIcons.more, label: l10n.companionMenu, grouped: true, onTap: _openMenu),
                ],
              ] else
                SizedBox(width: widget.sections ? 44 : 96),
            ],
          ),
        ),
        if (showStage && _stageReady)
          Positioned(
            left: companionEdge,
            right: companionEdge,
            bottom: max(insets, padding.bottom + navSpace) + companionEdge,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Her invitation takes the hint's place while it's there.
                if (_showTouchHint && _bubble == null && !inviting)
                  CompanionPill(icon: AppIcons.tip, label: l10n.companionTouchHint)
                else if (_showHomeHint && _bubble == null && !inviting)
                  CompanionPill(icon: AppIcons.tip, label: l10n.companionTouchHintHome),
                if (_voiceNotice case final notice?) CompanionPill(icon: AppIcons.tip, label: notice),
                if (_agentPill case final pill?)
                  CompanionPill(
                    icon: AppIcons.conversations,
                    label: pill.label,
                    tone: const Color(0xFF9FD8F2),
                    onTap: () {
                      _acted();
                      _openAgent(pill.sessionId);
                    },
                  ),
                if (!_light && chatId != null) CompanionAsk(key: ValueKey(chatId), sessionId: chatId),
                CompanionMyLine(text: _myLine),
                ValueListenableBuilder<String?>(
                  valueListenable: _bubbleWords,
                  builder: (_, words, _) => CompanionSpeech(
                    text: words,
                    textKey: _bubbleTextKey,
                    onFrame: _queueReplyPresentation,
                    error: _bubbleIsError,
                    thinking: _sending || (_running && words == null),
                    onPullBack: _openLog,
                  ),
                ),
                if (_bubble != null)
                  for (final result in _lookupResults)
                    CompanionPill(
                      icon: AppIcons.search,
                      label: l10n.companionLookupViewSources(result.placeName),
                      onTap: () {
                        if (_bubble == null || !_lookupResults.contains(result)) {
                          return;
                        }
                        _acted();
                        unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => CompanionTasksPage(memory: _memoryOwner!, taskId: result.taskId),
                            ),
                          ),
                        );
                      },
                    ),
                if (_bubble != null)
                  for (final id in _notesResults)
                    CompanionPill(
                      icon: AppIcons.document,
                      label: l10n.companionNotesView,
                      onTap: () {
                        if (_bubble == null || !_notesResults.contains(id)) {
                          return;
                        }
                        _acted();
                        unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => CompanionTasksPage(memory: _memoryOwner!, taskId: id),
                            ),
                          ),
                        );
                      },
                    ),
                if (_bubble != null)
                  for (final id in _mapResults)
                    CompanionPill(
                      icon: AppIcons.plan,
                      label: l10n.companionMapView,
                      onTap: () {
                        if (_bubble == null || !_mapResults.contains(id)) {
                          return;
                        }
                        _acted();
                        unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => CompanionTasksPage(memory: _memoryOwner!, taskId: id),
                            ),
                          ),
                        );
                      },
                    ),
                // Erasing original words waits for the person's own tap.
                CompanionInvite(
                  ticket: rawErase == null ? null : 'raw-erase-${rawErase.id}',
                  mark: const Icon(AppIcons.delete, size: 20, color: Color(0xFFFFB4A8)),
                  text: rawErase == null ? '' : _rawEraseQuestion(l10n, rawErase),
                  accept: l10n.companionRawEraseYes,
                  decline: l10n.companionRawEraseNo,
                  remaining: rawEraseLeft,
                  total: const Duration(minutes: 5),
                  onAccept: () => _answerRawErase(rawErase, erase: true),
                  onDecline: () => _answerRawErase(rawErase, erase: false),
                ),
                CompanionInvite(
                  ticket: _adaptOffer == null || inviting || rawErase != null ? null : 'adapt-${_adaptOffer!.moc}',
                  mark: const Icon(AppIcons.configure, size: 20, color: Color(0xFFFFD27A)),
                  text: l10n.companionAdaptOffer,
                  accept: l10n.companionAdaptOfferYes,
                  decline: l10n.companionAdaptOfferNo,
                  onAccept: () => unawaited(_answerAdaptOffer(yes: true)),
                  onDecline: () => unawaited(_answerAdaptOffer(yes: false)),
                ),
                CompanionInvite(
                  ticket: inviting && rawErase == null ? invite.ticket.id : null,
                  text: l10n.companionInviteRest,
                  accept: l10n.companionInviteAccept,
                  decline: l10n.companionInviteDecline,
                  remaining: inviteLeft,
                  total: const Duration(milliseconds: CompanionInitiativeRules.promptMs),
                  onAccept: () => _answerInvite(yes: true),
                  onDecline: () => _answerInvite(yes: false),
                ),
                const SizedBox(height: 10),
                if (_assistantPage != null)
                  InputChip(
                    label: Text(l10n.companionAssistantPageAttached),
                    onDeleted: () => setState(() => _assistantPage = null),
                  ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _input,
                  builder: (context, value, _) => CompanionComposer(
                    // Reaching for the keyboard is not talking over her: she finishes
                    // her sentence; sending (or the microphone) is what stops her.
                    // While she voices a memory follow-up, acting would withdraw it
                    // and cut her off, so typing only marks that the person is here.
                    onUserInput: () => _memoryFollowupTicket == null
                        ? _acted()
                        : _observeLateUse(interaction: true),
                    input: _input,
                    focus: _focus,
                    hint: l10n.companionInputHint(name),
                    running: _running,
                    busy: _sending,
                    listening: _voice.active,
                    voiceAvailable: _voice.available,
                    onSend: _send,
                    onStop: _stop,
                    onCall: _openCall,
                    onVoice: () {
                      // Reaching for the microphone is already doing something.
                      _acted();
                      // Her voice off before the microphone opens.
                      _hush();
                      _voice.active ? _voice.stop() : _voice.start();
                    },
                  ),
                ),
              ],
            ),
          ),
        Positioned.fill(child: CompanionLogTransition(child: _logOpen && showStage ? _log(name) : null)),
      ],
    );
    if (!widget.sections) {
      return Scaffold(backgroundColor: const Color(0xFF0D2F55), resizeToAvoidBottomInset: false, body: room);
    }
    return Scaffold(
      backgroundColor: const Color(0xFF0D2F55),
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          IndexedStack(
            index: _tab.index,
            sizing: StackFit.expand,
            children: [
              for (final tab in _CompanionTab.values)
                if (tab == _CompanionTab.room)
                  // Another page over her room covers it like a route: her
                  // stage pauses there. Her stage's chrome keeps clear of the
                  // bar itself; the first-run and failure screens get it as
                  // bottom padding.
                  TickerMode(
                    enabled: _tab == _CompanionTab.room,
                    child: showStage
                        ? room
                        : MediaQuery(
                            data: MediaQuery.of(context)
                                .copyWith(padding: padding.copyWith(bottom: padding.bottom + navSpace)),
                            child: room,
                          ),
                  )
                else if (!_visited.contains(tab))
                  const SizedBox.shrink()
                else
                  // Its own page keeps clear of the bar along the bottom.
                  MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(padding: padding.copyWith(bottom: padding.bottom + CompanionSectionNav.height + 10)),
                    child: TickerMode(enabled: _tab == tab, child: pages[tab] ?? _sectionPage(context, tab)),
                  ),
            ],
          ),
          Positioned(
            left: companionEdge + 8,
            right: companionEdge + 8,
            bottom: padding.bottom + 10,
            child: IgnorePointer(
              ignoring: !navShown,
              child: AnimatedOpacity(
                opacity: navShown ? 1 : 0,
                duration: AppMotion.of(context, AppMotion.quick),
                child: CompanionSectionNav(
                  selected: _tab.index,
                  onSelect: (index) => _selectTab(_CompanionTab.values[index]),
                  items: [
                    (icon: AppIcons.home, label: l10n.companionTabRoom),
                    (icon: AppIcons.bookmark, label: l10n.companionTabMemory),
                    (icon: AppIcons.reminder, label: l10n.companionTabTasks),
                    (icon: AppIcons.postLike, label: l10n.companionTabHer),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The pages of the section other than her room.
  final _visited = <_CompanionTab>{};

  Widget _sectionPage(BuildContext context, _CompanionTab tab) {
    if (tab == _CompanionTab.her) {
      final l10n = context.l10n;
      return AppPage(
        title: ref.read(companionNameProvider) ?? _character.name ?? l10n.companionTitle,
        hero: _panelHeader(l10n),
        slivers: [
          SliverList.list(
            children: _panel(l10n, (action, {stage = false}) {
              if (stage) _selectTab(_CompanionTab.room);
              action();
            }, tiles: false),
          ),
        ],
      );
    }
    return FutureBuilder<CompanionMemoryOwner>(
      future: _sectionMemory ??= _openMemory(),
      builder: (context, snapshot) {
        final l10n = context.l10n;
        final title = tab == _CompanionTab.memory ? l10n.companionMemoryTitle : l10n.companionTasksTitle;
        return switch (snapshot) {
          AsyncSnapshot(hasData: true, :final data?) when tab == _CompanionTab.memory => CompanionMemoryPage(
            memory: data,
            characterId: _attachment.characterId,
          ),
          AsyncSnapshot(hasData: true, :final data?) => CompanionTasksPage(memory: data, allSessions: true),
          AsyncSnapshot(hasError: true) => AppPage.list(
            title: title,
            children: [
              EmptyView(
                icon: tab == _CompanionTab.memory ? AppIcons.bookmark : AppIcons.reminder,
                title: l10n.companionMemoryLoadFailed,
                actionLabel: l10n.commonRetry,
                onAction: () => setState(() => _sectionMemory = null),
              ),
            ],
          ),
          _ => AppPage.list(title: title, children: const []),
        };
      },
    );
  }
}

/// The pages of the 伙伴小屋 section, in the order of its bar.
enum _CompanionTab { room, memory, tasks, her }

/// The original Page's real pickers, captured for one submitted turn. An
/// unrelated route or lifecycle exit retires it even if the room returns.
class _CompanionPageTaskUi implements CompanionAgentTaskUi {
  _CompanionPageTaskUi(this.page, this.current)
    : epoch = page._notesForegroundEpoch,
      mapGeneration = page._mapHandoff.generation,
      strings = page.context.l10n {
    selectionRoute = (route, nextRoute) {
      if (!current() || epoch != page._notesForegroundEpoch) return;
      page._notesSelectionRoutes.add(route);
      if (nextRoute != null && !page._notesSelectionRoutes.contains(nextRoute)) {
        if (nextRoute is DialogRoute<Object?> && identical(nextRoute.settings.arguments, selectionRoute)) {
          page._notesSelectionRoutes.add(nextRoute);
        } else {
          page._notesForegroundEpoch++;
          return;
        }
      }
      page._checkNotesSelectionRoute();
    };
  }

  final _CompanionPageState page;
  final bool Function() current;
  final int epoch, mapGeneration;
  final L10n strings;
  late final CompanionAgentSelectionRoute selectionRoute;

  @override
  bool get isCurrent =>
      current() &&
      page.mounted &&
      !page._leaving &&
      // Another page of the section over her room covers it like a route.
      (!page.widget.sections || page._tab == _CompanionTab.room) &&
      epoch == page._notesForegroundEpoch &&
      !page._logOpen &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      // The route, not the ticker: right after an owned picker pops, this
      // page's TickerMode still reads the covered value until the next build.
      // Coverage by any other route has already retired the epoch above.
      ((ModalRoute.of(page.context)?.isCurrent ?? false) ||
          page._notesSelectionRoutes.any((route) => route.isActive && route.isCurrent));
  @override
  bool get mapIsCurrent => isCurrent && page._mapHere && mapGeneration == page._mapHandoff.generation;
  @override
  CompanionAgentSelectionRoute get onSelectionRoute => selectionRoute;

  @override
  Future<String?> chooseDeadline(
    List<String> choices, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async {
    if (!this.isCurrent || !isCurrent()) return null;
    return showAppDialog<String>(
      context: page.context,
      onRouteChanged: onRouteChanged,
      builder: (dialog) => SimpleDialog(
        title: choices.length == 2 && choices.contains('07:00') && choices.contains('19:00')
            ? Text(strings.companionFindSeven)
            : null,
        children: [
          for (final time in choices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, time),
              child: Text(switch (time) {
                '07:00' => strings.companionFindMorningSeven,
                '19:00' => strings.companionFindEveningSeven,
                _ => time,
              }),
            ),
          SimpleDialogOption(onPressed: () => Navigator.pop(dialog), child: Text(strings.commonCancel)),
        ],
      ),
    );
  }

  @override
  Future<String?> chooseDirectory({
    required String kind,
    String? directoryHint,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async {
    if (!this.isCurrent || !isCurrent()) return null;
    return showDirectoryPicker(
      page.context,
      onRouteChanged: onRouteChanged,
      title: kind == 'host.find_draft'
          ? strings.companionFindChooseDirectory(directoryHint ?? '')
          : strings.companionNotesChooseDirectory,
    );
  }

  @override
  Future<MemoryRow?> chooseSavedDirectory(
    List<MemoryRow> directories, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async {
    if (!this.isCurrent || !isCurrent()) return null;
    return showAppDialog<MemoryRow>(
      context: page.context,
      onRouteChanged: onRouteChanged,
      builder: (dialog) => SimpleDialog(
        title: Text(strings.companionFindSavedDirectory),
        children: [
          for (final value in directories)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, value),
              child: Text(value['displayPath']! as String),
            ),
          SimpleDialogOption(onPressed: () => Navigator.pop(dialog), child: Text(strings.commonCancel)),
        ],
      ),
    );
  }

  @override
  Future<MemoryRow?> chooseDrafts({
    required CompanionMemoryStore store,
    required String hostKey,
    required DshClient? client,
    required CompanionTasksCapability? capability,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
    String? originalStoreId,
  }) async {
    if (!this.isCurrent || !isCurrent()) return null;
    return chooseCompanionDraftInputs(
      page.context,
      store: store,
      hostKey: hostKey,
      client: client,
      capability: capability,
      isCurrent: isCurrent,
      onRouteChanged: onRouteChanged,
      originalStoreId: originalStoreId,
    );
  }

  @override
  Future<({List<MemoryRow> inputs, MemoryRow outputDirectory})?> chooseReceipts({
    required CompanionMemoryStore store,
    required String hostKey,
    required DshClient? client,
    required CompanionTasksCapability? capability,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
    String? originalStoreId,
    List<MemoryRow>? keptInputs,
    MemoryRow? keptOutput,
  }) async {
    if (!this.isCurrent || !isCurrent()) return null;
    return chooseCompanionReceiptInputs(
      page.context,
      store: store,
      hostKey: hostKey,
      client: client,
      capability: capability,
      isCurrent: isCurrent,
      onRouteChanged: onRouteChanged,
      originalStoreId: originalStoreId,
      keptInputs: keptInputs,
      keptOutput: keptOutput,
    );
  }

  @override
  Future<CompanionMapSpec?> chooseMap(
    CompanionMaps maps,
    String address, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async {
    if (!mapIsCurrent || !isCurrent()) return null;
    return chooseCompanionMapTarget(
      page.context,
      maps,
      address,
      isCurrent: isCurrent,
      choosing: (value) => page._mapChoosing = value,
      onRouteChanged: onRouteChanged,
    );
  }

  @override
  void accepted(MemoryRow task) {
    if (!isCurrent) return;
    final id = task['task_id']! as String;
    page._update(() {
      switch (task['kind']) {
        case 'public.lookup':
          final original = page._memoryOwner!.store.lookupTask(id)!;
          page._lookupResults = [
            for (final result in page._lookupResults)
              if (result.taskId != id) result,
            (taskId: id, placeName: original['lookup_place_name']! as String),
          ];
        case 'phone.map_open':
          page._mapResults = {...page._mapResults, id}.toList();
        case 'host.notes_to_todo' || 'host.find_draft' || 'host.compare_drafts' || 'host.receipts_to_sheet':
          page._notesResults = {...page._notesResults, id}.toList();
      }
    });
  }

  @override
  void startForeground(List<CompanionNotesForegroundCapture> captures, {required bool Function() isCurrent}) {
    // A popped selection route must actually leave the frame before this
    // original Page hands the fresh tasks to their existing detail owner.
    unawaited(() async {
      await WidgetsBinding.instance.endOfFrame;
      if (!this.isCurrent || !isCurrent() || !page._notesForegroundHere) return;
      final memory = page._memoryOwner;
      if (memory == null) return;
      final foregrounds = <CompanionNotesForegroundCapture>[
        for (final capture in captures)
          if (memory.store.hostTask(capture.task['task_id']! as String)?['task_rev'] == capture.task['task_rev'] &&
              memory.store.hostTask(capture.task['task_id']! as String)?['cancel_requested'] == 0 &&
              identical(capture.client, page.ref.read(activeConnectionProvider).value?.client) &&
              capture.task['host_key'] == companionHostKey(page.ref.read(activeHostProvider)))
            capture,
      ];
      if (foregrounds.isEmpty || !page.mounted) return;
      unawaited(
        Navigator.of(page.context).push(
          MaterialPageRoute<void>(
            builder: (_) => CompanionTasksPage(
              memory: memory,
              taskId: foregrounds.first.task['task_id']! as String,
              freshNotes: List<CompanionNotesForegroundCapture>.unmodifiable(foregrounds),
            ),
          ),
        ),
      );
    }());
  }
}

/// Her room's dark theme, one per palette and blur setting: a new one each build
/// would tell every widget under it the theme changed whenever the page rebuilds
/// (a streaming reply rebuilds it about thirty times a second).
final _darkThemes = <(AppAccent, bool), ThemeData>{};

ThemeData _darkTheme(AppAccent accent, bool blur) {
  if (_darkThemes.length > 4) _darkThemes.clear();
  return _darkThemes.putIfAbsent((accent, blur), () {
    final theme = buildDarkTheme(accent: accent, glassBlur: blur);
    return theme.copyWith(
      extensions: [
        for (final extension in theme.extensions.values)
          if (extension is DshSurfaces) companionWaterSurfaces(extension) else extension,
      ],
    );
  });
}

/// A new name for one of her moves: the dialog owns its field.
class _LabelDialog extends StatefulWidget {
  const _LabelDialog({required this.initial, required this.hint});

  final String initial;
  final String hint;

  @override
  State<_LabelDialog> createState() => _LabelDialogState();
}

class _LabelDialogState extends State<_LabelDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.companionMovesRename),
      content: TextField(
        controller: _field,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(onPressed: () => Navigator.pop(context, _field.text), child: Text(l10n.commonSave)),
      ],
    );
  }
}

/// 适配这个模型: what to tell her AI, and whether new models are fitted on
/// their own. The sheet owns its field.
class _AdaptSheet extends StatefulWidget {
  const _AdaptSheet({required this.adapted, required this.onRun, required this.onUndo});

  final bool adapted;
  final ValueChanged<String> onRun;
  final VoidCallback onUndo;

  @override
  State<_AdaptSheet> createState() => _AdaptSheetState();
}

class _AdaptSheetState extends State<_AdaptSheet> {
  final _note = TextEditingController();
  bool? _auto;

  @override
  void initState() {
    super.initState();
    unawaited(
      companionAdaptAuto().then((on) {
        if (mounted) setState(() => _auto = on);
      }),
    );
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const inset = EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 12);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.companionMenuAdapt),
              Padding(
                padding: inset,
                child: Text(l10n.companionAdaptHint, style: Theme.of(context).textTheme.bodySmall),
              ),
              Padding(
                padding: inset,
                child: TextField(
                  controller: _note,
                  minLines: 1,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: l10n.companionAdaptNote,
                    hintText: l10n.companionAdaptNoteHint,
                  ),
                ),
              ),
              SheetGroup(
                margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                children: [
                  SettingsTile(
                    tinted: false,
                    title: l10n.companionAdaptAuto,
                    chevron: false,
                    trailing: Switch(
                      value: _auto ?? true,
                      onChanged: _auto == null
                          ? null
                          : (on) {
                              setState(() => _auto = on);
                              unawaited(companionAdaptSetAuto(on));
                            },
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 16),
                child: Row(
                  children: [
                    if (widget.adapted) TextButton(onPressed: widget.onUndo, child: Text(l10n.companionAdaptUndo)),
                    const Spacer(),
                    FilledButton(onPressed: () => widget.onRun(_note.text), child: Text(l10n.companionAdaptRun)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
