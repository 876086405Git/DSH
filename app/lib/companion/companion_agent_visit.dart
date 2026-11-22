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
  CompanionAgentAttachment._(this._visit);
  final _CompanionAgentVisit _visit;

  bool get isAttached => _visit.active;
  bool get preparing => _visit.preparing;
  bool get running => _visit.run?.running ?? false;
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
  CompanionSnapshot? get vitals => _visit.snapshot;
  bool get light => _visit.light;
  bool Function() captureCurrent() => _visit.captureCurrent();
  Future<CompanionMemoryOwner> openMemory() => _visit.openMemory();
  Future<void> submit(String raw) => _visit.submit(raw);
  Future<void> arrive({bool greet = true}) => _visit.arrive(greet: greet);
  Future<void> restart() => _visit.restart();
  void stop({bool discard = false}) => _visit.stop(discard: discard);
  void event(String type) => _visit.event(type);
  void remember(String kind, String? note) => _visit.remember(kind, note);
  void observe(CompanionInitiativeView view) => _visit.observe(view);
  void acted() => _visit.acted();
  void updateCharacter(CompanionCharacter character, CompanionMoves moves) {
    if (!_visit.active) return;
    _visit.character = character;
    _visit.moves = moves;
  }

  void detach() => _visit.close();
}

class _CompanionAgentVisit {
  _CompanionAgentVisit(this.agent, this.ref, this.root, this.character, this.moves, this.ui, this.mapHandoff)
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
    idleTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (active) {
        observe(ui.initiativeView);
        unawaited(consolidate());
      }
    });
    usageTimer = Timer.periodic(const Duration(seconds: 15), (_) => refreshHostUsage());
  }

  final CompanionAgent agent;
  final Ref ref;
  final Future<Directory> root;
  final CompanionAgentRoomUi ui;
  final CompanionMapHandoff mapHandoff;
  final CompanionInitiative initiative;
  final CompanionInitiativeClock Function() clock;
  final subscriptions = <void Function()>[];
  CompanionCharacter character;
  CompanionMoves moves;
  HostRef boundHost;
  DshClient? boundClient;
  late bool boundLight;
  bool closed = false;
  bool preparing = false;
  bool entered = false;
  int epoch = 0;
  int submission = 0;
  int controlRevision = 0;
  CompanionMemoryOwner? memory;
  Future<CompanionMemoryOwner>? opening;
  MemoryRow? retrySource;
  CompanionAgentMemoryTools? retryTools;
  _CompanionAgentRun? run;
  Timer? quietTimer;
  Timer? idleTimer;
  Timer? usageTimer;
  CompanionKeeper? phone;
  CompanionKeeper? keeper;
  CompanionSnapshot? snapshot;
  Future<void> vitalsQueue = Future.value();
  DateTime? lastSpokenAt;
  DateTime? lastClockAt;
  List<CompanionContextEvent> events = const [];
  int eventSerial = 0;
  String? followupAttempt;
  bool followupRetired = false;
  static final farewell = RegExp(
    r'^(?:(?:晚安|再见)(?:[，,\s]+(?:我)?先走了)?|(?:我)?先走了|good ?night|goodbye|bye)[。.!！]*$',
    caseSensitive: false,
  );

  bool get active => !closed && !agent._disposed && identical(agent._visit, this) && ui.mounted;
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
    final owner = await ref.read(companionMemoryOwnerProvider(directory.absolute.path).future);
    if (!active) return owner;
    memory = owner;
    controlRevision = owner.store.archive['control_revision']! as int;
    owner.addListener(memoryChanged);
    await initiative.attachMemory(owner.store);
    try {
      await owner.migrateLocal();
    } on Object {
      // The original migration retries on another visit.
    }
    if (!active) return owner;
    owner.enter(this, transport: agent._memoryTransport!, estimateTokens: estimateCompanionMemoryTokens);
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
    final owner = memory;
    if (!active || owner == null) return;
    final revision = owner.store.archive['control_revision']! as int;
    if (revision != controlRevision) {
      final own = identical(run, agent._run) && agent.acceptsControl(owner, revision);
      controlRevision = revision;
      owner.cancelWork();
      quietTimer?.cancel();
      if (!own) {
        stop(discard: true);
        epoch++;
        keeper = null;
        snapshot = null;
        vitalsQueue = Future.value();
      }
      // The real commit has already happened. Acknowledge it synchronously to
      // the window; delayed widget cleanup cannot replace a newer reply.
      ui.controlChanged(own: own);
      unawaited(clearWidget());
      unawaited(ref.read(companionSessionsProvider.notifier).forgetAll());
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
    if (!active || owner == null) return;
    try {
      await owner.extract(this, forceTail: forceTail);
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
    if (!view.visible || !view.resumed || view.blocked) return;
    try {
      await owner.consolidate(this);
    } on Object {
      // Existing cards remain available when optional maintenance cannot run.
    }
  }

  Future<void> submit(String raw) async {
    if (!active || raw.trim().isEmpty || preparing) return;
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
    preparing = true;
    changed();
    CompanionAgentMemoryTools? memoryTools;
    CompanionAgentTaskTools? taskTools;
    Completer<void>? settled;
    try {
      final submittedAt = DateTime.now();
      final owner = await openMemory();
      if (!current()) return;
      settled = Completer<void>();
      owner.retainReceipt(settled.future);
      final sessionId = owner.store.lightSessionId;
      final reuse =
          previous != null &&
          previous['text'] == raw &&
          previous['session_id'] == sessionId &&
          (previous['first_seq']! as int) > (owner.store.archive['history_after_seq']! as int);
      if (reuse && (inheritedRetry == null || !identical(inheritedRetry.memory, owner))) {
        // A closed/used turn is not a new model-planning opportunity. Its
        // original receipts and manual task/memory entry points stay intact.
        ui.failed(_agentRetryClosed);
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
            );
      if (farewell.hasMatch(raw.trim())) followupRetired = true;
      ui.committed(raw);
      final now = DateTime.now();
      final turnContext = companionTurnContext(
        now: now,
        utcOffsetMinutes: now.timeZoneOffset.inMinutes,
        lastSpokenAt: lastSpokenAt,
        lastClockAt: lastClockAt,
        events: events,
      );
      lastSpokenAt = now;
      final persona = ref.read(companionPersonaProvider);
      final system = companionLightSystem(
        persona: companionPersona(
          custom: persona.custom,
          name: ref.read(companionNameProvider) ?? character.name,
          callMe: persona.callMe,
          tools: true,
          moves: moves.rules(),
        ),
      );
      memoryTools = CompanionAgentMemoryTools(
        memory: owner,
        source: source,
        isCurrent: current,
        onCommitted: agent.confirmControlRevision,
        forgottenNotice: ui.forgottenNotice,
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
          sessionId: ref.read(companionSessionsProvider.notifier).of(hostRef)?.sessionId,
          ensureSession: () async {
            if (!hostCurrent()) throw const DshClosedException('Companion Host changed');
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
        mapHandoff: mapHandoff,
        ui: ui.tasks(isCurrent: current),
        apiKey: agent._apiKey(),
        lightClientFactory: agent._client,
        requestId: companionMemoryId,
        host: host,
      );
      preparing = false;
      final work = agent.say(
        memory: owner,
        source: source,
        system: system,
        context: turnContext,
        tools: [...memoryTools.bindings, ...taskTools.bindings],
        isCurrent: current,
        onSelected: memoryTools.grantSelection,
      );
      final submittedRun = run = agent._run;
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
          ui.failed(_agentRetryClosed);
        } else if (memoryTools.isCurrent) {
          // No tool ran, with or without words: retrying reuses the same line.
          retryTools = memoryTools;
          memoryTools = null;
          ui.failed(error, retry: raw);
        } else {
          retrySource = null;
          ui.failed(error, retry: raw);
        }
      } else if (submittedRun.text.trim().isNotEmpty || !submittedRun.toolDispatchStarted) {
        retrySource = null;
      }
      queueExtraction();
    } on Object catch (error) {
      if (current()) ui.failed(error, retry: raw);
    } finally {
      // Fresh foreground work is handed to its original detail route only
      // after every tool/picker in this turn finishes. No active scope moves.
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
      if (current()) {
        preparing = false;
        changed();
      }
    }
  }

  void stop({bool discard = false}) {
    final pendingRetry = retryTools;
    retryTools = null;
    pendingRetry?.close();
    submission++;
    preparing = false;
    mapHandoff.close();
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
    final client = ref.read(activeConnectionProvider).value?.client;
    final directory = await root;
    if (!current()) return null;
    final CompanionKeeper? next = light
        ? (phone ??= ref.read(companionPhoneKeeperProvider)(directory))
        : client == null
        ? null
        : HostKeeper(client);
    CompanionSnapshot? value;
    if (next != null) {
      try {
        value = await next.snapshot().timeout(const Duration(seconds: 3));
      } on Object {
        // A missing keeper never prevents phone conversation.
      }
    }
    if (!current()) return null;
    if (value != null) {
      keeper = next;
      snapshot = value;
      ui.vitalsChanged(value);
    }
    return value;
  }

  Future<void> arrive({bool greet = true}) async {
    final current = captureCurrent();
    final value = await refreshKeeper();
    if (!current()) return;
    if (greet) await ui.greet(value?.vitals.lastVisitAt, current);
    if (current() && value != null) event('visit');
  }

  void event(String type) {
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
    if (entered) {
      initiative.observe(ui.initiativeRoom, view);
    } else {
      entered = true;
      initiative.enter(ui.initiativeRoom, view);
    }
    requestFollowup(view);
  }

  static bool presentable(CompanionInitiativeView view) =>
      view.visible && view.resumed && !view.blocked && view.enabled;

  void requestFollowup(CompanionInitiativeView view) {
    final owner = memory;
    if (owner == null || followupRetired || !presentable(view) || initiative.fault != null) return;
    final now = clock();
    MemoryRow? opportunity;
    try {
      opportunity = owner.store.nextFollowup(nowMs: now.wallMs);
    } on Object {
      return;
    }
    if (opportunity == null) return;
    final captured = opportunity;
    final attempt = '${view.contextKey}:${captured['id']}:${captured['row_rev']}:${captured['control_revision']}';
    if (followupAttempt == attempt) return;
    final candidate = CompanionInitiativeSignal(
      id: 'followup:${captured['id']}:${captured['row_rev']}:${captured['control_revision']}',
      contextKey: view.contextKey,
      expiresAtMonoMs: now.monoMs + math.min(120000, (captured['expires_at_ms']! as int) - now.wallMs),
    );
    bool current() =>
        active &&
        !followupRetired &&
        candidate.contextKey == ui.initiativeView.contextKey &&
        owner.store.isFollowupCurrent(captured, nowMs: clock().wallMs);
    String? line;
    initiative.requestSignal(
      ui.initiativeRoom,
      view,
      candidate,
      followupId: captured['id']! as String,
      isCurrent: current,
      prepare: () async {
        followupAttempt = attempt;
        await ref.read(companionPersonaProvider.notifier).ready;
        if (!current() || !presentable(ui.initiativeView)) return false;
        final persona = ref.read(companionPersonaProvider);
        line = await owner.followup(
          this,
          captured,
          persona: companionPersonaPart(
            custom: persona.custom,
            name: ref.read(companionNameProvider) ?? character.name,
            callMe: persona.callMe,
          ),
          offsetMinutes: clock().offsetMinutes,
          isCurrent: () {
            final now = clock();
            return current() &&
                presentable(ui.initiativeView) &&
                now.monoMs < candidate.expiresAtMonoMs &&
                companionNightKey(now.wallMs, now.offsetMinutes) == null;
          },
        );
        return line != null;
      },
      present: (display) => current() && line != null && ui.presentFollowup(display, line!),
      hide: ui.hideFollowup,
    );
  }

  void acted() {
    if (!active) return;
    followupAttempt = null;
    initiative.activate(ui.initiativeRoom);
  }

  void connectionChanged() {
    if (!active) return;
    final host = ref.read(activeHostProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    final nextLight = light;
    final differs = nextLight != boundLight || (!nextLight && (host != boundHost || !identical(client, boundClient)));
    boundHost = host;
    boundClient = client;
    boundLight = nextLight;
    if (memory case final owner?) unawaited(resumeNotes(owner));
    if (!differs) return;
    stop();
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
    ui.detached();
    closed = true;
    stop(discard: true);
    idleTimer?.cancel();
    usageTimer?.cancel();
    quietTimer?.cancel();
    for (final close in subscriptions) {
      close();
    }
    subscriptions.clear();
    memory?.removeListener(memoryChanged);
    memory?.leave(this);
    initiative.leave(ui.initiativeRoom);
    unawaited(companionMarkSeen(DateTime.now()));
    if (identical(agent._visit, this)) agent._visit = null;
  }
}
