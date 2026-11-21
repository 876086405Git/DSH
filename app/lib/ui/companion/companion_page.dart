// 伙伴小屋: a whole page for the companion (docs/design/companion.md). She fills
// the screen in a WebView; on top of it, in Flutter, her words and a small input.
// Touches are answered on the spot without a model call. Talking goes, in full
// mode, through an ordinary session on the active host (companion_state.dart);
// in light mode, straight from the phone to the model (companion_light.dart).

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../companion/companion_adapt.dart';
import '../../companion/companion_bond.dart';
import '../../companion/companion_context.dart';
import '../../companion/companion_initiative.dart';
import '../../companion/companion_initiative_owner.dart';
import '../../companion/companion_keeper.dart';
import '../../companion/companion_memory.dart';
import '../../companion/companion_memory_worker.dart';
import '../../companion/companion_host_memory_transport.dart';
import '../../companion/companion_host_tasks.dart';
import '../../companion/companion_late_use.dart';
import '../../companion/companion_moves.dart';
import '../../companion/companion_light.dart';
import '../../companion/companion_pack.dart';
import '../../companion/companion_public_lookup.dart';
import '../../companion/companion_recall_prefs.dart';
import '../../companion/companion_reply.dart';
import '../../companion/companion_reminder.dart';
import '../../companion/companion_signal_consent.dart';
import '../../companion/companion_signals.dart';
import '../../companion/companion_state.dart';
import '../../companion/companion_voice.dart';
import '../../companion/companion_voice_source.dart';
import '../../companion/companion_widget.dart';
import '../../l10n/l10n.dart';
import '../../notify/chat_alerts.dart' show CompanionAlertDelivery, companionHostKey;
import '../../pets/pet_mood.dart' show PetEvent, PetEventKind;
import '../../pets/pet_signals.dart' show petEventBusProvider;
import '../../pets/pet_state.dart';
import '../../speech/speech_settings.dart';
import '../../speech/voice_cloud.dart';
import '../../state/app_mode_state.dart';
import '../../state/app_notes.dart';
import '../../state/chat_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/run_pulse.dart' show estimateTokens;
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/voice_model_state.dart';
import '../../state/voice_settings.dart';
import '../../state/voice_state.dart';
import '../../usage/usage_stats.dart';
import '../chat/voice/voice_controller.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../modes/mode_switch.dart';
import '../settings/settings_widgets.dart';
import '../theme/accent.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/surfaces.dart';
import '../workshop/workshop_screen.dart';
import '../workspace/directory_picker.dart';
import 'companion_ask.dart';
import 'companion_chrome.dart';
import 'companion_log.dart';
import 'companion_memory_page.dart';
import 'companion_persona_page.dart';
import 'companion_voice_page.dart';
import 'companion_stage.dart';
import 'companion_tasks_page.dart';

/// The person removed her pack: the one inside the app waits to be asked for.
const _packRemovedKey = 'companion_pack_removed';
const _hintDoneKey = 'companion_touch_hint_done';
const _homeHintDoneKey = 'companion_home_hint_done';

final _sentenceEnd = RegExp(r'[。！？!?…~～]');

enum _Phase { checking, setup, stage, failed }

typedef CompanionStageBuilder = Widget Function(CompanionStageController controller, CompanionStageEvents events);
typedef _ReplyPart = ({AssistantChatItem item, int? retry});

class CompanionPage extends ConsumerStatefulWidget {
  const CompanionPage({super.key, this.storeOverride, this.stageBuilder, this.stageController, this.bundledPack});

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

class _CompanionPageState extends ConsumerState<CompanionPage> implements CompanionInitiativeRoom {
  late final _stage = widget.stageController ?? CompanionStageController();
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _random = Random();
  late final VoiceInputController _voice;

  CompanionPackStore? _store;
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

  // The conversation.
  String? _sessionId;
  ProviderSubscription<ChatState>? _chat;
  late HostRef _bindingHost;
  DshClient? _bindingClient;
  int _bindingEpoch = 0;

  /// Light or full when the page last bound (see _bindingChanged).
  late bool _boundLight;
  bool _sending = false;
  bool _running = false;
  bool _needsAttention = false;
  bool _asleep = false;

  /// What her session waits on the person for (an approval or a question),
  /// already looked up at: she reacts once to each.
  String? _askingSeen;

  /// The backlog is over her (companion_log.dart).
  bool _logOpen = false;

  /// What she's doing in her corner (the stage's word for it).
  String _home = 'idle';
  String? _baselineUser;
  bool _baselineSet = false;
  int _marksHandled = 0;
  int _wordsSpoken = 0;
  List<_ReplyPart> _replyParts = const [];
  String _replyWords = '';

  /// What happened in the room since she last heard from the person (C905):
  /// data for her next turn, never part of what the person said.
  List<CompanionContextEvent> _contextEvents = const [];
  int _eventSerial = 0;

  /// Light mode: when the person last spoke, when she was last told the time,
  /// and the context the reply on its way was asked with.
  DateTime? _lastSpokenAt;
  DateTime? _lastClockAt;
  CompanionTurnContext? _lightContext;

  /// Full mode: one plan per request id (a retried send reuses it, never a
  /// fresh one under the same id); its events are spent once the person's
  /// own message with that id is in the session.
  final Map<String, ({CompanionFullContextPlan plan, String profile})> _fullPlans = {};

  /// The profile this host last acknowledged, and for which connection,
  /// instance, session and host revision: anything else changing (another
  /// client writing its own, too) sends it again.
  ({Object client, String instanceId, String sessionId, int revision, String profile})? _ackProfile;

  /// This host can't take her context: said once per visit.
  bool _contextUnsupportedSaid = false;

  // Light mode: her conversation on this phone, and the reply on its way.
  CompanionLightHistory? _lightHistory;
  StreamSubscription<String>? _lightReply;
  Completer<void>? _lightSettled;
  http.Client? _lightClient;
  String _lightTurn = '';
  String _lightText = '';
  String _lightAsked = '';
  int _lightTurns = 0;
  CompanionMemoryOwner? _memoryOwner;
  Future<CompanionMemoryOwner>? _memoryOpening;
  MemoryRow? _retryMemorySource;
  Timer? _memoryQuiet;
  Timer? _hostUsageTimer;
  int _memoryControlRevision = 0;
  String? _memoryFollowupAttempt;
  int? _fullControlRevision;
  int? _lightControlRevision;
  String? _lightSourceId;
  String? _lightReceiptId;
  bool _lightReceiptFinalized = false;
  CompanionAuxiliaryCapability? _memoryRoute;
  DshClient? _memoryRouteClient;

  // Her state on the Host (null: this host can't keep it).
  CompanionSnapshot? _vitals;
  CompanionKeeper? _keeper;

  /// Light mode's keeper: her state and memories on this phone.
  CompanionKeeper? _phone;
  CompanionKeeper get _phoneKeeper => _phone ??= ref.read(companionPhoneKeeperProvider)(_store!.root);
  Future<void> _vitalsQueue = Future.value();

  // What's on screen.
  String? _bubble;
  List<({String taskId, String placeName})> _lookupResults = const [];
  List<String> _notesResults = const [];
  bool _bubbleIsError = false;
  String? _myLine;
  String? _lastLine;
  Timer? _bubbleTimer;
  String? _memoryFollowupTicket;
  // A submitted goodbye retires memory questions for this page visit only.
  // Ordinary conversation still permits a later, already invited followup.
  bool _memoryFollowupRetired = false;
  static final _memoryFarewell = RegExp(
    r'^(?:(?:晚安|再见)(?:[，,\s]+(?:我)?先走了)?|(?:我)?先走了|good ?night|goodbye|bye)[。.!！]*$',
    caseSensitive: false,
  );
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
  bool _ttsRanges = false;
  int _ttsSerial = 0;
  int _spokenTo = 0;
  final Map<String, int> _ttsPending = {};

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
  bool _accessible = false;
  bool _entered = false;
  bool _leaving = false;
  bool _observeQueued = false;

  @override
  void initState() {
    super.initState();
    // Anonymous usage statistics: the room was opened once more.
    ref.read(usageStatsProvider.notifier).count(UsageCount.room);
    _initiative = ref.read(companionInitiativeProvider);
    // How often she may speak up: the person's pick, followed as it changes.
    _initiative.pace = ref.read(companionInitiativePaceProvider);
    ref.listenManual(companionInitiativePaceProvider, (_, pace) => _initiative.pace = pace);
    // The gate keeps the owner's clocks, so a line's deadline means the same to both.
    _clock = ref.read(companionInitiativeClockProvider);
    _signals = CompanionSignalGate(
      monotonicMs: () => _clock().monoMs,
      utcNow: () => DateTime.fromMillisecondsSinceEpoch(_clock().wallMs, isUtc: true),
    );
    _lifecycle = AppLifecycleListener(
      onStateChange: (_) {
        _observeInitiative();
        _observeLateUse();
      },
    );
    _lateUseTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _observeLateUse();
      _observeInitiative();
      unawaited(_consolidateMemory());
    });
    _hostUsageTimer = Timer.periodic(const Duration(seconds: 15), (_) => _refreshHostChatUsage());
    ref.listenManual(companionSignalConsentProvider, (_, _) => _syncSignals());
    _bindingHost = ref.read(activeHostProvider);
    _bindingClient = ref.read(activeConnectionProvider).value?.client;
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
    ref.listenManual(companionEffectiveVoiceProvider, (_, settings) {
      if (settings != null) unawaited(_prepareVoice(settings));
    }, fireImmediately: true);
    _focus.addListener(_refreshMood);
    _input.addListener(_inputChanged);
    unawaited(_prepare());
  }

  Future<void> _resumeLookups(CompanionMemoryOwner memory) async {
    final sourceSession = _light ? memory.store.lightSessionId : 'full:$_recallHostKey';
    final pending = memory.store
        .tasks(sourceSessionId: sourceSession)
        .where(
          (task) => task['kind'] == 'public.lookup' && const ['queued', 'running', 'unknown'].contains(task['state']),
        )
        .toList();
    if (pending.isEmpty) {
      return;
    }
    final reminders = ref.read(companionRemindersProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    final hostKey = _recallHostKey;
    final key = ref.read(settingsProvider).apiKey;
    final factory = ref.read(companionLightClientProvider);
    final operation = () async {
      try {
        final executor = await reminders.executorId();
        for (final row in pending) {
          final task = memory.store.lookupTask(row['task_id']! as String)!;
          if (task['cancel_requested'] == 1) {
            await memory.lookups.stop(task, executorId: executor, host: client, hostKey: hostKey);
          } else {
            await memory.lookups.run(
              task,
              executorId: executor,
              requestId: companionMemoryId,
              estimateTokens: estimateCompanionMemoryTokens,
              host: client,
              hostKey: hostKey,
              direct: CompanionLookupDirect(
                client: factory,
                apiKey: () => key,
                nowMilliseconds: memory.lookups.nowMilliseconds,
                estimateTokens: estimateCompanionMemoryTokens,
              ),
            );
          }
        }
      } on Object {
        // A later visit can read the same persisted task; never replace an ID.
      }
    }();
    memory.retainReceipt(operation);
    await operation;
  }

  Future<void> _resumeNotes(CompanionMemoryOwner memory) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null) {
      return;
    }
    final hostKey = companionHostKey(ref.read(activeHostProvider));
    final sourceSession = _light ? memory.store.lightSessionId : 'full:$_recallHostKey';
    final tasks = memory.store
        .tasks(sourceSessionId: sourceSession)
        .where(
          (task) =>
              task['kind'] == 'host.notes_to_todo' &&
              task['host_key'] == hostKey &&
              const ['queued', 'waiting', 'running', 'unknown'].contains(task['state']),
        )
        .toList();
    for (final task in tasks) {
      try {
        await memory.hostTasks.run(task, client: client, hostKey: hostKey);
      } on Object {
        // Keep the original command and any possible dispatch. A later visit
        // can query the original store; this does not create a replacement.
      }
    }
  }

  Future<void> _prepare() async {
    final store =
        widget.storeOverride ??
        CompanionPackStore(Directory('${(await getApplicationSupportDirectory()).path}/companion'));
    final installed = await store.installed();
    final character = installed ? await store.character() : const CompanionCharacter();
    final bundled = await _hasBundled();
    final removed = (await SharedPreferences.getInstance()).getBool(_packRemovedKey) ?? false;
    if (!mounted) return;
    setState(() {
      _store = store;
      _character = character;
      _bundledHere = bundled;
      _phase = installed ? _Phase.stage : _Phase.setup;
    });
    unawaited(_prepareMemory());
    // The first time, the pack inside the app is unpacked while she swims over.
    // After the person removed it, it waits on the setup screen to be asked for.
    if (!installed && bundled && !removed) await _installBundled(arriving: true);
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
    // Leaving her: no invitation follows, and nothing comes back to this page.
    _leaving = true;
    _memoryQuiet?.cancel();
    _hostUsageTimer?.cancel();
    _memoryOwner?.leave(this);
    _memoryOwner?.removeListener(_memoryChanged);
    _initiative.leave(this);
    _lifecycle.dispose();
    unawaited(companionMarkSeen(DateTime.now()));
    // Leaving: drop the light request without touching the page any more.
    _retireLight(discard: true);
    _chat?.close();
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
    if (_ttsPending.isNotEmpty) _speaker.stop();
    _voiceNoticeTimer?.cancel();
    _agentPillTimer?.cancel();
    _voice.removeListener(_voiceChanged);
    _voice.dispose();
    _focus.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _openMemories() async {
    try {
      final memory = await _openMemory();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CompanionMemoryPage(memory: memory)));
    } on Object {
      if (mounted) _notice(context.l10n.companionMemoryLoadFailed);
    }
  }

  Future<void> _openTasks() async {
    try {
      final memory = await _openMemory();
      if (!mounted) return;
      final sourceSession = _light ? memory.store.lightSessionId : 'full:$_recallHostKey';
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CompanionTasksPage(memory: memory, sourceSessionId: sourceSession),
        ),
      );
    } on Object {
      if (mounted) _notice(context.l10n.companionMemoryLoadFailed);
    }
  }

  Future<void> _prepareMemory() async {
    try {
      await _openMemory();
    } on Object {
      if (mounted) _notice(context.l10n.companionMemoryLoadFailed);
    }
  }

  Future<CompanionMemoryOwner> _openMemory() => _memoryOpening ??= _readMemory().catchError((Object error) {
    _memoryOpening = null;
    throw error;
  });

  Future<CompanionMemoryOwner> _readMemory() async {
    final memory = await ref.read(companionMemoryOwnerProvider(_store!.root.absolute.path).future);
    if (!mounted) return memory;
    _memoryOwner = memory;
    _memoryControlRevision = memory.store.archive['control_revision']! as int;
    memory.addListener(_memoryChanged);
    await _initiative.attachMemory(memory.store);
    try {
      await memory.migrateLocal();
    } on Object {
      // A pending local migration retries on the next visit.
    }
    if (mounted) {
      _attachMemoryWorker();
      unawaited(ref.read(companionRemindersProvider).recover());
      unawaited(_clearMemoryWidget());
      if (_light) unawaited(_extractMemory(forceTail: true));
      if (!_light) {
        unawaited(_migrateHostMemory());
        final binding = ref.read(companionSessionsProvider.notifier).of(ref.read(activeHostProvider));
        if (_stageReady && binding != null) _bind(binding.sessionId);
      }
      _observeInitiative();
      unawaited(_resumeLookups(memory));
      unawaited(_resumeNotes(memory));
    }
    return memory;
  }

  Future<void> _migrateHostMemory() async {
    final memory = _memoryOwner;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (memory == null || client == null || _light) return;
    _refreshHostChatUsage();
    final hostKey = _recallHostKey;
    // A pending migration retries on the next visit; she just keeps working.
    try {
      await memory.migrateHost(client);
      await _retireLegacyRecall(client, hostKey);
    } on Object {
      // Retried on the next visit.
    }
  }

  void _refreshHostChatUsage() {
    if (!mounted || _leaving || _light) return;
    final memory = _memoryOwner;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (memory == null || client == null) return;
    unawaited(memory.refreshHostChatUsage(client, _recallHostKey).catchError((Object _) {}));
  }

  void _attachMemoryWorker() {
    final memory = _memoryOwner;
    if (memory == null) return;
    memory.leave(this);
    if (_light) {
      memory.enter(
        this,
        transport: () => CompanionLightMemoryTransport(
          apiKey: () => ref.read(settingsProvider).apiKey,
          client: ref.read(companionLightClientProvider),
        ),
        estimateTokens: estimateCompanionMemoryTokens,
      );
    } else {
      final route = _memoryRoute;
      final client = _memoryRouteClient;
      memory.enter(
        this,
        transport: () =>
            route == null ||
                client == null ||
                route.sessionId != _sessionId ||
                !identical(client, ref.read(activeConnectionProvider).value?.client)
            ? null
            : CompanionHostMemoryTransport(client: client, capability: route),
        estimateTokens: estimateCompanionMemoryTokens,
      );
    }
  }

  Future<void> _readMemoryRoute(String sessionId) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (client == null || _light) return;
    final current = _currentRoom();
    try {
      final route = await client.readCompanionAuxiliaryCapability(sessionId);
      if (!current() || _sessionId != sessionId) return;
      _memoryRoute = route;
      _memoryRouteClient = client;
      _attachMemoryWorker();
      if (route != null) unawaited(_extractMemory(forceTail: true));
    } on Object {
      // Memory waits for the next chance; nothing to tell her person about.
    }
  }

  Future<void> _extractMemory({bool forceTail = false}) async {
    final memory = _memoryOwner;
    if (memory == null || !mounted) return;
    try {
      await memory.extract(this, forceTail: forceTail);
    } on Object {
      // A batch that could not run stays queued for the next chance.
    }
  }

  void _queueMemoryExtraction() {
    _memoryQuiet?.cancel();
    unawaited(_extractMemory());
    _memoryQuiet = Timer(const Duration(minutes: 2), () => unawaited(_extractMemory(forceTail: true)));
  }

  Future<void> _consolidateMemory() async {
    final memory = _memoryOwner;
    if (!mounted || _leaving || memory == null || _invite != null || _memoryFollowupTicket != null) return;
    final view = _initiativeView();
    if (!view.visible || !view.resumed || view.blocked) return;
    try {
      await memory.consolidate(this);
    } on Object {
      // The original cards remain readable; a later idle opportunity can retry.
    }
  }

  void _memoryChanged() {
    final memory = _memoryOwner;
    if (!mounted || memory == null) return;
    final control = memory.store.archive['control_revision']! as int;
    if (control != _memoryControlRevision) {
      _memoryControlRevision = control;
      memory.cancelWork();
      _memoryQuiet?.cancel();
      _retireLight(discard: true);
      _hush();
      _lastLine = null;
      final oldSession = _sessionId;
      if (oldSession != null) unawaited(ref.read(chatProvider(oldSession).notifier).cancel());
      unawaited(_clearMemoryWidget());
      unawaited(ref.read(companionSessionsProvider.notifier).forgetAll());
      setState(_unbind);
      _queueMemoryExtraction();
    } else {
      setState(() {});
    }
    _observeInitiative();
  }

  Future<bool> _clearMemoryWidget() async {
    final memory = _memoryOwner;
    if (memory == null) return false;
    final cleared = await memory.clearWidget(ref.read(companionWidgetProvider));
    if (!cleared && mounted) _notice(context.l10n.companionMemoryWidgetPending);
    return cleared;
  }

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
    if (!_light) {
      final binding = ref.read(companionSessionsProvider.notifier).of(ref.read(activeHostProvider));
      if (binding != null) _bind(binding.sessionId);
    }
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
  Future<void> _arrive({bool greet = true}) async {
    final current = _currentRoom();
    // Light mode keeps her on this phone and asks no host for anything.
    final client = ref.read(activeConnectionProvider).value?.client;
    final CompanionKeeper? keeper = _light ? _phoneKeeper : (client == null ? null : HostKeeper(client));
    CompanionSnapshot? snapshot;
    if (keeper != null) {
      try {
        snapshot = await keeper.snapshot().timeout(const Duration(seconds: 3));
      } on Object {
        // Not this host, or not now: she's still here, just without memory of it.
      }
    }
    if (!current()) return;
    if (snapshot != null) {
      _keeper = keeper;
      _applyVitals(snapshot);
    }
    if (greet) await _greet(snapshot?.vitals.lastVisitAt, current);
    if (current() && snapshot != null) _event('visit');
  }

  void _applyVitals(CompanionSnapshot snapshot) {
    final before = _vitals;
    _vitals = snapshot;
    final v = snapshot.vitals;
    _stage.command('vitals', {'valence': v.valence, 'energy': v.energy, 'closeness': v.closeness});
    _stage.command('activity', {'name': v.activity, 'remainingMs': snapshot.activityLeft.inMilliseconds});
    _widgetUpdate();
    // A step closer while the person is here: a small moment, once, as it
    // happens. Arriving with it already reached is not news.
    if (before != null && before.storeId == snapshot.storeId) {
      final step = companionBond(v.closeness);
      if (step > companionBond(before.vitals.closeness)) _closer(step);
    }
  }

  void _closer(int step) {
    _stage.command('emotion', {'name': 'happy', 'hold': 3200});
    _stage.command('action', {'name': 'hop'});
    _remember('pet', '你觉得和对方又亲近了一些');
    if (!mounted || _running || _sending) return;
    final l10n = context.l10n;
    _say(switch (step) {
      1 => l10n.companionCloser1,
      2 => l10n.companionCloser2,
      _ => l10n.companionCloser3,
    });
  }

  /// One event at a time, against the state last read. A conflict reads again;
  /// it never sends the same event twice.
  void _event(String type) {
    final keeper = _keeper;
    if (keeper == null) return;
    final current = _currentRoom();
    _vitalsQueue = _vitalsQueue.then((_) async {
      if (!current() || !identical(keeper, _keeper)) return;
      final read = _vitals;
      if (read == null) return;
      try {
        try {
          final next = await keeper.event(read, type);
          if (current()) _applyVitals(next);
        } on DshRemoteException catch (error) {
          if (!current() || (!error.code.endsWith('conflict') && !error.code.endsWith('store-changed'))) return;
          final again = await keeper.snapshot();
          if (current() && again != null) _applyVitals(again);
        }
      } on Object {
        // The refresh can fail too. Keep the queue usable; never retry a write.
      }
    });
  }

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
    // Once they're close she has a fonder word too.
    final close = companionBond(_vitals?.vitals.closeness ?? 0) >= 2;
    final lines = switch ((zone, kind)) {
      (_, 'hug') => [l10n.companionHug1, l10n.companionHug2, l10n.companionHug3, if (close) l10n.companionHugClose],
      (_, 'tease') => [l10n.companionTease1, l10n.companionTease2, l10n.companionTease3],
      (_, 'shake') => [l10n.companionShake1, l10n.companionShake2, l10n.companionShake3],
      (_, 'pat') => [l10n.companionPat1, l10n.companionPat2, l10n.companionPat3, if (close) l10n.companionPatClose],
      ('head', _) => [l10n.companionTapHead1, l10n.companionTapHead2],
      ('face', _) => [l10n.companionTapFace1, l10n.companionTapFace2, l10n.companionTapFace3],
      ('tail', _) => [l10n.companionTapTail1, l10n.companionTapTail2, l10n.companionTapTail3],
      ('legs', _) => [l10n.companionTapLegs1, l10n.companionTapLegs2],
      _ => [l10n.companionTapBody1, l10n.companionTapBody2, l10n.companionTapBody3],
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
    final choices = lines.where((l) => l != _lastLine).toList();
    final line = choices[_random.nextInt(choices.length)];
    _lastLine = line;
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
    if (_vitals != null) {
      _event(id);
    } else {
      // No host to keep it: the page's own guess, so her corner still answers.
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
      'snack' => [l10n.companionSnack1, l10n.companionSnack2, l10n.companionSnack3],
      'play' => [l10n.companionPlay1, l10n.companionPlay2, l10n.companionPlay3],
      _ => [l10n.companionRest1, l10n.companionRest2],
    };
    final choices = lines.where((l) => l != _lastLine).toList();
    final line = choices[_random.nextInt(choices.length)];
    _lastLine = line;
    // After the snack has reached her, not before.
    _objectTimer?.cancel();
    _objectTimer = Timer(Duration(milliseconds: id == 'snack' ? 1700 : 900), () {
      if (mounted && !_running && !_sending) _say(line);
    });
  }

  /// A conversation of the person's (not hers) ended its turn, failed, or waits
  /// on them: when it is on the host in front, a pill offers the way there.
  /// Nothing more from here. Whether she mentions it is the signal gate's
  /// call (_onTaskSignal), and no note of it goes to the model: sharing one
  /// would take the person's yes for that item (C902), not built yet.
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
    final speech = _signals.speechCandidate(
      slot,
      language: Localizations.localeOf(context).languageCode == 'zh' ? 'zh' : 'en',
    );
    final line = speech == null ? null : _signalLine(signal);
    if (speech == null || line == null) return;
    final candidate = CompanionInitiativeSignal(
      id: speech.id,
      contextKey: _initiativeContext,
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

  /// Her words for a signal, in the app's language. Metadata only: no titles.
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
  void _remember(String kind, String? note) {
    if (note == null) return;
    final now = DateTime.now();
    _contextEvents = companionRecentEvents([
      ..._contextEvents,
      CompanionContextEvent(id: 'e-${now.microsecondsSinceEpoch}-${++_eventSerial}', kind: kind, at: now, detail: note),
    ], now: now);
  }

  /// Present one short line. [aloud]: with her voice, when it is on.
  void _say(String line, {bool aloud = true, bool widgetLine = true}) {
    _objectTimer?.cancel();
    if (!aloud || !_speakAloud(line, flush: true)) _stage.command('say', {'chars': line.length});
    _showBubble(line, hold: Duration(milliseconds: 2400 + line.length * 90));
    if (widgetLine) _widgetUpdate(line: line);
  }

  /// The home-screen widget: who she is, what she's doing, how well she knows
  /// the person, and [line] when she has just said something.
  void _widgetUpdate({String? line}) {
    if (!mounted) return;
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
        'bond': snapshot == null ? null : companionBond(snapshot.vitals.closeness),
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

  /// Her persona as the person has it, under the name she goes by.
  String _persona() {
    final persona = ref.read(companionPersonaProvider);
    return companionPersona(
      custom: persona.custom,
      name: ref.read(companionNameProvider) ?? _character.name,
      callMe: persona.callMe,
      moves: _moves.rules(),
    );
  }

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
  }

  /// Her own moves just became known: marks already in the reply on screen
  /// that only now read as marks were said before, not news to play.
  void _rebaseMarks() {
    if (!_baselineSet) return;
    final text = _light ? _lightText : _replyParts.map((part) => part.item.text).join('\n');
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

  bool get _voiceOn => _ttsReady && (ref.read(companionEffectiveVoiceProvider)?.on ?? false);

  /// Ready to speak with [settings] (or silent when they are off).
  Future<void> _prepareVoice(CompanionVoiceSettings settings) async {
    if (!settings.on) {
      _ttsReady = false;
      _hush();
      return;
    }
    final ready = await _speaker.ready(settings);
    if (mounted) _ttsReady = ready;
  }

  /// Reads [text] aloud when her voice is on; false when it isn't (then her
  /// mouth keeps the text's rhythm). [flush] replaces whatever she is saying.
  bool _speakAloud(String text, {bool flush = false}) {
    if (!_voiceOn || text.trim().isEmpty) return false;
    if (flush) _ttsPending.clear();
    final id = 'v${++_ttsSerial}';
    _ttsPending[id] = text.length;
    _speaker.speak(id, text, flush: flush);
    return true;
  }

  /// She stops talking at once: the person is typing, talking, stopping her or leaving.
  void _hush() {
    if (_ttsPending.isEmpty) return;
    _ttsPending.clear();
    _speaker.stop();
    _stage.command('quiet');
  }

  void _onTts(CompanionVoiceEvent event) {
    if (!mounted || !_ttsPending.containsKey(event.id)) return;
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

  void _showBubble(String text, {Duration? hold, bool error = false}) {
    _retireGreeting();
    _bubbleTimer?.cancel();
    _memoryFollowupTicket = null;
    setState(() {
      _bubble = text;
      _bubbleIsError = error;
      _lookupResults = const [];
      _notesResults = const [];
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
    inputBusy: _focus.hasFocus || _input.text.trim().isNotEmpty,
    generating: _sending || _running || _lightReply != null,
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
    if (!mounted || _leaving) return;
    final view = _initiativeView();
    if (_entered) {
      _initiative.observe(this, view);
    } else {
      _entered = true;
      _initiative.enter(this, view);
    }
    _requestMemoryFollowup(view);
  }

  /// A current invitation becomes one ordinary signal, in this room only.
  /// The captured source and window are checked again at the actual render.
  void _requestMemoryFollowup(CompanionInitiativeView view) {
    final memory = _memoryOwner;
    if (memory == null || _memoryFollowupRetired || !_presentable(view) || _initiative.fault != null) {
      return;
    }
    final now = _clock();
    MemoryRow? opportunity;
    try {
      opportunity = memory.store.nextFollowup(nowMs: now.wallMs);
    } on Object {
      // An optional local question must not interrupt ordinary chat on a read failure.
      return;
    }
    if (opportunity == null) return;
    final captured = opportunity;
    final attempt = '$_initiativeContext:${captured['id']}:${captured['row_rev']}:${captured['control_revision']}';
    if (_memoryFollowupAttempt == attempt) {
      return;
    }
    final candidate = CompanionInitiativeSignal(
      id: 'followup:${captured['id']}:${captured['row_rev']}:${captured['control_revision']}',
      contextKey: _initiativeContext,
      expiresAtMonoMs: now.monoMs + min(120000, (captured['expires_at_ms']! as int) - now.wallMs),
    );
    bool current() =>
        mounted &&
        !_leaving &&
        !_memoryFollowupRetired &&
        candidate.contextKey == _initiativeContext &&
        memory.store.isFollowupCurrent(captured, nowMs: _clock().wallMs);
    String? line;
    _initiative.requestSignal(
      this,
      view,
      candidate,
      followupId: captured['id']! as String,
      isCurrent: current,
      prepare: () async {
        _memoryFollowupAttempt = attempt;
        await ref.read(companionPersonaProvider.notifier).ready;
        if (!current() || !_presentable(_initiativeView())) {
          return false;
        }
        final persona = ref.read(companionPersonaProvider);
        line = await memory.followup(
          this,
          captured,
          persona: companionPersonaPart(
            custom: persona.custom,
            name: ref.read(companionNameProvider) ?? _character.name,
            callMe: persona.callMe,
          ),
          offsetMinutes: _clock().offsetMinutes,
          isCurrent: () {
            final now = _clock();
            return current() &&
                _presentable(_initiativeView()) &&
                now.monoMs < candidate.expiresAtMonoMs &&
                companionNightKey(now.wallMs, now.offsetMinutes) == null;
          },
        );
        return line != null;
      },
      present: (display) {
        if (!current() || line == null) {
          return false;
        }
        _say(line!, widgetLine: false);
        _memoryFollowupTicket = display.ticket.id;
        return true;
      },
      hide: _hideMemoryFollowup,
    );
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
    _memoryFollowupAttempt = null;
    _initiative.activate(this);
    _observeLateUse(interaction: true);
  }

  @override
  bool canPresent(CompanionInitiativeTicket ticket) =>
      mounted &&
      !_leaving &&
      // She greets in her own words when the person arrives; only invitations
      // and signal lines come here.
      ticket.kind != CompanionPromptKind.greeting &&
      // No invitation while the pill to another conversation is up.
      (ticket.kind != CompanionPromptKind.invite || _agentPill == null) &&
      ticket.contextKey == _initiativeContext &&
      _presentable(_initiativeView());

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
  bool Function() _currentRoom() {
    final epoch = _bindingEpoch;
    // A light conversation belongs to no host: only leaving the page or
    // switching modes (an unbind) ends what it started.
    if (_light) return () => mounted && epoch == _bindingEpoch;
    final host = ref.read(activeHostProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    return () =>
        mounted &&
        epoch == _bindingEpoch &&
        host == ref.read(activeHostProvider) &&
        identical(client, ref.read(activeConnectionProvider).value?.client);
  }

  void _bindingChanged() {
    final host = ref.read(activeHostProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    if (host == _bindingHost && identical(client, _bindingClient)) return;
    _bindingHost = host;
    _bindingClient = client;
    // Signals come from the active connection in either mode.
    _syncSignals();
    if (_memoryOwner case final memory?) {
      unawaited(_resumeNotes(memory));
    }
    // With no mode picked, a host coming or going turns her light or full.
    final light = _light;
    if (light != _boundLight) {
      _modeChanged();
      return;
    }
    // A light conversation isn't on any host: nothing to rebind.
    if (light) return;
    unawaited(_migrateHostMemory());
    setState(_unbind);
    final binding = ref.read(companionSessionsProvider.notifier).of(host);
    if (binding != null && _stageReady) _bind(binding.sessionId);
    if (_stageReady) unawaited(_arrive());
  }

  /// Only a conversation tagged with the current phone archive and control.
  void _bind(String sessionId) {
    final memory = _memoryOwner;
    if (memory == null) return;
    final binding = ref.read(companionSessionsProvider.notifier).of(ref.read(activeHostProvider));
    final archive = memory.store.archive;
    if (binding?.sessionId != sessionId ||
        binding?.memoryArchiveId != archive['id'] ||
        binding?.memoryControlRevision != archive['control_revision']) {
      return;
    }
    if (_sessionId == sessionId && _chat != null) return;
    _chat?.close();
    _sessionId = sessionId;
    _fullControlRevision = archive['control_revision']! as int;
    _baselineSet = false;
    _chat = ref.listenManual(chatProvider(sessionId), (_, next) => _onChat(next), fireImmediately: true);
    if (!_light) unawaited(_readMemoryRoute(sessionId));
  }

  void _unbind() {
    _bindingEpoch++;
    _greetingPending = true;
    _hush();
    if (_voice.active) unawaited(_voice.cancel());
    _bubbleTimer?.cancel();
    _settleTimer?.cancel();
    _objectTimer?.cancel();
    _vitals = null;
    _keeper = null;
    _vitalsQueue = Future.value();
    _chat?.close();
    _chat = null;
    _sessionId = null;
    _fullControlRevision = null;
    _sending = false;
    _running = false;
    _needsAttention = false;
    _askingSeen = null;
    _baselineSet = false;
    _marksHandled = 0;
    _wordsSpoken = 0;
    _replyParts = const [];
    _replyWords = '';
    _contextEvents = const [];
    _fullPlans.clear();
    _ackProfile = null;
    _memoryRoute = null;
    _memoryRouteClient = null;
    // The cleared host route cannot send; this room can still merge locally.
    if (!_light) _attachMemoryWorker();
    _bubble = null;
    _memoryFollowupTicket = null;
    _myLine = null;
    _home = 'idle';
    _asleep = false;
    _stage.command('quiet');
    _stage.command('activity', {'name': 'idle', 'remainingMs': 0});
    _stage.command('vitals', {'valence': 0.25, 'energy': 0.75, 'closeness': 0});
    _refreshMood();
    // A new room for the gate: what the old one let in goes with it.
    _syncSignals();
  }

  /// The words after the latest thing the person said.
  (String?, List<_ReplyPart>) _latestReply(ChatState state) {
    final tail = <ChatItem>[];
    String? user;
    for (final item in state.items.reversed) {
      if (item is UserChatItem) {
        user = item.key;
        break;
      }
      tail.add(item);
    }
    final parts = <_ReplyPart>[];
    int? retry;
    for (final item in tail.reversed) {
      if (item is NoticeChatItem && item.kind == 'retry') retry = item.seq;
      if (item is AssistantChatItem && item.text.isNotEmpty) parts.add((item: item, retry: retry));
    }
    return (user, parts);
  }

  void _onChat(ChatState state) {
    if (!mounted || _memoryOwner == null || _fullControlRevision != _memoryOwner!.store.archive['control_revision']) {
      return;
    }
    _spendCommitted(state);
    if (_running && !state.running && state.pending.isEmpty) _refreshHostChatUsage();
    final asking = state.openApproval?.eventId ?? state.questions.firstOrNull?.eventId;
    if (asking != _askingSeen) {
      // Something already waiting when the page opened is not news.
      if (asking != null && _baselineSet) {
        _stage.command('emotion', {'name': 'surprised', 'hold': 1600});
        _stage.command('action', {'name': 'lookUp'});
      }
      _askingSeen = asking;
    }
    final (user, parts) = _latestReply(state);
    _onReply(
      user,
      parts.map((part) => part.item.text).join('\n'),
      parts: parts,
      running: state.running || state.pending.isNotEmpty,
      attention: state.openApproval != null || state.questions.isNotEmpty,
      error: state.error,
      loading: state.loading,
    );
  }

  /// Keep progress only for the same full-mode assistant segments. A retry
  /// can replace a draft without publishing its empty interval to this page.
  void _retainReplyProgress(List<_ReplyPart> next) {
    final prefix = <String>[];
    for (var i = 0; i < min(_replyParts.length, next.length); i++) {
      final old = _replyParts[i];
      final current = next[i];
      // FinishChunk makes a draft nonstreaming too; only seq identifies a
      // durable message. Its row key is shared with the draft it commits.
      final commitsDraft = old.item.seq == null && current.item.seq != null && old.item.key == current.item.key;
      if (old.retry != current.retry || (old.item.id != current.item.id && !commitsDraft)) break;
      final before = old.item.text;
      final after = current.item.text;
      if (before == after) {
        prefix.add(before);
        continue;
      }
      var end = 0;
      while (end < min(before.length, after.length) && before.codeUnitAt(end) == after.codeUnitAt(end)) {
        end++;
      }
      prefix.add(before.substring(0, end));
      break;
    }
    final retainedText = prefix.join('\n');
    if (retainedText != _replyParts.map((part) => part.item.text).join('\n')) {
      final retained = parseCompanionReply(
        retainedText,
        streaming: true,
        emotions: _moves.emotionLabels,
        actions: _moves.actionLabels,
      );
      _marksHandled = min(_marksHandled, retained.marks.length);
      _wordsSpoken = min(_wordsSpoken, retained.words.length);
    }
    _replyParts = next;
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
      _showBubble(words);
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
    List<_ReplyPart>? parts,
  }) {
    if (!_baselineSet) {
      // What's already in the conversation has been said; only news moves her.
      if (loading) return;
      _baselineSet = true;
      _baselineUser = user;
      final old = parseCompanionReply(text, emotions: _moves.emotionLabels, actions: _moves.actionLabels);
      _marksHandled = old.marks.length;
      _wordsSpoken = old.words.length;
      _spokenTo = old.words.length;
      _replyParts = parts ?? const [];
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
      _spokenTo = 0;
      _replyParts = const [];
    }

    if (parts != null) _retainReplyProgress(parts);
    final reply = parseCompanionReply(
      text,
      streaming: running,
      emotions: _moves.emotionLabels,
      actions: _moves.actionLabels,
    );
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

    final fresh = reply.words.length - _wordsSpoken;
    final aloud = _voiceOn && error == null;
    if (fresh > 0) {
      // Read aloud, her mouth follows the voice instead of the text.
      if (!aloud) _stage.command('say', {'chars': fresh});
      if (_sentenceEnd.hasMatch(reply.words.substring(_wordsSpoken))) _stage.command('beat');
    }
    _wordsSpoken = reply.words.length;
    if (aloud) {
      // Whole sentences as they complete, the rest once the reply is in. A
      // retry can take words back; what was said stays said.
      if (_spokenTo > reply.words.length) _spokenTo = reply.words.length;
      final (sentences, to) = companionSpeakable(reply.words, _spokenTo, final_: !running);
      _spokenTo = to;
      if (sentences.isNotEmpty) _speakAloud(sentences);
    }
    _showReplyWords(reply.words, fresh);

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
        _showBubble(error, hold: const Duration(seconds: 6), error: true);
      } else if (reply.words.isNotEmpty) {
        _widgetUpdate(line: reply.words.length > 80 ? '${reply.words.substring(0, 79)}…' : reply.words);
        _bubbleTimer?.cancel();
        _bubbleTimer = Timer(Duration(milliseconds: 9000 + reply.words.length * 60), () {
          if (mounted) setState(() => _bubble = null);
        });
      }
    }

    setState(() {
      _running = running;
      _needsAttention = attention;
    });
  }

  bool _isMemoryControl(String input) =>
      _memoryOwner != null && parseMemoryControl(input, _memoryOwner!.store.cards()) != null;

  bool _isReminderControl(Iterable<CompanionReminderPart> parts) =>
      parts.any((part) => part.command != null && part.command!.operation != 'create');

  bool _isTaskControl(String input) {
    final parts = parseCompanionReminders(input);
    return _isReminderControl(parts) ||
        parts.any(
          (part) =>
              parseCompanionLookup(part.raw)?['operation'] == 'cancel' ||
              parseCompanionNotes(part.raw)?['operation'] == 'cancel',
        );
  }

  Future<bool> _handleMemoryControl(CompanionMemoryOwner memory, MemoryRow source, String raw) async {
    final cards = memory.store.cards(includeInactive: true);
    final control = parseMemoryControl(raw, cards, topicControls: memory.store.topicControls());
    if (control == null) return false;
    final l10n = context.l10n;
    final kind = control['kind']! as String;
    var hostSourceRemoved = false;
    if (control['ambiguous'] == true) {
      memory.store.finishUnresolvedControl(
        messageId: source['id']! as String,
        expectedSourceRev: source['source_rev']! as int,
      );
    } else if (kind == 'correct') {
      final card = cards.singleWhere((row) => row['id'] == control['target_card_id']);
      memory.store.correctFromMessage(
        cardId: card['id']! as String,
        expectedRowRev: card['row_rev']! as int,
        messageId: source['id']! as String,
        expectedSourceRev: source['source_rev']! as int,
        text: control['replacement_text']! as String,
      );
    } else {
      final hostSources = control['delete_chat'] == true
          ? {
              for (final row in memory.store.messages())
                if ((row['session_id']! as String).startsWith('full:')) row['id']! as String,
            }
          : <String>{};
      memory.store.applyControl(
        topicIds: (control['topic_ids']! as List).cast<String>(),
        kind: kind,
        controlMessageId: source['id']! as String,
        deleteChat: control['delete_chat'] == true,
      );
      if (hostSources.isNotEmpty) {
        final remaining = memory.store.messages().map((row) => row['id']).toSet();
        hostSourceRemoved = hostSources.any((id) => !remaining.contains(id));
      }
    }
    _retryMemorySource = null;
    memory.changed();
    final current = _currentRoom();
    final cleared = await memory.clearWidget(ref.read(companionWidgetProvider));
    if (!current()) return true;
    final line = control['ambiguous'] == true
        ? l10n.companionMemoryWhich
        : switch (kind) {
            'forget' => l10n.companionMemoryForgotten,
            'never' => l10n.companionMemoryNeverDone,
            'less' => l10n.companionMemoryLessDone,
            'normal' => l10n.companionMemoryNormalDone,
            'cancel' => l10n.companionMemoryCancelledDone,
            'postpone' => l10n.companionMemoryPostponedDone,
            _ => l10n.companionMemoryCorrected,
          };
    // A local acknowledgement must not write a fresh widget line immediately
    // after the control deliberately cleared both persisted fields.
    _say(line, widgetLine: false);
    if (!cleared) _notice(l10n.companionMemoryWidgetPending);
    if (hostSourceRemoved) _notice(l10n.companionMemoryHostSourceRemaining);
    _queueMemoryExtraction();
    return true;
  }

  Future<void> _send() async {
    // What the person typed, exactly; trimmed only to see it isn't empty.
    final raw = _input.text;
    final text = raw.trim();
    final reminderParts = parseCompanionReminders(raw);
    final reminder = reminderParts.any((part) => part.command != null);
    final lookupCommands = {for (final part in reminderParts) part.itemNo: parseCompanionLookup(part.raw)};
    final lookup = lookupCommands.values.any((command) => command != null);
    final notesCommands = {for (final part in reminderParts) part.itemNo: parseCompanionNotes(part.raw)};
    final notes = notesCommands.values.any((command) => command != null);
    final reminderClock =
        reminderParts.any((part) => part.command != null && part.command!.operation != 'clarify') ||
        lookupCommands.values.any((command) => command != null && command['operation'] != 'clarify') ||
        notesCommands.values.any((command) => command != null && command['operation'] != 'clarify');
    final control =
        _isMemoryControl(raw) ||
        _isReminderControl(reminderParts) ||
        lookupCommands.values.any((command) => command?['operation'] == 'cancel') ||
        notesCommands.values.any((command) => command?['operation'] == 'cancel');
    if (text.isEmpty || ((_sending || _lightReply != null) && !control)) return;
    if (control) {
      _retireLight(discard: true);
      final oldSession = _sessionId;
      if (oldSession != null) unawaited(ref.read(chatProvider(oldSession).notifier).cancel());
      setState(_unbind);
    }
    _acted();
    _hush();
    _retireGreeting();
    if (_voice.active) unawaited(_voice.cancel());
    final current = _currentRoom();
    final submittedAt = DateTime.now();
    _bubbleTimer?.cancel();
    _objectTimer?.cancel();
    setState(() {
      _sending = true;
      _bubble = null;
      _myLine = text;
    });
    _stage.command('mood', {'mood': 'thinking'});
    try {
      CompanionReminderClock? clock;
      if (reminderClock && _retryMemorySource?['text'] != raw) {
        clock = await ref.read(companionRemindersProvider).clock();
      }
      final memory = await _openMemory();
      if (!current()) return;
      final sourceSession = _light ? memory.store.lightSessionId : 'full:$_recallHostKey';
      final retry = _retryMemorySource;
      final reuse =
          retry != null &&
          retry['text'] == raw &&
          retry['session_id'] == sourceSession &&
          (retry['first_seq']! as int) > (memory.store.archive['history_after_seq']! as int);
      if (reminderClock && !reuse && clock == null) {
        clock = await ref.read(companionRemindersProvider).clock();
        if (!current()) return;
      }
      final source = _retryMemorySource = reuse
          ? retry
          : memory.store.submitMessage(
              id: companionMemoryId(),
              sessionId: sourceSession,
              text: raw,
              saidAtUtc: clock?.utcMs ?? submittedAt.toUtc().millisecondsSinceEpoch,
              offsetMinutes: clock == null ? submittedAt.timeZoneOffset.inMinutes : clock.offsetSeconds ~/ 60,
              zoneId: clock?.zoneId,
              offsetSeconds: clock?.offsetSeconds,
            );
      // Only the person's complete submitted statement can retire this visit;
      // a failed source transaction must not retire its pending question.
      if (_memoryFarewell.hasMatch(raw.trim())) {
        _memoryFollowupRetired = true;
      }
      // Do not clear the composer's only copy before SQLite commits. If the
      // person typed ahead during opening, preserve that new draft too.
      if (_input.text == raw) _input.clear();
      if (reminder || lookup || notes) {
        await _handleTasks(memory, source, reminderParts, lookupCommands, notesCommands, current);
        return;
      }
      if (await _handleMemoryControl(memory, source, raw)) return;
      if (!current()) return;
      _queueMemoryExtraction();
      if (_light) {
        await _sendLight(raw, source, current);
        return;
      }
      final sessions = ref.read(companionSessionsProvider.notifier);
      final binding = await sessions.ensure(
        memoryArchiveId: memory.store.archive['id']! as String,
        memoryControlRevision: memory.store.archive['control_revision']! as int,
      );
      if (!current()) return;
      _bind(binding.sessionId);
      final chat = ref.read(chatProvider(binding.sessionId).notifier);
      if (!await chat.waitForSync(isCurrent: current)) throw const DshClosedException('not synced');
      if (!current()) return;
      // A host without her preset at all: the persona goes once, in front of
      // the first line, or she'd be no one (the oldest hosts only).
      final firstInline = binding.inlinePersona && ref.read(chatProvider(binding.sessionId)).items.isEmpty;
      final client = ref.read(activeConnectionProvider).value?.client;
      // Her name, persona and moves go to the host as context (C905), sent
      // only when they change; the time and what just happened go beside the
      // message under its own id. A host without that gets the text alone.
      // Nor does a conversation without her preset take context later on.
      final capability = binding.inlinePersona || client == null
          ? null
          : await client.companionPromptCapability(binding.sessionId);
      if (!current()) return;
      if (capability == null) _contextUnsupported(phoneMemoryOnly: firstInline);
      final profile = _contextProfile();
      final sent = await chat.send(
        firstInline ? '${appNote('（从现在起请扮演下面的角色，直接开始，不要复述这段设定。）\n${_persona()}')}\n$raw' : raw,
        verbatim: true,
        deliveryAllowed: () => current() && binding.memoryControlRevision == memory.store.archive['control_revision'],
        beforeDeliver: capability == null || client == null
            ? null
            : (requestId) => _prepareContext(client, capability, binding.sessionId, requestId, raw, profile, current),
      );
      if (!current()) return;
      if (!sent) throw StateError(ref.read(chatProvider(binding.sessionId)).error ?? 'send');
      _retryMemorySource = null;
    } on Object catch (error) {
      if (!current() || !mounted) return;
      if (_input.text.isEmpty) _input.text = raw;
      _stage.command('emotion', {'name': 'worried', 'hold': 3000});
      setState(() => _myLine = null);
      _showBubble(
        reminder
            ? companionReminderFailure(context.l10n, error)
            : lookup
            ? context.l10n.companionLookupSaveFailed
            : notes
            ? context.l10n.companionNotesSaveFailed
            : _failureText(error),
        hold: const Duration(seconds: 6),
        error: true,
      );
    } finally {
      if (current()) {
        setState(() => _sending = false);
        _refreshMood();
      }
    }
  }

  Future<void> _handleTasks(
    CompanionMemoryOwner memory,
    MemoryRow source,
    List<CompanionReminderPart> parts,
    Map<int, MemoryRow?> lookupCommands,
    Map<int, MemoryRow?> notesCommands,
    bool Function() current,
  ) async {
    final reminders = ref.read(companionRemindersProvider);
    final l10n = context.l10n;
    final roomMode = _light ? 'light' : 'full';
    final hostKey = _light ? null : _recallHostKey;
    final hostSession = _light ? null : _sessionId;
    final operation = () async {
      final lines = <String>[];
      final lookups = <({String taskId, String placeName})>[];
      final notes = <String>[];
      var failed = false;
      for (final part in parts) {
        final command = part.command;
        if (command == null) {
          final lookup = lookupCommands[part.itemNo];
          if (lookup != null) {
            try {
              final result = await _handleLookup(memory, source, part.itemNo, lookup, current);
              lines.add(result.line);
              if (result.task case final task?) {
                lookups.add((taskId: task['task_id']! as String, placeName: task['lookup_place_name']! as String));
              }
            } on Object {
              failed = true;
              lines.add(l10n.companionLookupSaveFailed);
            }
          } else if (notesCommands[part.itemNo] case final notesCommand?) {
            try {
              final result = await _handleNotes(memory, source, part.itemNo, notesCommand, current);
              lines.add(result.line);
              if (result.task case final task?) {
                notes.add(task['task_id']! as String);
              }
            } on Object {
              failed = true;
              lines.add(l10n.companionNotesSaveFailed);
            }
          } else if (part.raw.isNotEmpty) {
            lines.add(l10n.companionReminderUnhandled(part.raw));
          }
          continue;
        }
        if (command.operation == 'clarify') {
          lines.add(l10n.companionReminderSyntax);
          continue;
        }
        final accepted = memory.store.taskForCommand(source['id']! as String, part.itemNo);
        final previous = command.operation == 'create' || accepted != null
            ? null
            : reminders.target(memory.store, source['session_id']! as String, command);
        if (command.operation != 'create' && accepted == null && previous == null) {
          lines.add(l10n.companionReminderWhich);
          continue;
        }
        try {
          final result = await reminders.submit(
            store: memory.store,
            source: source,
            part: part,
            roomMode: roomMode,
            hostKey: hostKey,
            hostSessionId: hostSession,
            previous: previous,
            isCurrent: current,
          );
          if (result.task['task_rev'] != result.acceptedRev) {
            lines.add(l10n.companionTaskChanged);
          } else {
            final title = result.task['reminder_text'] as String?;
            final status = companionReminderLine(l10n, result.task, executorId: result.executorId);
            lines.add('${title == null || title.isEmpty ? '' : '$title：'}$status');
          }
        } on Object catch (error) {
          failed = true;
          lines.add(companionReminderFailure(l10n, error));
        }
      }
      memory.changed();
      return (lines: lines, failed: failed, lookups: lookups, notes: notes);
    }();
    memory.retainReceipt(operation.then<void>((_) {}));
    final result = await operation;
    if (!current()) return;
    if (result.failed) {
      if (_input.text.isEmpty) {
        _input.text = source['text']! as String;
      }
    } else {
      _retryMemorySource = null;
    }
    _say(result.lines.join('\n'));
    setState(() {
      _lookupResults = result.lookups;
      _notesResults = result.notes;
    });
    _queueMemoryExtraction();
  }

  Future<({String line, MemoryRow? task})> _handleNotes(
    CompanionMemoryOwner memory,
    MemoryRow source,
    int itemNo,
    MemoryRow command,
    bool Function() current,
  ) async {
    final l10n = context.l10n;
    if (command['operation'] == 'clarify') {
      return (line: l10n.companionNotesSyntax, task: null);
    }
    final host = ref.read(activeHostProvider);
    final hostKey = companionHostKey(host);
    final client = ref.read(activeConnectionProvider).value?.client;
    final light = _light;
    // A light room itself has no Host binding. Its explicit computer task
    // still captures the selected Host throughout directory selection.
    bool sameRoomAndHost() =>
        current() &&
        host == ref.read(activeHostProvider) &&
        identical(client, ref.read(activeConnectionProvider).value?.client);
    final accepted = memory.store.taskForCommand(source['id']! as String, itemNo);
    CompanionTasksCapability? capability;
    MemoryRow task;
    if (accepted != null) {
      task = memory.store.hostTask(accepted['task_id']! as String)!;
    } else if (command['operation'] == 'cancel') {
      final targets = memory.store
          .tasks(sourceSessionId: source['session_id']! as String)
          .where(
            (row) =>
                row['kind'] == 'host.notes_to_todo' &&
                row['cancel_requested'] == 0 &&
                const ['queued', 'waiting', 'running', 'unknown'].contains(row['state']),
          )
          .map((row) => memory.store.hostTask(row['task_id']! as String)!)
          .where(
            (row) =>
                command['outputName'] == null ||
                ((row['agreement']! as Map)['args']! as Map)['outputName'] == command['outputName'],
          )
          .toList();
      if (targets.length != 1) {
        return (line: l10n.companionNotesWhich, task: null);
      }
      if (!current()) {
        throw const DshClosedException('room changed before accepting task cancellation');
      }
      task = memory.store.cancelNotesTask(
        taskId: targets.single['task_id']! as String,
        expectedTaskRev: targets.single['task_rev']! as int,
        messageId: source['id']! as String,
        expectedSourceRev: source['source_rev']! as int,
        itemNo: itemNo,
      );
    } else {
      if (client == null) {
        return (line: l10n.companionNotesConnect, task: null);
      }
      final agreement = await companionNotesAgreement(source, command, ref.read(companionRemindersProvider));
      if (!sameRoomAndHost()) {
        throw const DshClosedException('room changed before task selection');
      }
      if (agreement == null) {
        return (line: l10n.companionNotesDateMissing, task: null);
      }
      capability = await client.readCompanionTasksCapability();
      if (!sameRoomAndHost()) {
        throw const DshClosedException('room changed before task selection');
      }
      if (capability == null || !capability.notes) {
        return (line: l10n.companionNotesUnavailable, task: null);
      }
      if (!mounted) throw const DshClosedException('room changed before task selection');
      final path = await showDirectoryPicker(context, title: l10n.companionNotesChooseDirectory);
      if (!sameRoomAndHost()) {
        throw const DshClosedException('room changed during directory selection');
      }
      if (path == null) {
        return (line: l10n.companionNotesNoDirectory, task: null);
      }
      final bound = await client.bindCompanionNotesDirectory(capability, path);
      String? session;
      if (!sameRoomAndHost()) {
        throw const DshClosedException('room changed before accepting notes task');
      }
      if (!light) {
        final binding = await ref
            .read(companionSessionsProvider.notifier)
            .ensure(
              memoryArchiveId: memory.store.archive['id']! as String,
              memoryControlRevision: memory.store.archive['control_revision']! as int,
            );
        session = binding.sessionId;
      }
      if (!sameRoomAndHost()) {
        throw const DshClosedException('room changed before accepting notes task');
      }
      task = memory.store.createNotesTaskFromMessage(
        messageId: source['id']! as String,
        expectedSourceRev: source['source_rev']! as int,
        itemNo: itemNo,
        roomMode: light ? 'light' : 'full',
        hostKey: hostKey,
        hostSessionId: session,
        directoryLabels: {'source': bound['displayPath'], 'output': bound['displayPath']},
        agreement: {
          'args': {
            'folderRef': bound['folderRef'],
            'localDate': agreement['localDate'],
            'timeZone': agreement['timeZone'],
            'dateBy': 'modified',
            'outputDirRef': bound['folderRef'],
            'outputName': agreement['outputName'],
            'writeMode': 'createNew',
          },
          'deadlineAtMs': agreement['deadlineAtMs'],
          'afterExit': agreement['afterExit'],
          'allowQueue': agreement['allowQueue'],
        },
      );
    }
    memory.changed();
    if (client == null || hostKey != task['host_key']) {
      return (line: l10n.companionNotesOriginalHost, task: task);
    }
    task = await memory.hostTasks.run(
      task,
      client: client,
      hostKey: hostKey,
      initialOpportunity: accepted == null,
      submitPending: true,
      capability: capability,
    );
    return (line: companionNotesLine(l10n, task), task: task);
  }

  Future<({String line, MemoryRow? task})> _handleLookup(
    CompanionMemoryOwner memory,
    MemoryRow source,
    int itemNo,
    MemoryRow command,
    bool Function() current,
  ) async {
    final l10n = context.l10n;
    if (command['operation'] == 'clarify') {
      return (line: l10n.companionLookupSyntax, task: null);
    }
    final accepted = memory.store.taskForCommand(source['id']! as String, itemNo);
    final reminders = ref.read(companionRemindersProvider);
    final light = _light;
    final hostKey = light ? null : _recallHostKey;
    final client = light ? null : ref.read(activeConnectionProvider).value?.client;
    final sessions = ref.read(companionSessionsProvider.notifier);
    final key = ref.read(settingsProvider).apiKey;
    final factory = ref.read(companionLightClientProvider);
    final executor = await reminders.executorId();
    MemoryRow task;
    if (accepted != null) {
      task = memory.store.lookupTask(accepted['task_id']! as String)!;
    } else if (command['operation'] == 'cancel') {
      final targets = memory.store
          .tasks(sourceSessionId: source['session_id']! as String)
          .where(
            (row) =>
                row['kind'] == 'public.lookup' &&
                row['cancel_requested'] == 0 &&
                const ['queued', 'waiting', 'running', 'unknown'].contains(row['state']) &&
                (command['placeName'] == null || command['placeName'] == row['lookup_place_name']),
          )
          .toList();
      if (targets.length != 1) {
        return (line: l10n.companionLookupWhich, task: null);
      }
      if (targets.single['executor_id'] != executor) {
        return (line: l10n.companionLookupNotHere, task: null);
      }
      if (!current()) {
        throw const DshClosedException('room changed before accepting lookup cancellation');
      }
      task = memory.store.cancelLookup(
        taskId: targets.single['task_id']! as String,
        expectedTaskRev: targets.single['task_rev']! as int,
        messageId: source['id']! as String,
        expectedSourceRev: source['source_rev']! as int,
        itemNo: itemNo,
      );
    } else {
      final agreement = companionLookupAgreement(source, command);
      if (agreement['waitReason'] != null) {
        return (
          line: agreement['waitReason'] == 'zone_missing'
              ? l10n.companionLookupZoneMissing
              : l10n.companionLookupDateMissing,
          task: null,
        );
      }
      String? hostSession;
      if (!light) {
        final binding = await sessions.ensure(
          memoryArchiveId: memory.store.archive['id']! as String,
          memoryControlRevision: memory.store.archive['control_revision']! as int,
        );
        hostSession = binding.sessionId;
      }
      if (!current()) {
        throw const DshClosedException('room changed before accepting lookup');
      }
      task = memory.store.createLookupFromMessage(
        messageId: source['id']! as String,
        expectedSourceRev: source['source_rev']! as int,
        itemNo: itemNo,
        roomMode: light ? 'light' : 'full',
        hostKey: hostKey,
        hostSessionId: hostSession,
        executorId: executor,
        lookup: CompanionLookupSpec(
          placeName: agreement['placeName']! as String,
          city: agreement['city'] as String?,
          localDate: agreement['localDate']! as String,
          zoneId: agreement['zoneId']! as String,
          question: agreement['question']! as String,
          deadlineAtMs: agreement['deadlineAtMs']! as int,
        ),
      );
      memory.changed();
      if (current()) {
        _say(l10n.companionLookupAccepted, widgetLine: false);
      }
    }
    if (task['cancel_requested'] == 1) {
      await memory.lookups.stop(task, executorId: executor, host: client, hostKey: hostKey);
      task = memory.store.lookupTask(task['task_id']! as String)!;
    } else {
      task = await memory.lookups.run(
        task,
        executorId: executor,
        requestId: companionMemoryId,
        estimateTokens: estimateCompanionMemoryTokens,
        host: client,
        hostKey: hostKey,
        direct: CompanionLookupDirect(
          client: factory,
          apiKey: () => key,
          nowMilliseconds: memory.lookups.nowMilliseconds,
          estimateTokens: estimateCompanionMemoryTokens,
        ),
      );
    }
    memory.changed();
    return (line: companionLookupLine(l10n, task, executorId: executor), task: task);
  }

  /// Who she is to this host: persona, name, what she calls the person, her
  /// own moves. Sent when it differs from what the host acknowledged.
  CompanionContextProfile _contextProfile() {
    final persona = ref.read(companionPersonaProvider);
    String cap(String text, int most) {
      if (text.runes.length <= most) return text;
      final cut = String.fromCharCodes(text.runes.take(most));
      final space = cut.lastIndexOf(' ');
      return space > 0 ? cut.substring(0, space) : cut;
    }

    return CompanionContextProfile(
      persona: cap(persona.custom.trim(), 4000),
      name: cap((ref.read(companionNameProvider) ?? _character.name ?? '').replaceAll(RegExp(r'\s+'), ' ').trim(), 24),
      callMe: cap(persona.callMe.replaceAll(RegExp(r'\s+'), ' ').trim(), 40),
      moves: cap(_moves.rules() ?? '', 1024),
    );
  }

  /// Runs inside the send, once its request id is chosen: the plan for that
  /// id (kept for a retry), and the host told what changed. False: the room
  /// left this conversation meanwhile, so the line is not sent there.
  Future<bool> _prepareContext(
    DshClient client,
    CompanionPromptCapability capability,
    String sessionId,
    String requestId,
    String raw,
    CompanionContextProfile profile,
    bool Function() current,
  ) async {
    if (!current()) return false;
    final memory = _memoryOwner!;
    final ack = _ackProfile;
    // A retry sends the plan it made first, and the profile in it.
    final entry = _fullPlans[requestId] ??= (
      plan: companionFullContextPlan(
        text: raw,
        sessionId: sessionId,
        requestId: requestId,
        profile: profile,
        supported: true,
        now: DateTime.now(),
        instanceId: capability.instanceId,
        profileRevision: capability.profileRevision,
        acknowledgedProfile:
            ack != null &&
                identical(ack.client, client) &&
                ack.instanceId == capability.instanceId &&
                ack.sessionId == sessionId &&
                ack.revision == capability.profileRevision
            ? ack.profile
            : null,
        events: _contextEvents,
        memoryMode: capability.memoryMode,
        recall: false,
        phoneMemory: capability.phoneMemory ? memory.phoneContext(memory.select(raw)) : null,
      ),
      profile: profile.fingerprint,
    );
    while (_fullPlans.length > 8) {
      _fullPlans.remove(_fullPlans.keys.first);
    }
    final update = entry.plan.update;
    if (!capability.phoneMemory) _contextUnsupported(phoneMemoryOnly: true);
    if (update == null) return true;
    final selected = update['phoneMemory'] as Map<String, Object?>?;
    if (selected != null && selected['controlRevision'] != memory.store.archive['control_revision']) return false;
    final CompanionPromptCapability answer;
    try {
      answer = await client.prepareCompanionPromptContext(update);
    } on DshRemoteException catch (error) {
      if (error.code != 'companion/memory-context-stale' && error.code != 'companion/context-restarted') rethrow;
      // Preparation rejected before prompt delivery: a restarted host no
      // longer owns this old phone context. Keep the original source for the
      // person's next explicit send, which will create a clean conversation.
      if (!current()) return false;
      await ref.read(companionSessionsProvider.notifier).forget();
      if (!current()) return false;
      setState(_unbind);
      if (_input.text.isEmpty) _input.text = raw;
      if (mounted) _notice(context.l10n.companionMemoryHostRestarted);
      return false;
    }
    if (answer.profileAccepted == true && update.containsKey('profile')) {
      _ackProfile = (
        client: client,
        instanceId: answer.instanceId,
        sessionId: sessionId,
        revision: answer.profileRevision,
        profile: entry.profile,
      );
    }
    if (!current() || (selected != null && selected['controlRevision'] != memory.store.archive['control_revision'])) {
      return false;
    }
    if (answer.chatUsage && selected != null) {
      memory.store.rememberHostChatDelivery(
        hostKey: _recallHostKey,
        instanceId: answer.instanceId,
        sessionId: sessionId,
        requestId: requestId,
        archiveId: selected['archiveId']! as String,
        controlRevision: selected['controlRevision']! as int,
        historyAfterSeq: selected['historyAfterSeq']! as int,
        observedAt: DateTime.now().millisecondsSinceEpoch,
      );
      _refreshHostChatUsage();
    }
    return true;
  }

  /// The person's own message with a plan's id is in the session: what that
  /// plan carried is spent. Events that came since stay for the next one.
  void _spendCommitted(ChatState state) {
    if (_fullPlans.isEmpty) return;
    final committed = {
      for (final item in state.items)
        if (item is UserChatItem && item.sourceKind == 'user' && item.requestId != null) item.requestId!,
    };
    for (final id in [..._fullPlans.keys]) {
      if (!committed.contains(id)) continue;
      _contextEvents = companionConsumeEvents(_contextEvents, _fullPlans.remove(id)!.plan.eventIds);
    }
  }

  void _contextUnsupported({bool phoneMemoryOnly = false}) {
    if (_contextUnsupportedSaid || !mounted) return;
    _contextUnsupportedSaid = true;
    _notice(phoneMemoryOnly ? context.l10n.companionMemoryHostUnsupported : context.l10n.companionContextUnsupported);
  }

  /// A word from the app (not from her) in the pill above her words.
  void _notice(String text) {
    if (!mounted) return;
    _voiceNoticeTimer?.cancel();
    setState(() => _voiceNotice = text);
    _voiceNoticeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _voiceNotice = null);
    });
  }

  // Old host recall is only retired. New conversations use phone selection.
  String get _recallHostKey => companionHostKey(ref.read(activeHostProvider));

  Future<void> _retireLegacyRecall(DshClient client, String hostKey) async {
    final stored = await companionRecallStored(hostKey);
    if (stored == null) return;
    if (!stored.off) {
      final caps = await client.readCompanionRecallCapabilities();
      if (caps == null) throw const DshClosedException('legacy recall cleanup pending');
      try {
        await client.revokeCompanionRecall(caps, operationId: newCompanionRecallId(), bindingId: stored.bindingId);
      } on DshRemoteException catch (error) {
        if (!error.code.endsWith('not-found') && !error.code.endsWith('retired')) rethrow;
      }
    }
    // Only an actual retirement receipt (or an already retired record) lets
    // the phone discard its cleanup identity. No new binding is established.
    await companionRecallClear(hostKey, stored.bindingId);
  }

  String _failureText(Object error) {
    final l10n = context.l10n;
    return switch (error) {
      CompanionLightError(failure: CompanionLightFailure.noKey) => l10n.companionLightNoKey,
      CompanionLightError(failure: CompanionLightFailure.badKey) => l10n.companionLightBadKey,
      CompanionLightError(failure: CompanionLightFailure.busy) => l10n.companionLightBusy,
      DshRemoteException(code: 'companion/cleanup-source-unknown') => l10n.companionMemoryCleanupUnknown,
      // Full mode only because nobody picked a mode yet: light would work without a host.
      DshClosedException() when ref.read(companionModeProvider) == null => l10n.companionNotConnectedTryLight,
      DshClosedException() => l10n.companionNotConnected,
      _ => l10n.companionSendFailed,
    };
  }

  /// Light mode: the reply comes straight from the model, and the conversation
  /// stays on this phone.
  Future<void> _sendLight(String raw, MemoryRow source, bool Function() current) async {
    final key = ref.read(settingsProvider).apiKey.trim();
    if (key.isEmpty) throw const CompanionLightError(CompanionLightFailure.noKey);
    if (!current()) return;
    final memory = _memoryOwner!;
    final selection = memory.select(raw);
    final lines = companionLightContext([
      for (final row in memory.store.messages(
        sessionId: source['session_id']! as String,
        forModel: true,
        limit: CompanionLightHistory.window,
      ))
        row['role'] == 'user' ? CompanionLine.user(row['text']! as String) : CompanionLine.her(row['text']! as String),
    ]);
    final system = companionLightSystem(persona: _persona());
    final now = DateTime.now();
    final turnContext = _lightContext = companionTurnContext(
      now: now,
      utcOffsetMinutes: now.timeZoneOffset.inMinutes,
      lastSpokenAt: _lastSpokenAt,
      lastClockAt: _lastClockAt,
      events: _contextEvents,
    );
    _lastSpokenAt = now;
    // Nothing said before this page counts as news.
    _baselineSet = true;
    final turn = _lightTurn = 'light-${++_lightTurns}';
    _lightControlRevision = selection.controlRevision;
    _lightSourceId = source['id']! as String;
    _lightText = '';
    _lightAsked = raw;
    final requestId = _lightReceiptId = memory.store.reserveRequest(
      category: 'chat',
      provider: 'deepseek',
      model: companionLightModel,
      inputTokens: estimateTokens('$system\n${lines.map((line) => line.text).join('\n')}\n${selection.block}').ceil(),
      outputTokens: 800,
    )!;
    _lightReceiptFinalized = false;
    final settled = _lightSettled = Completer<void>();
    memory.retainReceipt(settled.future);
    final client = _lightClient = ref.read(companionLightClientProvider)();
    _lightReply =
        streamCompanionReply(
          client: client,
          apiKey: key,
          system: system,
          lines: lines,
          context: turnContext,
          memory: selection,
          onSent: () {
            if (!current() || selection.controlRevision != memory.store.archive['control_revision']) {
              throw const DshClosedException('Memory control changed');
            }
            memory.store.markRequestSent(requestId);
          },
          onUsage: (usage) {
            memory.store.recordUsage(requestId, usage.toJson());
            memory.store.finishRequest(requestId, terminal: usage.terminal);
            memory.changed();
            if (turn == _lightTurn) _lightReceiptFinalized = true;
            final input = usage.reportedInputTokens;
            if (mounted && (input != null || usage.outputTokens != null)) {
              ref.read(usageStatsProvider.notifier).tokens(input ?? 0, usage.outputTokens ?? 0);
            }
          },
          onUsageSettled: (usage, {required partial}) {
            if (mounted) {
              ref.read(usageStatsProvider.notifier).tokenUsage(UsageTokenSource.companion, usage, partial: partial);
            }
          },
        ).listen(
          (delta) {
            if (!mounted || turn != _lightTurn) return;
            if (selection.controlRevision != memory.store.archive['control_revision']) {
              _retireLight(discard: true);
              return;
            }
            _lightText += delta;
            _onReply(turn, _lightText, running: true);
          },
          onError: (Object error) {
            try {
              _endLight(turn, error: error);
            } finally {
              if (!settled.isCompleted) settled.complete();
            }
          },
          onDone: () {
            try {
              _endLight(turn);
            } finally {
              if (!settled.isCompleted) settled.complete();
            }
          },
          cancelOnError: true,
        );
    _onReply(turn, '', running: true);
  }

  /// The light reply [turn] is over: finished, failed or stopped. What she
  /// said is kept; a line she never answered goes back into the input.
  void _endLight(String turn, {Object? error}) {
    if (turn != _lightTurn || _lightReply == null) return;
    _lightReply = null;
    _lightSettled = null;
    _lightTurn = '';
    _lightClient?.close();
    _lightClient = null;
    final memory = _memoryOwner!;
    final requestId = _lightReceiptId;
    _lightReceiptId = null;
    if (requestId != null && !_lightReceiptFinalized) {
      memory.store.finishRequest(requestId, terminal: error == null ? 'cancelled' : 'local_error');
    }
    if (_lightControlRevision != memory.store.archive['control_revision']) {
      _lightText = '';
      _lightContext = null;
      return;
    }
    final answered = _lightText.trim().isNotEmpty;
    final asked = _lightContext;
    _lightContext = null;
    Object? failure = error;
    if (answered) {
      final now = DateTime.now();
      try {
        memory.store.submitMessage(
          id: 'reply:$_lightSourceId:$requestId',
          sessionId: memory.store.lightSessionId,
          role: 'assistant',
          text: _lightText,
          saidAtUtc: now.toUtc().millisecondsSinceEpoch,
          offsetMinutes: now.timeZoneOffset.inMinutes,
        );
        _retryMemorySource = null;
      } on Object catch (saveError) {
        failure ??= saveError;
      }
      // She heard it: what this turn carried is spent.
      if (asked != null) {
        _contextEvents = companionConsumeEvents(_contextEvents, asked.eventIds);
        if (asked.hasClock) _lastClockAt = asked.sampledAt;
      }
    }
    if (!mounted) return;
    if (!answered && failure != null) {
      if (_input.text.isEmpty) _input.text = _lightAsked;
      _stage.command('emotion', {'name': 'worried', 'hold': 3000});
    }
    _onReply(turn, _lightText, running: false, error: failure == null ? null : _failureText(failure));
    _queueMemoryExtraction();
  }

  /// Ends the light reply on its way, at once: what she has said so far is
  /// kept, the request is dropped (its client closed first), and nothing it
  /// does later reaches the page. Cancelling can itself fail late (a timeout
  /// already under way); that is swallowed, not let loose.
  void _retireLight({bool discard = false}) {
    final reply = _lightReply;
    if (reply == null) return;
    final settled = _lightSettled;
    if (discard) {
      final id = _lightReceiptId;
      if (id != null && !_lightReceiptFinalized) _memoryOwner!.store.finishRequest(id, terminal: 'cancelled');
      _lightReceiptId = null;
      _lightReply = null;
      _lightSettled = null;
      _lightTurn = '';
      _lightText = '';
      _lightContext = null;
      _lightClient?.close();
      _lightClient = null;
    } else {
      _endLight(_lightTurn);
    }
    unawaited(
      reply.cancel().catchError((Object _) {}).whenComplete(() {
        if (settled != null && !settled.isCompleted) settled.complete();
      }),
    );
  }

  Future<void> _stop() async {
    _acted();
    _hush();
    if (_lightReply != null) {
      _retireLight();
      return;
    }
    final id = _sessionId;
    if (id == null) return;
    await ref.read(chatProvider(id).notifier).cancel();
  }

  /// Switching modes on the page: drop the reply on its way and the other
  /// mode's conversation, then arrive again.
  void _modeChanged() {
    _boundLight = _light;
    _attachMemoryWorker();
    if (!_light) unawaited(_migrateHostMemory());
    _retireLight();
    setState(_unbind);
    if (!_stageReady) return;
    if (!_light) {
      final binding = ref.read(companionSessionsProvider.notifier).of(ref.read(activeHostProvider));
      if (binding != null) _bind(binding.sessionId);
    }
    // She is already here: no second hello.
    unawaited(_arrive(greet: false));
  }

  /// The backlog over her: this room's whole conversation, in either mode.
  Future<void> _openLog() async {
    _acted();
    if (_light && _store != null) {
      final history = _lightHistory ??= CompanionLightHistory.at(_store!.root);
      await history.load();
    }
    if (!mounted) return;
    _focus.unfocus();
    setState(() => _logOpen = true);
    // Under the log's blur she's barely seen: her stage draws slowly meanwhile.
    _stage.command('covered', {'on': true});
  }

  void _closeLog() {
    if (!mounted || !_logOpen) return;
    setState(() => _logOpen = false);
    _stage.command('covered', {'on': false});
  }

  List<CompanionLine> get _visibleLightLines => [
    ...?_lightHistory?.lines,
    for (final row in _memoryOwner?.store.messages() ?? const <MemoryRow>[])
      if ((row['session_id']! as String).startsWith('light:'))
        row['role'] == 'user' ? CompanionLine.user(row['text']! as String) : CompanionLine.her(row['text']! as String),
  ];

  Widget _log(String name) {
    final sessionId = _sessionId;
    if (_light) {
      return CompanionLog(
        key: const ValueKey('log-light'),
        entries: companionLogFromLight(
          _visibleLightLines,
          emotions: _moves.emotionLabels,
          actions: _moves.actionLabels,
          // What she is saying right now, already in her bubble.
          speaking: _lightReply != null && _lightText.isNotEmpty ? _lightText : null,
        ),
        name: name,
        onClose: _closeLog,
      );
    }
    // Full mode before her conversation there has begun: nothing said yet.
    if (sessionId == null) {
      return CompanionLog(key: const ValueKey('log-none'), entries: const [], name: name, onClose: _closeLog);
    }
    return Consumer(
      key: ValueKey('log-$sessionId'),
      builder: (context, ref, _) {
        final chat = ref.watch(
          chatProvider(sessionId).select((s) => (items: s.items, more: s.hasMoreHistory, loading: s.loadingOlder)),
        );
        return CompanionLog(
          entries: companionLogFromChat(chat.items, emotions: _moves.emotionLabels, actions: _moves.actionLabels),
          name: name,
          onClose: _closeLog,
          loadingOlder: chat.loading,
          history: chat.items.length,
          onLoadOlder: chat.more ? ref.read(chatProvider(sessionId).notifier).loadOlder : null,
          onOpenChat: () {
            _closeLog();
            _openFullChat();
          },
        );
      },
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
  Future<void> _installBundled({bool arriving = false}) => _installFrom((claim) async {
    final bytes = await _bundled();
    if (bytes == null) throw const CompanionPackException(CompanionPackProblem.notAPack);
    final zip = claim('${_store!.root.parent.path}/companion-bundled-${DateTime.now().microsecondsSinceEpoch}.zip');
    await zip.writeAsBytes(bytes, flush: true);
    return zip;
  }, arriving: arriving);

  /// [bring] makes the zip to install, through `claim` for its temporary
  /// file: claimed before anything is written, so a write that fails halfway
  /// is cleaned up too (Pro C542).
  Future<void> _installFrom(
    Future<File?> Function(File Function(String path) claim) bring, {
    bool arriving = false,
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
        await store.install(zip.path);
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
          await store.install(runtime.path);
        } finally {
          if (await runtime.exists()) await runtime.delete();
        }
        await store.install(zip.path);
      }
      final character = await store.character();
      // She's back: the pack inside the app may come by itself again.
      unawaited(SharedPreferences.getInstance().then((p) => p.remove(_packRemovedKey)));
      if (!mounted) return;
      setState(() {
        _character = character;
        _failure = null;
        _stageReady = false;
        _stageRun++;
        _phase = _Phase.stage;
      });
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
    final character = await store.character();
    if (!mounted || _phase != _Phase.failed) return;
    setState(() {
      _character = character;
      _failure = null;
      _stageReady = false;
      _stageRun++;
      _phase = _Phase.stage;
    });
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
    });
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

  void _openMenu() {
    _acted();
    final l10n = context.l10n;
    final light = _light;
    final credit = [
      if (_character.author case final author?) l10n.companionCreditAuthor(author),
      ?_character.license,
      ?_character.source,
    ].join(' · ');
    unawaited(
      showAppSheet<void>(
        context,
        // Scrolls on a short screen instead of overflowing.
        builder: (sheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetTitleBar(ref.read(companionNameProvider) ?? _character.name ?? l10n.companionTitle),
                SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    SettingsTile(
                      icon: AppIcons.edit,
                      tinted: false,
                      title: l10n.companionMenuPersona,
                      value: Text(_name(l10n)),
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => CompanionPersonaPage(packName: _character.name)),
                          ),
                        );
                      },
                    ),
                    SettingsTile(
                      icon: AppIcons.configure,
                      tinted: false,
                      title: l10n.companionMenuAdapt,
                      value: _adapting
                          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : null,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        _openAdapt();
                      },
                    ),
                    SettingsTile(
                      icon: AppIcons.generating,
                      tinted: false,
                      title: l10n.companionMenuMoves,
                      value: Text('${_moves.expressions.length + _moves.motions.length}'),
                      onTap: () {
                        Navigator.of(sheet).pop();
                        _openMoves();
                      },
                    ),
                    // Only where her state is kept: otherwise there is nothing to show.
                    if (_vitals case final vitals?)
                      SettingsTile(
                        icon: AppIcons.postLike,
                        tinted: false,
                        title: l10n.companionBondTitle,
                        value: CompanionBondMeter(
                          step: companionBond(vitals.vitals.closeness),
                          label: switch (companionBond(vitals.vitals.closeness)) {
                            0 => l10n.companionBond0,
                            1 => l10n.companionBond1,
                            2 => l10n.companionBond2,
                            _ => l10n.companionBond3,
                          },
                        ),
                      ),
                    SettingsTile(
                      icon: light ? AppIcons.engineStarting : AppIcons.engine,
                      tinted: false,
                      title: l10n.companionMenuMode,
                      value: Text(light ? l10n.companionModeLight : l10n.companionModeFull),
                      onTap: () {
                        Navigator.of(sheet).pop();
                        _chooseMode();
                      },
                    ),
                    SettingsTile(
                      icon: AppIcons.bookmark,
                      tinted: false,
                      title: l10n.companionMemoryTitle,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(_openMemories());
                      },
                    ),
                    SettingsTile(
                      icon: AppIcons.reminder,
                      tinted: false,
                      title: l10n.companionTasksTitle,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(_openTasks());
                      },
                    ),
                    Consumer(
                      // The page's own context pushes the voice page, not the sheet's.
                      builder: (_, ref, _) {
                        final voice = ref.watch(companionVoiceSettingsProvider);
                        return SettingsTile(
                          icon: AppIcons.companionVoice,
                          tinted: false,
                          title: l10n.companionMenuVoice,
                          value: Text(switch (voice) {
                            CompanionVoiceSettings(on: true, follow: true) => l10n.speechVoiceFollow,
                            CompanionVoiceSettings(on: true, source: CompanionVoiceSource.deepseek) =>
                              l10n.speechVoiceDeepseek,
                            CompanionVoiceSettings(on: true, source: CompanionVoiceSource.system) =>
                              l10n.companionVoiceSystem,
                            CompanionVoiceSettings(on: true, source: CompanionVoiceSource.preset) =>
                              voice.presetInfo.name,
                            CompanionVoiceSettings(on: true, source: CompanionVoiceSource.openai) =>
                              l10n.companionVoiceOpenai,
                            CompanionVoiceSettings(on: true, source: CompanionVoiceSource.custom) =>
                              l10n.companionVoiceCustom,
                            _ => l10n.companionVoiceOff,
                          }),
                          onTap: () {
                            Navigator.of(sheet).pop();
                            unawaited(
                              Navigator.of(context)
                                  .push(MaterialPageRoute<void>(builder: (_) => const CompanionVoicePage())),
                            );
                          },
                        );
                      },
                    ),
                    Consumer(
                      builder: (context, ref, _) => SettingsTile(
                        icon: AppIcons.companionInvite,
                        tinted: false,
                        title: l10n.companionMenuPace,
                        value: Text(_paceChoices(l10n).firstWhere((c) => c.$1 == _paceChoice(ref)).$2),
                        onTap: () {
                          Navigator.of(sheet).pop();
                          _choosePace();
                        },
                      ),
                    ),
                    SettingsTile(
                      icon: AppIcons.notifications,
                      tinted: false,
                      title: l10n.companionMenuSignals,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        _openSignals();
                      },
                    ),
                    if (light && _visibleLightLines.isNotEmpty)
                      SettingsTile(
                        icon: AppIcons.newChat,
                        tinted: false,
                        title: l10n.companionMenuRestart,
                        subtitle: l10n.companionMenuRestartLightHint,
                        onTap: () {
                          Navigator.of(sheet).pop();
                          unawaited(_restart());
                        },
                      ),
                    if (_sessionId != null || (light && _visibleLightLines.isNotEmpty))
                      SettingsTile(
                        icon: AppIcons.history,
                        tinted: false,
                        title: l10n.companionMenuHistory,
                        onTap: () {
                          Navigator.of(sheet).pop();
                          unawaited(_openLog());
                        },
                      ),
                    if (_sessionId != null)
                      SettingsTile(
                        icon: AppIcons.newChat,
                        tinted: false,
                        title: l10n.companionMenuRestart,
                        subtitle: l10n.companionMenuRestartHint,
                        onTap: () {
                          Navigator.of(sheet).pop();
                          unawaited(_restart());
                        },
                      ),
                    // 创意工坊: companions other people made. Only where this build has one to open.
                    if (ref.read(workshopAvailableProvider))
                      SettingsTile(
                        icon: AppIcons.workshop,
                        tinted: false,
                        title: l10n.workshopTitle,
                        subtitle: l10n.workshopEntrySubtitle,
                        onTap: () {
                          Navigator.of(sheet).pop();
                          unawaited(
                            Navigator.of(context)
                                .push(MaterialPageRoute<void>(builder: (_) => const WorkshopScreen()))
                                .then((_) => _afterWorkshop()),
                          );
                        },
                      ),
                    SettingsTile(
                      icon: AppIcons.delete,
                      tinted: false,
                      title: l10n.companionMenuRemovePack,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(_removePack());
                      },
                    ),
                  ],
                ),
                // 模式: 工作 or 酒馆 from here, and which one a launch opens.
                SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    SettingsTile(
                      key: const ValueKey('companion-mode'),
                      icon: AppIcons.modes,
                      tinted: false,
                      title: l10n.modeSheetTitle,
                      value: Text(l10n.modeCompanionShort),
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(showModeSheet(context, current: AppMode.companion));
                      },
                    ),
                  ],
                ),
                if (credit.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 12),
                    child: Text(credit, style: Theme.of(sheet).textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
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
    final light = _light;
    final ok = await _confirm(
      l10n.companionMenuRestart,
      light ? l10n.companionMenuRestartLightConfirm : l10n.companionMenuRestartConfirm,
    );
    if (!ok || !mounted) return;
    if (light) {
      _retireLight(discard: true);
      _hush();
      _settleTimer?.cancel();
      setState(() {
        _running = false;
        _myLine = null;
      });
      _refreshMood();
      final memory = await _openMemory();
      memory.store.startLightConversation();
      _retryMemorySource = null;
      _lastSpokenAt = null;
      _lastClockAt = null;
      if (!mounted) return;
      _say(_firstHello(l10n));
      return;
    }
    final client = ref.read(activeConnectionProvider).value?.client;
    final hostKey = _recallHostKey;
    await ref.read(companionSessionsProvider.notifier).forget();
    if (!mounted) return;
    setState(_unbind);
    _say(_firstHello(l10n));
    if (client != null) {
      try {
        await _retireLegacyRecall(client, hostKey);
      } on Object {
        if (mounted) _notice(l10n.companionMemoryMigrationPending);
      }
    }
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
    // Changing host while here: her conversation is per host.
    ref.listen(activeHostProvider, (_, _) => _bindingChanged());
    ref.listen(activeConnectionProvider.select((value) => value.value?.client), (_, _) => _bindingChanged());
    // A refreshed host (name, folder) keeps its client but not the wrapper
    // her signals are tied to.
    ref.listen(activeConnectionProvider.select((value) => value.value), (_, _) => _syncSignals());
    ref.listen(companionModeProvider, (before, now) {
      // The saved pick arriving after the page opened changes nothing if it is what she already does.
      bool light(CompanionMode? mode) =>
          mode == CompanionMode.light || (mode == null && ref.read(activeConnectionProvider).value == null);
      if (light(before) != light(now)) _modeChanged();
    });
    // What her invitation depends on that only a build can see: this page in
    // front (a sheet or another page over her isn't), a screen reader, the switch.
    _routeShown = TickerMode.valuesOf(context).enabled && (ModalRoute.isCurrentOf(context) ?? true);
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
          child: BackdropGroup(child: Builder(builder: _buildPage)),
        ),
      ),
    );
  }

  Widget _buildPage(BuildContext context) {
    final l10n = context.l10n;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final padding = MediaQuery.paddingOf(context);
    final store = _store;
    final showStage = _phase == _Phase.stage && store != null;
    final name = _name(l10n);
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
    return Scaffold(
      backgroundColor: const Color(0xFF0D2F55),
      resizeToAvoidBottomInset: false,
      body: Stack(
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
                    CompanionStage(key: ValueKey(_stageRun), store: store, controller: _stage, events: events),
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
                const SizedBox(width: 52),
                Expanded(
                  child: Center(
                    child: _stageReady ? CompanionNamePlate(name: name, activity: _activity) : const SizedBox.shrink(),
                  ),
                ),
                if (_stageReady) ...[
                  CompanionRoundButton(
                    icon: AppIcons.history,
                    label: l10n.companionLogTitle,
                    grouped: true,
                    onTap: _openLog,
                  ),
                  const SizedBox(width: 8),
                  CompanionRoundButton(icon: AppIcons.more, label: l10n.companionMenu, grouped: true, onTap: _openMenu),
                ] else
                  const SizedBox(width: 96),
              ],
            ),
          ),
          if (showStage && _stageReady)
            Positioned(
              left: companionEdge,
              right: companionEdge,
              bottom: max(insets, padding.bottom) + companionEdge,
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
                  if (!_light && _sessionId != null)
                    Consumer(
                      builder: (_, ref, _) {
                        final session = _sessionId!;
                        final approval = ref.watch(chatProvider(session).select((state) => state.openApproval));
                        final current = _currentRoom();
                        return CompanionAsk(
                          sessionId: session,
                          approvalTarget: approval == null
                              ? null
                              : (
                                  eventId: approval.eventId,
                                  callId: approval.callId,
                                  isCurrent: () => current() && _sessionId == session,
                                ),
                        );
                      },
                    ),
                  CompanionMyLine(text: _myLine),
                  CompanionSpeech(
                    text: _bubble,
                    error: _bubbleIsError,
                    thinking: _sending || (_running && _bubble == null),
                    onPullBack: _openLog,
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
                  CompanionInvite(
                    ticket: _adaptOffer == null || inviting ? null : 'adapt-${_adaptOffer!.moc}',
                    mark: const Icon(AppIcons.configure, size: 20, color: Color(0xFFFFD27A)),
                    text: l10n.companionAdaptOffer,
                    accept: l10n.companionAdaptOfferYes,
                    decline: l10n.companionAdaptOfferNo,
                    onAccept: () => unawaited(_answerAdaptOffer(yes: true)),
                    onDecline: () => unawaited(_answerAdaptOffer(yes: false)),
                  ),
                  CompanionInvite(
                    ticket: inviting ? invite.ticket.id : null,
                    text: l10n.companionInviteRest,
                    accept: l10n.companionInviteAccept,
                    decline: l10n.companionInviteDecline,
                    remaining: inviteLeft,
                    total: const Duration(milliseconds: CompanionInitiativeRules.promptMs),
                    onAccept: () => _answerInvite(yes: true),
                    onDecline: () => _answerInvite(yes: false),
                  ),
                  const SizedBox(height: 10),
                  CompanionComposer(
                    onUserInput: () {
                      _acted();
                      _hush();
                    },
                    input: _input,
                    focus: _focus,
                    hint: l10n.companionInputHint(name),
                    running: _running,
                    busy: _sending && !_isMemoryControl(_input.text) && !_isTaskControl(_input.text),
                    listening: _voice.active,
                    voiceAvailable: _voice.available,
                    onSend: _send,
                    onStop: _stop,
                    onVoice: () {
                      // Reaching for the microphone is already doing something.
                      _acted();
                      // Her voice off before the microphone opens.
                      _hush();
                      _voice.active ? _voice.stop() : _voice.start();
                    },
                  ),
                ],
              ),
            ),
          Positioned.fill(child: CompanionLogTransition(child: _logOpen && showStage ? _log(name) : null)),
        ],
      ),
    );
  }
}

/// Her room's dark theme, one per palette and blur setting: a new one each build
/// would tell every widget under it the theme changed whenever the page rebuilds
/// (a streaming reply rebuilds it about thirty times a second).
final _darkThemes = <(AppAccent, bool), ThemeData>{};

ThemeData _darkTheme(AppAccent accent, bool blur) {
  if (_darkThemes.length > 4) _darkThemes.clear();
  return _darkThemes.putIfAbsent((accent, blur), () => buildDarkTheme(accent: accent, glassBlur: blur));
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
        maxLength: 16,
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
                  maxLength: 200,
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
