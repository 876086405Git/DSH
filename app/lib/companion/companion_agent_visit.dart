part of 'companion_agent.dart';

const _agentRetryClosed = DshRemoteException(
  'companion/agent-retry-closed',
  'Inspect the original task or memory before giving a new instruction.',
  {'status': 409},
);

/// Window facts and immediate presentation effects. No BuildContext or
/// WidgetRef crosses this port; the Page still owns its actual routes.
abstract interface class CompanionAgentRoomUi {
  bool get mounted;
  bool get stageReady;
  String get forgottenNotice;
  CompanionInitiativeRoom get initiativeRoom;
  CompanionInitiativeView get initiativeView;
  bool get hasInvitation;
  CompanionAgentTaskUi tasks({required bool Function() isCurrent});
  void committed(String raw);
  void failed(Object error, {String? retry});
  void controlChanged({required bool own});
  void connectionChanged();
  void detached();
  void widgetClearPending();
  void vitalsChanged(CompanionSnapshot snapshot);
  Future<void> greet(DateTime? lastVisit, bool Function() isCurrent);
  bool presentFollowup(CompanionInitiativeDisplay display, String line);
  void hideFollowup(String ticketId);
}

/// A handle to one actual room visit. It never resolves through a newer visit
/// when an old voice callback, picker or disposal finishes late.
class CompanionAgentAttachment {
  CompanionAgentAttachment._(this._visit, this._window);
  final _CompanionAgentVisit _visit;
  final _CompanionAgentWindow _window;

  bool get isAttached => _window.current(_visit);
  bool get preparing => _visit.preparing;
  bool get running => _visit.run?.running ?? false;
  // Retained API: local task speech has no model preparation.
  String? get preparingSignalId => null;
  String get text => _visit.run?.text ?? '';
  String? get pendingText {
    final request = _visit.run?.request;
    return request != null && !request.saved && request.text.isNotEmpty ? request.text : null;
  }

  String? get replyId => _visit.run?.replyId;
  Object? get error {
    final run = _visit.run;
    // Only a turn that already ran a tool is closed: retrying it could repeat
    // the tool's effect. A dropped stream with words only is an ordinary failure.
    if (run != null && run.error != null && run.toolDispatchStarted) {
      return _agentRetryClosed;
    }
    return run?.error;
  }

  CompanionMemoryOwner? get memory => _visit.memory;
  String? get characterId => _visit.characterId;
  ({int tier, Object? settledDay})? get affinity => _visit.displayAffinity;

  CompanionPendingRawErase? get pendingRawErase => isAttached ? _visit.pendingRawErase : null;

  /// Call only after the actual card or notification actions were provided.
  CompanionRawEraseResult markRawEraseOffered(String id) {
    if (!isAttached) throw const DshClosedException('Companion window closed');
    return _visit.markRawEraseOffered(id);
  }

  CompanionRawEraseResult confirmRawErase(String id) {
    if (!isAttached) throw const DshClosedException('Companion window closed');
    return _visit.confirmRawErase(id);
  }

  CompanionRawEraseResult declineRawErase(String id) {
    if (!isAttached) throw const DshClosedException('Companion window closed');
    return _visit.declineRawErase(id);
  }

  CompanionSnapshot? get vitals => _visit.snapshot;
  bool get light => _visit.light;
  bool Function() captureCurrent() {
    final visitCurrent = _visit.captureCurrent();
    return () => isAttached && visitCurrent();
  }

  Future<CompanionMemoryOwner> openMemory() =>
      isAttached ? _visit.openMemory() : Future.error(const DshClosedException('Companion window closed'));
  Future<void> submit(String raw, {String? assistantPage, bool returnToApp = false}) async {
    if (isAttached) {
      await _visit.submit(
        raw,
        inputWindow: 'room',
        origin: _window.ui,
        handoff: _window.mapHandoff,
        originCurrent: () => isAttached,
        assistantPage: assistantPage,
        returnToApp: returnToApp,
      );
    }
  }

  Future<void> arrive({bool greet = true}) async {
    if (isAttached) await _visit.arrive(greet: greet, windowCurrent: () => isAttached);
  }

  Future<void> restart() async {
    if (isAttached) await _visit.restart();
  }

  void stop({bool discard = false}) {
    if (isAttached) _visit.stop(discard: discard);
  }

  void event(String type) {
    if (isAttached) _visit.event(type);
  }

  void remember(String kind, String? note) {
    if (isAttached) _visit.remember(kind, note);
  }

  void observe(CompanionInitiativeView view) {
    if (isAttached) _visit.observe(view);
  }

  void acted() {
    if (isAttached) _visit.acted();
  }

  void offerTaskSignal(
    CompanionSignalSpeech speech, {
    required String language,
    required bool Function() isCurrent,
    required bool Function(CompanionInitiativeDisplay, String) present,
  }) {
    if (!isAttached) return;
    _visit._offerTaskSignal(
      speech,
      target: _window.ui,
      recipientCurrent: () => isAttached,
      signalCurrent: isCurrent,
      present: present,
    );
  }

  Map<String, ({int start, int end})> get pendingReplyRanges {
    if (!isAttached) return const {};
    return Map<String, ({int start, int end})>.unmodifiable({
      ...?_visit.run?.unpresentedReplies,
      ...?_visit.notices?.presentationRanges(_visit.run),
    });
  }

  void presentedReply(String replyId, String text, {required Set<String> sourceIds}) {
    if (isAttached) _visit.presentedReply(replyId, text, sourceIds: sourceIds);
  }

  void updateCharacter(CompanionCharacter character, CompanionMoves moves, {String? sourceKey}) {
    if (isAttached) _visit.updateCharacter(character, moves, sourceKey);
  }

  void detach() => _visit.detachWindow(_window);
}

class CompanionAgentResident {
  CompanionAgentResident._(this._visit, this._ui);
  final _CompanionAgentVisit _visit;
  final CompanionAgentRoomUi _ui;
  bool get active => _visit.active && identical(_visit.residentUi, _ui);
  CompanionMemoryOwner? get memory => active ? _visit.memory : null;
  String? get characterId => active ? _visit.characterId : null;
  CompanionPendingRawErase? get pendingRawErase => active ? _visit.pendingRawErase : null;

  /// Notification and float actions share the room's one Store record.
  CompanionRawEraseResult markRawEraseOffered(String id) {
    if (!active) throw const DshClosedException('Companion resident closed');
    return _visit.markRawEraseOffered(id);
  }

  CompanionRawEraseResult confirmRawErase(String id) {
    if (!active) throw const DshClosedException('Companion resident closed');
    return _visit.confirmRawErase(id);
  }

  CompanionRawEraseResult declineRawErase(String id) {
    if (!active) throw const DshClosedException('Companion resident closed');
    return _visit.declineRawErase(id);
  }

  bool get ownsCurrentRun => active && identical(_visit.runOrigin, _ui) && identical(_visit.run, _visit.agent._run);

  Future<bool> deliverReply(String replyId, String text, Future<bool> Function(int? noticeEpoch) deliver) {
    final run = _visit.run;
    if (!active || run == null || !identical(run, _visit.agent._run) || run.replyId != replyId) {
      return Future.value(false);
    }
    final notices = _visit.notices;
    if (notices != null) return notices.deliverReply(run, text, deliver);
    return run.externalNoticeContent ? Future.value(false) : deliver(null);
  }

  /// Retained API: local task speech has no model preparation.
  String? get preparingSignalId => null;

  /// The floating composer reads the same role/cutoff-filtered transcript.
  /// It keeps no second message list or cold replay queue.
  List<MemoryRow> get recentMessages {
    final owner = memory;
    if (owner == null) return const [];
    return owner.store.modelMessages(sessionId: owner.store.lightSessionId, characterId: characterId, limit: 3);
  }

  Future<CompanionMemoryOwner> openMemory() =>
      active ? _visit.openMemory() : Future.error(const DshClosedException('Companion resident closed'));
  Future<void> submit(String raw, {bool fromFloat = false, void Function(MemoryRow)? onCommitted}) async {
    if (active) {
      await _visit.submit(
        raw,
        inputWindow: fromFloat ? 'floating' : 'notification',
        origin: _ui,
        handoff: _visit.residentMapHandoff!,
        originCurrent: () => active,
        replacePreparing: true,
        onCommitted: onCommitted,
      );
    }
  }

  void setReducedPower(bool value) {
    if (active) _visit.setReducedPower(value);
  }

  void close() => _visit.releaseResident(_ui);
}

class _CompanionAgentWindow {
  _CompanionAgentWindow(this.ui, this.mapHandoff);
  final CompanionAgentRoomUi ui;
  final CompanionMapHandoff mapHandoff;
  bool attached = true;
  bool current(_CompanionAgentVisit visit) => attached && identical(visit.window, this) && visit.active && ui.mounted;
}

class _CompanionAgentVisit {
  _CompanionAgentVisit(this.agent, this.ref, this.root, this.character, this.moves)
    : initiative = ref.read(companionInitiativeProvider),
      clock = ref.read(companionInitiativeClockProvider),
      boundHost = ref.read(activeHostProvider),
      boundClient = ref.read(activeConnectionProvider).value?.client {
    boundLight = light;
    initiative.pace = ref.read(companionInitiativePaceProvider);
    subscriptions.add(
      ref.listen(companionInitiativePaceProvider, (_, pace) {
        if (active) initiative.pace = pace;
      }).close,
    );
    subscriptions.add(ref.listen(activeHostProvider, (_, _) => connectionChanged()).close);
    subscriptions.add(
      ref.listen(activeConnectionProvider.select((value) => value.value?.client), (_, _) => connectionChanged()).close,
    );
    subscriptions.add(ref.listen(companionModeProvider, (_, _) => connectionChanged()).close);
    subscriptions.add(
      ref.listen(settingsProvider.select((value) => value.apiKey), (_, _) => notices?.invalidate()).close,
    );
    subscriptions.add(ref.listen(companionPersonaProvider, (_, _) => notices?.invalidate()).close);
    subscriptions.add(ref.listen(companionNameProvider, (_, _) => notices?.invalidate()).close);
    _schedulePeriodicWork();
  }

  final CompanionAgent agent;
  final Ref ref;
  final Future<Directory> root;
  _CompanionAgentWindow? window;
  CompanionAgentRoomUi? residentUi;
  CompanionMapHandoff? residentMapHandoff;
  CompanionAgentRoomUi? runOrigin;
  CompanionMapHandoff? runMapHandoff;
  CompanionAgentRoomUi get ui => window?.ui ?? residentUi!;
  CompanionAgentRoomUi get initiativeUi {
    final page = window?.ui;
    final view = page?.initiativeView;
    return page != null && view!.visible && view.resumed ? page : residentUi ?? ui;
  }

  final CompanionInitiative initiative;
  final CompanionInitiativeClock Function() clock;
  final subscriptions = <void Function()>[];
  CompanionCharacter character;
  CompanionMoves moves;
  String? characterSourceKey;
  String? characterId;
  _CompanionPresence? presence;
  int? affinitySettledDay;
  ({CompanionMemoryOwner owner, String role, ({int tier, Object? settledDay}) display})? _affinityDisplay;

  ({int tier, Object? settledDay})? get displayAffinity {
    final owner = memory;
    final role = characterId;
    if (!active || owner == null || role == null) return null;
    final cached = _affinityDisplay;
    if (cached != null && identical(cached.owner, owner) && cached.role == role) return cached.display;
    final row = owner.store.companionAffinity(characterId: role);
    final display = (tier: row?['tier'] as int? ?? 0, settledDay: row?['settled_through_day']);
    _affinityDisplay = (owner: owner, role: role, display: display);
    return display;
  }

  HostRef boundHost;
  DshClient? boundClient;
  late bool boundLight;
  bool closed = false;
  bool preparing = false;
  bool entered = false;
  CompanionInitiativeRoom? enteredRoom;
  int epoch = 0;
  int submission = 0;
  int controlRevision = 0;
  CompanionMemoryOwner? memory;
  Future<CompanionMemoryOwner>? opening;
  MemoryRow? retrySource;
  CompanionAgentMemoryTools? retryTools;
  CompanionAgentPhoneTools? activePhoneTools;
  CompanionResidentSignals? residentSignals;
  _VisitNotices? notices;
  _CompanionAgentRun? run;
  Timer? quietTimer;
  Timer? idleTimer;
  Timer? usageTimer;
  bool _reducedPower = false;
  CompanionKeeper? phone;
  CompanionKeeper? keeper;
  CompanionSnapshot? snapshot;
  Future<void> vitalsQueue = Future.value();
  DateTime? lastSpokenAt;
  DateTime? lastClockAt;
  List<CompanionContextEvent> events = const [];
  int eventSerial = 0;
  String? followupWindow;
  final followupAttempts = <String>{};
  bool followupRetired = false;
  static final farewell = RegExp(
    r'^(?:(?:晚安|再见)(?:[，,\s]+(?:我)?先走了)?|(?:我)?先走了|good ?night|goodbye|bye)[。.!！]*$',
    caseSensitive: false,
  );

  bool get active =>
      !closed &&
      !agent._disposed &&
      identical(agent._visit, this) &&
      (residentUi != null || (window?.attached == true && window!.ui.mounted));

  DateTime? lastUserInteractionAt;

  CompanionPendingRawErase? get pendingRawErase =>
      active ? memory?.pendingRawErase(this, characterId: characterId) : null;

  CompanionMemoryOwner get _rawEraseOwner {
    final owner = memory;
    if (!active || owner == null) throw const DshClosedException('Companion visit closed');
    return owner;
  }

  CompanionRawEraseResult markRawEraseOffered(String id) =>
      _rawEraseOwner.markRawEraseOffered(this, id, characterId: characterId);
  CompanionRawEraseResult confirmRawErase(String id) =>
      _rawEraseOwner.confirmRawErase(this, id, characterId: characterId);
  CompanionRawEraseResult declineRawErase(String id) =>
      _rawEraseOwner.declineRawErase(this, id, characterId: characterId);

  // Only resident-owned periodic work slows down. User input, the current
  // request and its receipt are unchanged; equal state never resets a timer.
  void setReducedPower(bool value) {
    if (closed || _reducedPower == value) return;
    _reducedPower = value;
    _schedulePeriodicWork();
  }

  void _schedulePeriodicWork() {
    idleTimer?.cancel();
    usageTimer?.cancel();
    final factor = _reducedPower ? 2 : 1;
    idleTimer = Timer.periodic(Duration(minutes: factor), (_) {
      if (active) {
        notices?.tick();
        observe(ui.initiativeView);
        unawaited(consolidate());
      }
    });
    usageTimer = Timer.periodic(Duration(seconds: 15 * factor), (_) => refreshHostUsage());
  }

  CompanionAgentAttachment attachWindow(CompanionAgentRoomUi next, CompanionMapHandoff handoff) {
    if (residentUi case final CompanionAgentAmbientUi background) background.stopSpeech();
    final previous = window;
    if (previous != null) detachWindow(previous, replacing: true);
    final captured = window = _CompanionAgentWindow(next, handoff);
    entered = false;
    followupRetired = false;
    changed();
    return CompanionAgentAttachment._(this, captured);
  }

  void detachWindow(_CompanionAgentWindow captured, {bool replacing = false}) {
    if (!captured.attached) return;
    captured.attached = false;
    captured.mapHandoff.close();
    captured.ui.detached();
    if (!identical(window, captured)) return;
    // This runs inside the Page's dispose: revoke without notifying. The
    // Visit's own close, or its changed() below, follows right after.
    if (!replacing) memory?.invalidateRawErase(this, notify: false);
    unawaited(companionMarkSeen(DateTime.now()));
    finishPresence();
    if (identical(enteredRoom, captured.ui.initiativeRoom)) {
      initiative.leave(captured.ui.initiativeRoom);
      enteredRoom = null;
    }
    entered = false;
    window = null;
    if (residentUi == null && !replacing) {
      close();
    } else if (!replacing) {
      observe(ui.initiativeView);
      changed();
    }
  }

  void releaseResident(CompanionAgentRoomUi captured) {
    if (!identical(residentUi, captured)) return;
    agent.cancelScreenObservation();
    residentSignals?.close();
    residentSignals = null;
    if (identical(runOrigin, captured)) stop();
    residentMapHandoff?.close();
    residentMapHandoff = null;
    if (window == null) {
      close();
    } else {
      residentUi = null;
      setReducedPower(false);
      observe(ui.initiativeView);
      changed();
    }
  }

  bool get light {
    final mode = ref.read(companionModeProvider);
    return mode == CompanionMode.light || (mode == null && ref.read(activeConnectionProvider).value == null);
  }

  bool Function() captureCurrent() {
    final capturedEpoch = epoch;
    return () => active && capturedEpoch == epoch;
  }

  void changed() {
    if (active) agent.changed();
  }

  void updateCharacter(CompanionCharacter next, CompanionMoves nextMoves, String? sourceKey) {
    if (!active) return;
    character = next;
    moves = nextMoves;
    if (characterSourceKey == sourceKey) return;
    memory?.invalidateRawErase(this);
    finishPresence();
    stop(discard: true);
    memory?.cancelWork();
    epoch++;
    characterSourceKey = sourceKey;
    bindCharacter();
    notices?.invalidate();
    retrySource = null;
    run = null;
    events = const [];
    lastSpokenAt = null;
    lastClockAt = null;
    followupWindow = null;
    followupAttempts.clear();
    followupRetired = false;
    phone = null;
    keeper = null;
    snapshot = null;
    vitalsQueue = Future.value();
    if (memory case final owner?) {
      unawaited(
        ref
            .read(companionWidgetProvider)
            .clearMemoryLine(
              archiveId: owner.store.archive['id']! as String,
              controlRevision: owner.store.archive['control_revision']! as int,
            ),
      );
    }
    changed();
    observe(ui.initiativeView);
  }

  void bindCharacter() {
    final owner = memory;
    final key = characterSourceKey;
    characterId = owner == null || key == null
        ? null
        : owner.store.ensureCompanionCharacter(sourceKey: key)['id']! as String;
  }

  Future<CompanionMemoryOwner> openMemory() {
    final current = opening;
    if (current != null) return current;
    late final Future<CompanionMemoryOwner> next;
    next = readMemory().catchError((Object error) {
      // This slot belongs only to this visit, and only this opening clears it.
      if (identical(opening, next)) opening = null;
      throw error;
    });
    opening = next;
    return next;
  }

  Future<CompanionMemoryOwner> readMemory() async {
    final directory = await root;
    if (!active) throw const DshClosedException('Companion visit closed');
    final provider = companionMemoryOwnerProvider(directory.absolute.path);
    // A failed open is not kept: the next attempt (a retry) opens again.
    if (ref.read(provider).hasError) ref.invalidate(provider);
    final owner = await ref.read(provider.future);
    if (!active) return owner;
    memory = owner;
    bindCharacter();
    controlRevision = owner.store.archive['control_revision']! as int;
    owner.addListener(memoryChanged);
    // Bind this real Visit before either initialization await can outlive its
    // window. The Owner's ready gate still postpones all maintenance work.
    owner.enter(
      this,
      transport: () => agent._modelTransport(isCurrent: captureCurrent(), forMemory: true),
      estimateTokens: estimateCompanionMemoryTokens,
      characterId: characterId,
      ready: false,
    );
    await initiative.attachMemory(owner.store);
    try {
      await owner.migrateLocal();
    } on Object {
      // The original migration retries on another visit.
    }
    if (!active) return owner;
    owner.finishOpening(this);
    if (ref.read(operatingSystemProvider) == 'android') {
      notices = _VisitNotices(this, owner, ref.read(companionNoticesProvider));
      unawaited(notices!.start(directory.path));
    }
    unawaited(ref.read(companionRemindersProvider).recover());
    unawaited(clearWidget());
    unawaited(extract(forceTail: true));
    unawaited(migrateHostMemory());
    unawaited(resumeLookups(owner));
    unawaited(resumeNotes(owner));
    observe(ui.initiativeView);
    changed();
    return owner;
  }

  void memoryChanged() {
    _affinityDisplay = null;
    final owner = memory;
    if (!active || owner == null) return;
    final revision = owner.store.archive['control_revision']! as int;
    // Validate the fixed plan against committed changes, including an own
    // later tool or maintenance commit. This projection does not notify.
    owner.pendingRawErase(this, characterId: characterId);
    if (revision != controlRevision) {
      agent.cancelScreenObservation();
      final maintenance = owner.acceptsMaintenanceControl(this, revision);
      final own = maintenance || (identical(run, agent._run) && agent.acceptsControl(owner, revision));
      controlRevision = revision;
      notices?.invalidate();
      if (!maintenance) owner.cancelWork();
      quietTimer?.cancel();
      if (!own) {
        owner.invalidateRawErase(this, notify: false);
        stop(discard: true);
        epoch++;
        keeper = null;
        snapshot = null;
        vitalsQueue = Future.value();
      }
      // The real commit has already happened. Acknowledge it synchronously to
      // the window; delayed widget cleanup cannot replace a newer reply.
      final foreground = ui;
      foreground.controlChanged(own: own);
      final background = residentUi;
      if (background != null && !identical(background, foreground)) background.controlChanged(own: own);
      unawaited(clearWidget());
      ref.read(companionSessionsProvider.notifier).retirePending();
      if (!own && ui.stageReady) unawaited(refreshKeeper());
      queueExtraction();
    }
    changed();
    observe(ui.initiativeView);
  }

  Future<void> clearWidget() async {
    final owner = memory;
    if (owner == null) return;
    final cleared = await owner.clearWidget(ref.read(companionWidgetProvider));
    if (!cleared && active) ui.widgetClearPending();
  }

  Future<void> extract({bool forceTail = false}) async {
    final owner = memory;
    if (!active || owner == null || preparing || run?.running == true) return;
    try {
      await owner.extract(this, forceTail: forceTail, offsetMinutes: clock().offsetMinutes);
    } on Object {
      // The original batch remains queued for a later actual opportunity.
    }
  }

  void queueExtraction() {
    if (!active) return;
    quietTimer?.cancel();
    unawaited(extract());
    quietTimer = Timer(const Duration(minutes: 2), () => unawaited(extract(forceTail: true)));
  }

  Future<void> consolidate() async {
    final owner = memory;
    if (!active || owner == null || ui.hasInvitation) return;
    final view = ui.initiativeView;
    if (preparing || run?.running == true) return;
    if (residentUi == null && (!view.visible || !view.resumed || view.blocked)) return;
    try {
      await owner.consolidate(this, offsetMinutes: clock().offsetMinutes);
    } on Object {
      // Existing cards remain available when optional maintenance cannot run.
    }
  }

  Future<void> submit(
    String raw, {
    required String inputWindow,
    required CompanionAgentRoomUi origin,
    required CompanionMapHandoff handoff,
    required bool Function() originCurrent,
    bool replacePreparing = false,
    String? assistantPage,
    bool returnToApp = false,
    void Function(MemoryRow)? onCommitted,
  }) async {
    if (!active || !originCurrent() || raw.trim().isEmpty || (preparing && !replacePreparing)) return;
    final noticeReply = notices?.replyContext(raw, retrySource: retrySource?['id'] as String?);
    notices?.invalidate(keepReply: true);
    lastUserInteractionAt = DateTime.now();
    acted();
    memory?.cancelWork();
    final previous = retrySource;
    // Take only this visit's drained, no-tool retry before stop retires other
    // pending work. A new wrapper must capture the new submission below.
    CompanionAgentMemoryTools? inheritedRetry;
    if (previous?['text'] == raw && retryTools?.isCurrent == true) {
      inheritedRetry = retryTools;
      retryTools = null;
    }
    stop();
    run = null;
    final number = ++submission;
    final visitCurrent = captureCurrent();
    bool current() => visitCurrent() && submission == number;
    // Capture the actual window before any await. Detach retires only its UI
    // and foreground capabilities, never lends them to a replacement window.
    final taskUi = origin.tasks(isCurrent: () => current() && originCurrent());
    runOrigin = origin;
    runMapHandoff = handoff;
    void failed(Object error, {String? retry}) {
      if (originCurrent()) {
        origin.failed(error, retry: retry);
      } else {
        residentUi?.failed(error, retry: retry);
      }
    }

    preparing = true;
    changed();
    CompanionAgentMemoryTools? memoryTools;
    CompanionAgentTaskTools? taskTools;
    CompanionAgentPhoneTools? phoneTools;
    _CompanionAgentRun? submittedRun;
    Completer<void>? settled;
    try {
      final submittedAt = DateTime.now();
      final owner = await openMemory();
      if (!current()) return;
      owner.cancelWork();
      settled = Completer<void>();
      owner.retainReceipt(settled.future);
      final sessionId = owner.store.lightSessionId;
      final reuse =
          previous != null &&
          previous['text'] == raw &&
          previous['session_id'] == sessionId &&
          previous['character_id'] == characterId &&
          (previous['first_seq']! as int) > (owner.store.archive['history_after_seq']! as int);
      if (reuse && (inheritedRetry == null || !identical(inheritedRetry.memory, owner))) {
        // A closed/used turn is not a new model-planning opportunity. Its
        // original receipts and manual task/memory entry points stay intact.
        failed(_agentRetryClosed);
        return;
      }
      if (!reuse) {
        inheritedRetry?.close();
        inheritedRetry = null;
      }
      CompanionReminderClock? sourceClock;
      if (!reuse) {
        try {
          sourceClock = await ref.read(companionRemindersProvider).clock();
        } on MissingPluginException {
          // Chat still works. Date-dependent tools see the genuine missing zone.
        } on PlatformException {
          // Never guess an IANA zone from the local numeric offset.
        }
      }
      if (!current()) return;
      final source = retrySource = reuse
          ? previous
          : owner.store.submitMessage(
              id: companionMemoryId(),
              sessionId: sessionId,
              text: raw,
              saidAtUtc: sourceClock?.utcMs ?? submittedAt.toUtc().millisecondsSinceEpoch,
              offsetMinutes: sourceClock == null
                  ? submittedAt.timeZoneOffset.inMinutes
                  : sourceClock.offsetSeconds ~/ 60,
              zoneId: sourceClock?.zoneId,
              offsetSeconds: sourceClock?.offsetSeconds,
              characterId: characterId,
            );
      recordInteraction('chat', source: source);
      onCommitted?.call(source);
      if (farewell.hasMatch(raw.trim())) followupRetired = true;
      if (originCurrent()) origin.committed(raw);
      final now = sourceClock == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(sourceClock.utcMs, isUtc: true);
      // Every explicit user turn receives a current clock. A live retry keeps
      // its stored source/clock identity and takes no second native sample.
      final sampledContext = companionTurnContext(
        now: now,
        utcOffsetMinutes: sourceClock == null ? now.timeZoneOffset.inMinutes : sourceClock.offsetSeconds ~/ 60,
        lastSpokenAt: lastSpokenAt,
        lastClockAt: lastClockAt,
        askTime: true,
        events: events,
      );
      final turnContext = CompanionTurnContext(
        Map.unmodifiable({
          ...sampledContext.data,
          if (noticeReply != null) 'noticeReply': noticeReply.context,
          'window': inputWindow,
          if (sourceClock != null) 'zoneId': sourceClock.zoneId,
          // A retry's current clock is not when its unchanged words were said.
          if (reuse)
            'originalMessage': {
              ...companionTurnContext(
                now: DateTime.fromMillisecondsSinceEpoch(source['said_at_utc']! as int, isUtc: true),
                utcOffsetMinutes: source['offset_minutes']! as int,
                askTime: true,
              ).data,
              if (source['zone_id'] case final String zone) 'zoneId': zone,
            },
        }),
        sampledContext.eventIds,
        sampledAt: sampledContext.sampledAt,
        hasClock: sampledContext.hasClock,
      );
      lastSpokenAt = now;
      await ref.read(companionPersonaProvider.notifier).ready;
      if (!current()) return;
      final persona = ref.read(companionPersonaProvider);
      final system = companionLightSystem(
        persona: companionPersona(
          custom: persona.custom,
          name: ref.read(companionNameProvider) ?? character.name,
          callMe: persona.callMe,
          tools: true,
          moves: moves.rules(),
          whale: companionIsWhale(characterSourceKey, character.name),
        ),
      );
      memoryTools = CompanionAgentMemoryTools(
        memory: owner,
        source: source,
        isCurrent: current,
        onCommitted: agent.confirmControlRevision,
        forgottenNotice: origin.forgottenNotice,
        semanticRecall: (query) => owner.recallIds(
          query,
          characterId: source['character_id'] as String?,
          isCurrent: () => current() && memoryTools?.isCurrent == true,
        ),
      );
      // beginAgentTurn has read the same open source/revision/turn. Calling
      // close on the obsolete wrapper would close the new wrapper's turn too.
      inheritedRetry = null;
      final capturedHost = agent._host!();
      CompanionAgentTaskHost? host;
      if (capturedHost != null) {
        final client = capturedHost.client;
        final hostRef = capturedHost.host;
        bool hostCurrent() =>
            current() &&
            ref.read(activeHostProvider) == hostRef &&
            identical(ref.read(activeConnectionProvider).value?.client, client);
        host = CompanionAgentTaskHost(
          key: companionHostKey(hostRef),
          client: client,
          isCurrent: hostCurrent,
          sessionId: client == null ? null : ref.read(companionSessionsProvider.notifier).of(hostRef)?.sessionId,
          ensureSession: () async {
            if (client == null || !hostCurrent()) throw const DshClosedException('Companion Host changed');
            final binding = await ref
                .read(companionSessionsProvider.notifier)
                .ensure(
                  memoryArchiveId: owner.store.archive['id']! as String,
                  memoryControlRevision: owner.store.archive['control_revision']! as int,
                );
            if (!hostCurrent()) throw const DshClosedException('Companion Host changed');
            return binding.sessionId;
          },
        );
      }
      taskTools = CompanionAgentTaskTools(
        memoryTools: memoryTools,
        source: source,
        roomMode: light ? 'light' : 'full',
        reminders: ref.read(companionRemindersProvider),
        maps: ref.read(companionMapsProvider),
        mapHandoff: handoff,
        ui: taskUi,
        apiKey: agent._apiKey(),
        lightClientFactory: agent._client,
        requestId: companionMemoryId,
        host: host,
      );
      phoneTools = CompanionAgentPhoneTools(
        memory: owner,
        source: source,
        turnId: memoryTools.turnId,
        returnToApp: returnToApp,
        window: inputWindow,
        isCurrent: () => current() && memoryTools?.isCurrent == true,
        onStep: (text) {
          if (residentUi case final CompanionAgentAmbientUi target when current() && target.presentationAvailable) {
            unawaited(target.presentLine(id: 'phone:${source['id']}', text: text, emotion: 'neutral', speak: false));
          }
        },
      );
      activePhoneTools = phoneTools;
      final photoTools = CompanionAgentPhotoTools(
        describe: (image, question) =>
            agent.describePhoto(owner: owner, image: image, question: question, isCurrent: current),
      );
      if (noticeReply?.draftOnly != true) await phoneTools.prepare();
      if (!current()) return;
      if (noticeReply != null) {
        await notices?.refresh();
        if (!current() || notices?.replyCurrent(noticeReply) != true) {
          throw const DshClosedException('Notice reply context changed');
        }
      }
      preparing = false;
      final work = agent.say(
        memory: owner,
        source: source,
        system: system,
        context: turnContext,
        assistantPage: assistantPage,
        tools: noticeReply == null
            ? [
                ...memoryTools.bindings,
                ...taskTools.bindings,
                ...phoneTools.bindings,
                if (ref.read(androidSystemFeaturesProvider)) ...photoTools.bindings,
              ]
            : noticeReply.draftOnly
            ? const []
            : phoneTools.bindings,
        isCurrent: current,
        onSelected: memoryTools.grantSelection,
        onStop: phoneTools.stop,
      );
      submittedRun = run = agent._run;
      if (submittedRun != null) notices?.bindReply(submittedRun, noticeReply);
      changed();
      await work;
      if (!current() || !identical(run, submittedRun)) return;
      if (submittedRun!.text.trim().isNotEmpty) {
        events = companionConsumeEvents(events, turnContext.eventIds);
        if (turnContext.hasClock) lastClockAt = turnContext.sampledAt;
      }
      if (submittedRun.error case final error?) {
        // say has returned after its physical request's first cancel drain.
        // No tool callback has entered, so the original clock and budget can
        // survive until a later explicit click in this same live visit.
        if (submittedRun.toolDispatchStarted) {
          failed(_agentRetryClosed);
        } else if (memoryTools.isCurrent) {
          // No tool ran, with or without words: retrying reuses the same line.
          retryTools = memoryTools;
          memoryTools = null;
          failed(error, retry: raw);
        } else {
          retrySource = null;
          failed(error, retry: raw);
        }
      } else if (submittedRun.text.trim().isNotEmpty || !submittedRun.toolDispatchStarted) {
        retrySource = null;
      }
      queueExtraction();
    } on Object catch (error) {
      if (current()) failed(error, retry: raw);
    } finally {
      // Fresh foreground work is handed to its original detail route only
      // after every tool/picker in this turn finishes. No active scope moves.
      try {
        await phoneTools?.close(stopped: !current() || submittedRun?.cancelled == true);
      } finally {
        if (identical(activePhoneTools, phoneTools)) activePhoneTools = null;
        try {
          taskTools?.close();
        } finally {
          try {
            memoryTools?.close();
          } finally {
            try {
              inheritedRetry?.close();
            } finally {
              settled?.complete();
            }
          }
        }
      }
      if (current()) {
        preparing = false;
        notices?.tick();
        changed();
      }
    }
  }

  void stop({bool discard = false}) {
    activePhoneTools?.stop();
    agent.cancelScreenObservation();
    final pendingRetry = retryTools;
    retryTools = null;
    pendingRetry?.close();
    submission++;
    preparing = false;
    runMapHandoff?.close();
    runMapHandoff = null;
    if (run != null && identical(run, agent._run)) agent.stop(discard: discard);
    changed();
  }

  Future<void> restart() async {
    if (!active) return;
    stop(discard: true);
    final current = captureCurrent();
    final owner = await openMemory();
    if (!current()) return;
    owner.store.startLightConversation();
    retrySource = null;
    lastSpokenAt = null;
    lastClockAt = null;
    run = null;
    // Retire the old native conversation at the same real session boundary.
    // This also fences queued resident output; task reminders are independent.
    residentUi?.controlChanged(own: false);
    changed();
  }

  void remember(String kind, String? note) {
    if (!active || note == null) return;
    final now = DateTime.now();
    events = companionRecentEvents([
      ...events,
      CompanionContextEvent(id: 'e-${now.microsecondsSinceEpoch}-${++eventSerial}', kind: kind, at: now, detail: note),
    ], now: now);
  }

  Future<CompanionSnapshot?> refreshKeeper() async {
    final current = captureCurrent();
    final owner = await openMemory();
    if (!current()) return null;
    final role = characterId;
    if (role == null) return null;
    final directory = await root;
    if (!current() || role != characterId) return null;
    // Immediate activity still uses the existing phone calculation. Its
    // compatibility closeness field is never imported or used as v2 affinity.
    // Activity no longer writes the original root file in either room mode.
    final next = phone ??= ref.read(companionPhoneKeeperProvider)(Directory('${directory.path}/activity/$role'));
    unawaited(importLegacyAffinity(owner, role, current));
    CompanionSnapshot? value;
    try {
      value = await next.snapshot().timeout(const Duration(seconds: 3));
    } on Object {
      // A missing keeper never prevents phone conversation.
    }
    if (!current() || role != characterId) return null;
    if (value != null) {
      keeper = next;
      snapshot = value;
      ui.vitalsChanged(value);
    }
    return value;
  }

  Future<void> importLegacyAffinity(CompanionMemoryOwner owner, String role, bool Function() current) async {
    final settled = Completer<void>();
    owner.retainReceipt(settled.future);
    bool here() => current() && identical(memory, owner) && characterId == role;
    void importSeed(String kind, CompanionSnapshot value) {
      if (!here()) return;
      final now = clock();
      if (owner.store.importCompanionAffinity(
        characterId: role,
        sourceKind: kind,
        sourceId: value.storeId,
        closeness: value.vitals.closeness,
        observedAtMs: now.wallMs,
        offsetMinutes: now.offsetMinutes,
      )) {
        owner.changed();
      }
    }

    try {
      // probeForMigration does not create a missing legacy file. The actual
      // snapshot must still be from that same store before its value is used.
      try {
        final existing = await owner.legacy.probeForMigration();
        if (!here()) return;
        if (existing != null) {
          final previous = await owner.legacy.companionSnapshot();
          if (previous.storeId == existing.storeId) importSeed('phone', previous);
        }
      } on Object {
        // A corrupt or unavailable source remains untouched for later review.
      }
      if (!here() || light) return;
      final client = ref.read(activeConnectionProvider).value?.client;
      if (client == null) return;
      try {
        final previous = await client.companionSnapshot().timeout(const Duration(seconds: 3));
        if (previous != null && here() && identical(ref.read(activeConnectionProvider).value?.client, client)) {
          importSeed('host', previous);
        }
      } on Object {
        // This GET is a possible legacy seed, never a Host activity write.
      }
    } finally {
      settled.complete();
    }
  }

  Future<void> arrive({bool greet = true, bool Function()? windowCurrent}) async {
    final visitCurrent = captureCurrent();
    final arrivalUi = ui;
    bool current() => visitCurrent() && (windowCurrent?.call() ?? identical(arrivalUi, ui));
    final value = await refreshKeeper();
    if (!current()) return;
    if (greet) await arrivalUi.greet(value?.vitals.lastVisitAt, current);
    if (current() && value != null && arrivalUi.initiativeView.visible) event('visit');
  }

  void event(String type) {
    if (const {'pet', 'snack', 'play'}.contains(type)) {
      lastUserInteractionAt = DateTime.now();
      recordInteraction(type);
    }
    final owner = keeper;
    if (!active || owner == null) return;
    final current = captureCurrent();
    vitalsQueue = vitalsQueue.then((_) async {
      if (!current() || !identical(owner, keeper)) return;
      final read = snapshot;
      if (read == null) return;
      try {
        CompanionSnapshot? next;
        try {
          next = await owner.event(read, type);
        } on DshRemoteException catch (error) {
          if (!current() || (!error.code.endsWith('conflict') && !error.code.endsWith('store-changed'))) return;
          next = await owner.snapshot();
        }
        if (current() && next != null) {
          snapshot = next;
          ui.vitalsChanged(next);
        }
      } on Object {
        // Refresh failure leaves the queue usable; no event write is retried.
      }
    });
  }

  void observe(CompanionInitiativeView view) {
    if (!active) return;
    observePresence(view);
    settleAffinity();
    final target = initiativeUi;
    final deliveredView = identical(target, window?.ui) ? view : target.initiativeView;
    if (entered && identical(enteredRoom, target.initiativeRoom)) {
      initiative.observe(target.initiativeRoom, deliveredView);
    } else {
      if (enteredRoom case final old?) initiative.leave(old);
      entered = true;
      enteredRoom = target.initiativeRoom;
      initiative.enter(target.initiativeRoom, deliveredView);
    }
    if (notices?.offer() != true) requestFollowup(deliveredView, target);
    if (residentUi != null) {
      residentSignals ??= CompanionResidentSignals(
        ref: ref,
        clock: clock,
        isCurrent: () =>
            active &&
            residentUi != null &&
            identical(initiativeUi, residentUi) &&
            residentUi!.initiativeView.notificationAvailable,
        isOwnSession: (session) =>
            session == memory?.store.lightSessionId ||
            ref.read(companionSessionFilterProvider)(ref.read(activeHostProvider), session),
        offer: offerResidentSignal,
      );
      residentSignals!.refresh();
    }
  }

  void settleAffinity() {
    final owner = memory;
    if (!active || owner == null) return;
    final now = clock();
    final day = (now.wallMs + now.offsetMinutes * 60000) ~/ 86400000;
    if (affinitySettledDay == day) return;
    final segment = presence;
    if (segment != null &&
        flushPresence(segment, now, force: true) &&
        segment.persistedMs < now.monoMs - segment.monoMs) {
      // Do not close yesterday over a failed checkpoint of a measured live
      // segment. A later observation can retry the same cumulative identity.
      return;
    }
    try {
      final settled = owner.store.settleCompanionAffinity(nowMs: now.wallMs, offsetMinutes: now.offsetMinutes);
      affinitySettledDay = day;
      if (settled.isNotEmpty) owner.changed();
    } on Object {
      // The SDK watermark remains authoritative; another actual observation
      // can retry without inventing activity or requiring a model request.
    }
  }

  void recordInteraction(String kind, {MemoryRow? source}) {
    final owner = memory;
    final role = characterId;
    if (!active || owner == null || role == null) return;
    final stamp = clock();
    if (source == null && stamp.monoMs < 0) return;
    try {
      owner.store.recordCompanionInteraction(
        characterId: role,
        eventId: source?['id'] as String? ?? companionMemoryId(),
        kind: kind,
        atMs: source?['said_at_utc'] as int? ?? stamp.wallMs,
        offsetMinutes: source?['offset_minutes'] as int? ?? stamp.offsetMinutes,
        sourceId: source?['id'] as String?,
      );
    } on Object {
      // Optional relationship accounting never fabricates a successful write
      // and never turns an already committed chat into a new submission.
    }
  }

  void observePresence(CompanionInitiativeView view) {
    final owner = memory;
    final role = characterId;
    final now = clock();
    if (!view.visible || !view.resumed || owner == null || role == null || now.monoMs < 0) {
      finishPresence(now);
      return;
    }
    final previous = presence;
    if (previous != null &&
        (!identical(previous.memory, owner) ||
            previous.characterId != role ||
            previous.offsetMinutes != now.offsetMinutes ||
            !flushPresence(previous, now))) {
      finishPresence(now);
    }
    presence ??= _CompanionPresence(owner, role, companionMemoryId(), now);
  }

  bool flushPresence(_CompanionPresence segment, CompanionInitiativeClock now, {bool force = false}) {
    final elapsed = now.monoMs - segment.monoMs;
    // A clock discontinuity supplies no evidence for the unobserved interval.
    // The existing sampler/controller uses the same one-second wall tolerance.
    if (now.monoMs < 0 ||
        elapsed < segment.persistedMs ||
        ((now.wallMs - segment.startedAtMs) - elapsed).abs() > 1000) {
      return false;
    }
    if (!force && elapsed - segment.persistedMs < 60000) return true;
    if (elapsed == segment.persistedMs) return true;
    try {
      segment.memory.store.recordCompanionPresence(
        characterId: segment.characterId,
        segmentId: segment.id,
        startedAtMs: segment.startedAtMs,
        elapsedMs: elapsed,
        offsetMinutes: segment.offsetMinutes,
      );
      segment.persistedMs = elapsed;
    } on Object {
      // The next checkpoint can submit the same cumulative segment again.
      // A failed final write is not reconstructed from a later wall clock.
    }
    return true;
  }

  void finishPresence([CompanionInitiativeClock? now]) {
    final previous = presence;
    presence = null;
    if (previous != null) flushPresence(previous, now ?? clock(), force: true);
  }

  static bool presentable(CompanionInitiativeView view) =>
      ((view.visible && view.resumed) || view.notificationAvailable) && !view.blocked && view.enabled;

  void requestFollowup(CompanionInitiativeView view, CompanionAgentRoomUi target) {
    final owner = memory;
    if (owner == null ||
        owner.working ||
        preparing ||
        agent.running ||
        followupRetired ||
        !presentable(view) ||
        initiative.fault != null) {
      return;
    }
    final now = clock();
    final role = characterId;
    final window = '${view.contextKey}:$controlRevision';
    if (followupWindow != window) {
      followupWindow = window;
      followupAttempts.clear();
    }
    MemoryRow? opportunity;
    try {
      opportunity = owner.store.nextAgentFollowup(nowMs: now.wallMs, characterId: role, excludedIds: followupAttempts);
    } on Object {
      return;
    }
    if (opportunity == null) return;
    final captured = opportunity;
    final visitCurrent = captureCurrent();
    final candidate = CompanionInitiativeSignal(
      id: 'followup:${captured['id']}:${captured['row_rev']}:${captured['control_revision']}',
      contextKey: view.contextKey,
      expiresAtMonoMs: now.monoMs + math.min(120000, (captured['expires_at_ms']! as int) - now.wallMs),
    );
    bool current() =>
        visitCurrent() &&
        identical(owner, memory) &&
        characterId == role &&
        !followupRetired &&
        identical(initiativeUi, target) &&
        candidate.contextKey == target.initiativeView.contextKey &&
        owner.store.isAgentFollowupCurrent(captured, nowMs: clock().wallMs, characterId: role);
    String? line;
    String? notificationTicket;
    final notify = switch (target) {
      final CompanionAgentNotificationUi notify => notify,
      _ => null,
    };
    void recordPresented() {
      if (role == null) return;
      try {
        final shown = owner.store.followups().singleWhere((row) => row['id'] == captured['id']);
        if (shown['state'] != 'asked' || shown['presented_at_ms'] is! int) return;
        owner.store.recordCompanionPresentation(
          characterId: role,
          // UI ticket counters restart; the shown opportunity is durable.
          presentationId: 'followup:${captured['id']}',
          kind: 'followup',
          presentedAtMs: shown['presented_at_ms']! as int,
          opportunityId: captured['id']! as String,
        );
      } on Object {
        /* No shown receipt means no presentation fact. */
      }
    }

    initiative.requestSignal(
      target.initiativeRoom,
      view,
      candidate,
      followupId: captured['id']! as String,
      isCurrent: current,
      prepare: () async {
        // A failed preparation is skipped for this opportunity, not marked
        // asked. The next observation may consider another eligible card.
        followupAttempts.add(captured['id']! as String);
        await ref.read(companionPersonaProvider.notifier).ready;
        if (!current() || !presentable(target.initiativeView)) return false;
        final persona = ref.read(companionPersonaProvider);
        line = await owner.followup(
          this,
          captured,
          persona:
              companionPersonaPart(
                custom: persona.custom,
                name: ref.read(companionNameProvider) ?? character.name,
                callMe: persona.callMe,
                whale: companionIsWhale(characterSourceKey, character.name),
              ) +
              owner.relationshipContext(role, forInitiative: true),
          offsetMinutes: clock().offsetMinutes,
          isCurrent: () {
            final now = clock();
            return current() &&
                presentable(target.initiativeView) &&
                now.monoMs < candidate.expiresAtMonoMs &&
                companionNightKey(now.wallMs, now.offsetMinutes) == null;
          },
        );
        return line != null;
      },
      present: (display) {
        if (!current() || line == null || !target.presentFollowup(display, line!)) return false;
        if (role != null) {
          // The initiative owner settles its real shown receipt synchronously
          // after this callback. Record only after that settlement, while the
          // original phone database is still retained.
          final receipt = Future<void>.microtask(() {
            recordPresented();
          });
          owner.retainReceipt(receipt);
        }
        return true;
      },
      deliver: notify == null
          ? null
          : (display) async {
              if (!current() || line == null) return false;
              notificationTicket = display.ticket.id;
              return notify.deliverFollowup(id: 'followup:${captured['id']}', text: line!);
            },
      retainDelivery: (future) {
        owner.retainReceipt(
          future.then((_) {
            if (notificationTicket != null) recordPresented();
          }),
        );
      },
      hide: target.hideFollowup,
    );
  }

  void acted() {
    if (!active) return;
    followupWindow = null;
    followupAttempts.clear();
    if (enteredRoom case final room?) initiative.activate(room);
  }

  void offerResidentSignal(CompanionSignalSpeech speech, bool Function() signalCurrent) {
    final target = residentUi;
    if (target == null) return;
    final notify = switch (target) {
      final CompanionAgentNotificationUi notify => notify,
      _ => null,
    };
    if (notify == null) return;
    _offerTaskSignal(
      speech,
      target: target,
      recipientCurrent: () => identical(residentUi, target),
      signalCurrent: signalCurrent,
      present: (display, text) => false,
      deliver: (text) => notify.deliverFollowup(id: 'task:${speech.slot.signal.id}', text: text),
    );
  }

  void _offerTaskSignal(
    CompanionSignalSpeech speech, {
    required CompanionAgentRoomUi target,
    required bool Function() recipientCurrent,
    required bool Function() signalCurrent,
    required bool Function(CompanionInitiativeDisplay, String) present,
    Future<bool> Function(String)? deliver,
  }) {
    final owner = memory;
    if (owner == null || !active || !recipientCurrent() || !identical(initiativeUi, target)) return;
    final view = target.initiativeView;
    final candidate = CompanionInitiativeSignal(
      id: speech.id,
      contextKey: view.contextKey,
      expiresAtMonoMs: speech.expiresAtMonoMs,
      nightKey: speech.nightKey,
    );
    final visitCurrent = captureCurrent();
    bool current() => visitCurrent() && recipientCurrent() && identical(initiativeUi, target) && signalCurrent();
    initiative.requestSignal(
      target.initiativeRoom,
      view,
      candidate,
      isCurrent: current,
      present: (display) => current() && present(display, speech.text),
      hide: (_) {},
      nightCareEnabled: speech.nightCare,
      deliver: deliver == null
          ? null
          : (_) async {
              if (!current()) return false;
              return deliver(speech.text);
            },
      retainDelivery: owner.retainReceipt,
    );
  }

  void presentedReply(String replyId, String text, {required Set<String> sourceIds}) {
    final shown = run;
    final owner = memory;
    final role = characterId;
    if (!active ||
        owner == null ||
        shown == null ||
        shown.discard ||
        !identical(shown.memory, owner) ||
        shown.source['character_id'] != role ||
        shown.replyId != replyId ||
        shown.text != text) {
      return;
    }
    notices?.presentedReply(shown, text, sourceIds);
    if (role == null) return;
    final at = clock().wallMs;
    for (final id in sourceIds) {
      final range = shown.unpresentedReplies[id];
      if (range == null || range.end > text.length) continue;
      try {
        owner.store.recordCompanionPresentation(
          characterId: role,
          presentationId: 'assistant:$id',
          kind: 'assistant',
          presentedAtMs: at,
          assistantSourceId: id,
        );
        shown.unpresentedReplies.remove(id);
      } on Object {
        // No fabricated presentation on an unavailable/deleted source. A
        // later actual frame may retry; leaving never fabricates a frame.
      }
    }
  }

  void connectionChanged({bool generationChanged = false}) {
    if (!active) return;
    final host = ref.read(activeHostProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    final nextLight = light;
    final differs =
        nextLight != boundLight ||
        (!nextLight && (generationChanged || host != boundHost || !identical(client, boundClient)));
    boundHost = host;
    boundClient = client;
    boundLight = nextLight;
    if (memory case final owner?) unawaited(resumeNotes(owner));
    if (!differs) return;
    notices?.invalidate();
    memory?.invalidateRawErase(this);
    stop();
    memory?.cancelWork();
    epoch++;
    keeper = null;
    snapshot = null;
    vitalsQueue = Future.value();
    ui.connectionChanged();
    unawaited(migrateHostMemory());
    // She arrives at the new keeper as on opening: its state, her greeting,
    // then this visit recorded there.
    if (ui.stageReady) unawaited(arrive());
  }

  Future<void> migrateHostMemory() async {
    final owner = memory;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (!active || owner == null || client == null || light) return;
    refreshHostUsage();
    final hostKey = companionHostKey(ref.read(activeHostProvider));
    try {
      await owner.migrateHost(client);
      final stored = await companionRecallStored(hostKey);
      if (stored == null) return;
      if (!stored.off) {
        final capability = await client.readCompanionRecallCapabilities();
        if (capability == null) throw const DshClosedException('legacy recall cleanup pending');
        try {
          await client.revokeCompanionRecall(
            capability,
            operationId: newCompanionRecallId(),
            bindingId: stored.bindingId,
          );
        } on DshRemoteException catch (error) {
          if (!error.code.endsWith('not-found') && !error.code.endsWith('retired')) rethrow;
        }
      }
      await companionRecallClear(hostKey, stored.bindingId);
    } on Object {
      // Only original bindings are read/retired; a later visit can retry.
    }
  }

  void refreshHostUsage() {
    final owner = memory;
    final client = ref.read(activeConnectionProvider).value?.client;
    if (!active || light || owner == null || client == null) return;
    unawaited(
      owner.refreshHostChatUsage(client, companionHostKey(ref.read(activeHostProvider))).catchError((Object _) {}),
    );
  }

  Future<void> resumeLookups(CompanionMemoryOwner owner) async {
    // These are already persisted tasks, not fresh model intents. Preserve the
    // executor and original source; no old Host lookup is re-created on phone.
    final originalSessions = [
      owner.store.lightSessionId,
      if (!light) 'full:${companionHostKey(ref.read(activeHostProvider))}',
    ];
    final pending = [for (final session in originalSessions) ...owner.store.tasks(sourceSessionId: session)]
        .where((row) => row['kind'] == 'public.lookup' && const ['queued', 'running', 'unknown'].contains(row['state']))
        .toList();
    if (pending.isEmpty) return;
    final reminders = ref.read(companionRemindersProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    final hostKey = companionHostKey(ref.read(activeHostProvider));
    final key = agent._apiKey();
    final operation = () async {
      try {
        final executor = await reminders.executorId();
        for (final row in pending) {
          final task = owner.store.lookupTask(row['task_id']! as String)!;
          if (task['cancel_requested'] == 1) {
            await owner.lookups.stop(task, executorId: executor, host: client, hostKey: hostKey);
          } else {
            await owner.lookups.run(
              task,
              executorId: executor,
              requestId: companionMemoryId,
              estimateTokens: estimateCompanionMemoryTokens,
              host: client,
              hostKey: hostKey,
              direct: CompanionLookupDirect(
                client: agent._client,
                apiKey: () => key,
                nowMilliseconds: owner.lookups.nowMilliseconds,
                estimateTokens: estimateCompanionMemoryTokens,
              ),
            );
          }
        }
      } on Object {
        // The persisted command remains available through its original detail.
      }
    }();
    owner.retainReceipt(operation);
    await operation;
  }

  Future<void> resumeNotes(CompanionMemoryOwner owner) async {
    final client = ref.read(activeConnectionProvider).value?.client;
    if (!active || client == null) return;
    final hostKey = companionHostKey(ref.read(activeHostProvider));
    final tasks = [
      ...[
        for (final session in [owner.store.lightSessionId, if (!light) 'full:$hostKey'])
          ...owner.store.tasks(sourceSessionId: session),
      ].where(
        (row) =>
            row['kind'] == 'host.notes_to_todo' &&
            row['host_key'] == hostKey &&
            const ['queued', 'waiting', 'running', 'unknown'].contains(row['state']),
      ),
      ...owner.store.pendingFindDraftTasks(hostKey: hostKey),
      ...owner.store.pendingCompareDraftTasks(hostKey: hostKey),
      ...owner.store.pendingReceiptsTasks(hostKey: hostKey),
    ];
    for (final task in tasks) {
      try {
        final current = owner.store.hostTask(task['task_id']! as String)!;
        final agreement = current['agreement']! as MemoryRow;
        final firstDelivery =
            const ['host.find_draft', 'host.compare_drafts', 'host.receipts_to_sheet'].contains(current['kind']) &&
            current['state'] == 'queued' &&
            current['host_store_id'] != null &&
            current['cancel_requested'] == 0 &&
            agreement['allowQueue'] == true &&
            agreement['afterExit'] == 'continue' &&
            owner.store
                .hostTaskCommands(current['task_id']! as String)
                .every((row) => row['possible_sent_at_ms'] == null);
        await owner.hostTasks.run(current, client: client, hostKey: hostKey, submitPending: firstDelivery);
      } on Object {
        // Original IDs/possible dispatch remain. This never opens a new scope.
      }
    }
  }

  void close() {
    if (closed) return;
    finishPresence();
    final oldWindow = window;
    final oldUi = oldWindow?.ui ?? residentUi;
    window?.attached = false;
    window?.mapHandoff.close();
    oldUi?.detached();
    notices?.close();
    notices = null;
    closed = true;
    stop(discard: true);
    idleTimer?.cancel();
    usageTimer?.cancel();
    quietTimer?.cancel();
    residentSignals?.close();
    residentSignals = null;
    for (final close in subscriptions) {
      close();
    }
    subscriptions.clear();
    memory?.removeListener(memoryChanged);
    memory?.leave(this, characterId: characterId, actualRoomLeave: oldWindow != null);
    if (enteredRoom case final room?) initiative.leave(room);
    enteredRoom = null;
    window = null;
    residentUi = null;
    residentMapHandoff?.close();
    residentMapHandoff = null;
    if (oldWindow != null) unawaited(companionMarkSeen(DateTime.now()));
    if (identical(agent._visit, this)) agent._visit = null;
  }
}

class _CompanionPresence {
  _CompanionPresence(this.memory, this.characterId, this.id, CompanionInitiativeClock now)
    : startedAtMs = now.wallMs,
      monoMs = now.monoMs,
      offsetMinutes = now.offsetMinutes;

  final CompanionMemoryOwner memory;
  final String characterId;
  final String id;
  final int startedAtMs;
  final int monoMs;
  final int offsetMinutes;
  int persistedMs = 0;
}
