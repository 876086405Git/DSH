part of 'companion_agent.dart';

extension on _CompanionAgentVisit {
  Future<void> sendInSession(_CompanionAgentRun run) async {
    final connection = ref.read(activeConnectionProvider).value;
    if (connection == null) throw const CompanionHostError(CompanionHostFailure.disconnected);
    final host = ref.read(activeHostProvider);
    final scope = ref.read(modelSelectionScopeProvider);
    bool routeCurrent() =>
        ref.mounted &&
        ref.read(activeHostProvider) == host &&
        identical(ref.read(activeConnectionProvider).value?.client, connection.client) &&
        identical(ref.read(modelSelectionScopeProvider), scope);
    run.modelCurrent = routeCurrent;
    bool current() => agent._current(run);
    final binding = await ref.read(companionSessionsProvider.notifier).ensure();
    if (!current()) return;
    if (binding.inlinePersona) throw const CompanionHostError(CompanionHostFailure.unavailable);
    var session = fullSession;
    if (session == null || session.id != binding.sessionId || !identical(session.client, connection.client)) {
      session?.close();
      session = fullSession = _CompanionFullSession(this, connection.client, binding.sessionId);
    }
    await session.send(run, current);
  }
}

/// Keeps the ChatController (and its unsettled request id) alive across an
/// explicit retry. A room and its resident share one follow subscription.
class _CompanionFullSession {
  _CompanionFullSession(this.visit, this.client, this.id) {
    follow = visit.ref.listen(chatProvider(id), (_, next) => observe?.call(next));
  }

  final _CompanionAgentVisit visit;
  final DshClient client;
  final String id;
  late final ProviderSubscription<ChatState> follow;
  void Function(ChatState)? observe;
  String? instance;
  String? profileFingerprint;
  int? profileRevision;
  CompanionFullContextPlan? prepared;
  MemorySelection? selectedCards;

  ChatController get chat => visit.ref.read(chatProvider(id).notifier);
  void close() => follow.close();

  Future<void> send(_CompanionAgentRun run, bool Function() current) async {
    final controller = chat;
    final provider = chatProvider(id);
    if (!await controller.waitForSync(isCurrent: current) || !current()) {
      if (current()) throw const CompanionHostError(CompanionHostFailure.disconnected);
      return;
    }
    final cap = await client.companionPromptCapability(id);
    if (!current()) return;
    if (instance != cap?.instanceId || profileRevision != cap?.profileRevision) {
      profileFingerprint = null;
      if (instance != cap?.instanceId) {
        prepared = null;
        selectedCards = null;
      }
    }
    instance = cap?.instanceId;
    final ended = Completer<void>();
    String? requestId;
    int? echoSeq;
    CompanionSessionTools? devices;
    void finish() {
      if (!ended.isCompleted) ended.complete();
    }

    void observeTurn(ChatState state) {
      final req = requestId;
      if (req == null || ended.isCompleted) return;
      if (!current()) {
        finish();
        return;
      }
      if (state.streamLost) {
        run.error = const CompanionHostError(CompanionHostFailure.disconnected);
        finish();
        return;
      }
      if (!state.controlReady) return;
      final failed = state.pending.where((p) => p.requestId == req && p.failed).firstOrNull;
      if (failed != null) {
        run.error = const CompanionHostError(CompanionHostFailure.requestFailed);
        finish();
        return;
      }
      if (echoSeq == null) {
        final echo = controller.events.whereType<UserMessageEvent>().where(
          (event) => event.isHumanPrompt && !event.message.source.raw.containsKey('principal') && event.requestId == req,
        ).firstOrNull;
        if (echo != null) {
          echoSeq = echo.seq;
          final plan = prepared;
          if (plan != null && plan.requestId == req) {
            visit.events = companionConsumeEvents(visit.events, plan.eventIds);
            visit.lastClockAt = run.context?.sampledAt;
          }
        }
      }
      if (echoSeq == null) return;
      final trace = state.turns.reversed.where(
        (t) => t.startSeq <= echoSeq! && (t.endSeq == null || echoSeq! <= t.endSeq!),
      ).firstOrNull;
      if (trace == null) return;
      if (trace.spans.any((s) => s.kind == TraceKind.tool)) run.toolDispatchStarted = true;
      if (trace.endSeq != null) {
        final failure = trace.endReason?.error;
        if (failure != null) run.error = CompanionHostError(companionHostFailure(failure.code), failure.message);
        finish();
      }
    }

    final listener = observeTurn;
    observe = listener;
    final endInteraction = controller.beginInteraction(current);
    var handedOff = false;
    void Function()? clearStop;
    run.stopSession = (cancelHost) {
      if (cancelHost && handedOff && requestId != null && visit.ref.mounted &&
          identical(visit.ref.read(activeConnectionProvider).value?.client, client)) {
        clearStop = controller.stopPrompt(requestId!);
      }
      devices?.close();
      finish();
    };
    try {
      final accepted = await controller.send(
        run.source['text']! as String,
        verbatim: true,
        mode: SendMode.interrupt,
        deliveryAllowed: () {
          handedOff = current();
          return handedOff;
        },
        beforeDeliver: (req) async {
          if (!current()) return false;
          requestId = req;
          if (cap != null) await prepare(run, cap, req, current);
          if (!current()) return false;
          devices = await CompanionSessionTools.open(
            client,
            sessionId: id,
            requestId: req,
            tools: [
              for (final binding in visit.agent._bindings(run))
                (
                  definition: binding.definition,
                  execute: (call) {
                    run.toolDispatchStarted = true;
                    return binding.execute(call);
                  },
                ),
            ],
            local: visit.boundHost == HostRef.local,
            stopPhone: run.onStop,
            isCurrent: current,
          );
          return current();
        },
      );
      if (!accepted && requestId != null && !controller.awaitingPromptOutcome(requestId!)) clearStop?.call();
      if (!current()) return;
      if (!accepted) throw CompanionHostError(CompanionHostFailure.requestFailed, visit.ref.read(provider).error);
      observeTurn(visit.ref.read(provider));
      await ended.future;
    } finally {
      if (identical(observe, listener)) observe = null;
      endInteraction();
      run.stopSession = null;
      devices?.close();
    }
  }

  Future<void> prepare(
    _CompanionAgentRun run,
    CompanionPromptCapability cap,
    String req,
    bool Function() current,
  ) async {
    if (prepared?.requestId != req) {
      final persona = visit.ref.read(companionPersonaProvider);
      final name = visit.ref.read(companionNameProvider) ?? visit.character.name;
      final whale = companionIsWhale(visit.characterSourceKey, visit.character.name);
      final profile = CompanionContextProfile(
        persona: persona.custom.trim().isNotEmpty || !whale
            ? companionPersonaPart(custom: persona.custom, name: name, whale: whale)
            : '',
        name: name ?? '',
        callMe: persona.callMe,
        moves: visit.moves.rules(),
      );
      MemorySelection? cards;
      if (cap.phoneMemory && cap.phoneMemoryVersion >= 3 && cap.memoryMode != 'automatic') {
        cards = await run.memory.selectForAgent(
          run.source['text']! as String,
          characterId: run.source['character_id'] as String?,
          offsetMinutes: run.source['offset_minutes']! as int,
          explicitUserInput: run.source['text']! as String,
          isCurrent: current,
        );
        if (!current()) return;
        if (companionSelectionHasNotice(cards)) {
          // A saved notification is usable in the private phone workflow. Its
          // third-party summary is not part of the durable DSH conversation.
          final block = jsonDecode(cards.block) as Map<String, Object?>;
          final items = (block['items']! as List).cast<Map<String, Object?>>().where(
            (row) => (row['source'] as Map?)?['kind'] != 'notice',
          ).toList();
          cards = MemorySelection(
            block: jsonEncode({...block, 'items': items}),
            ids: [for (final item in items) item['id']! as String],
            controlRevision: cards.controlRevision,
          );
        }
      }
      final ctx = run.context!.data;
      prepared = companionFullContextPlan(
        sessionId: id,
        requestId: req,
        text: run.source['text']! as String,
        profile: profile,
        supported: true,
        instanceId: cap.instanceId,
        profileRevision: cap.profileRevision,
        acknowledgedProfile: profileFingerprint,
        now: run.context!.sampledAt,
        events: visit.events.where((e) => run.context!.eventIds.contains(e.id)),
        // Migrated phone authority must never re-enable old JSON memories.
        recall: false,
        memoryMode: cards == null ? 'query' : 'phone',
        phoneMemory: cards == null ? null : run.memory.phoneContext(cards),
        deviceContext: cap.phoneMemoryVersion >= 3 ? {
          'window': ctx['window'],
          'localTime': ctx['localTime'],
          if (ctx.containsKey('zoneId')) 'zoneId': ctx['zoneId'],
          if (ctx.containsKey('originalMessage')) 'originalMessage': ctx['originalMessage'],
        } : null,
      );
      selectedCards = cards;
    }
    final update = prepared!.update;
    if (update != null) {
      final ack = await client.prepareCompanionPromptContext(update);
      if (!current()) return;
      profileRevision = ack.profileRevision;
      if (update['profile'] is Map && ack.profileAccepted == true) {
        profileFingerprint = jsonEncode(update['profile']);
      }
    }
    if (selectedCards case final cards?) {
      run.onSelected?.call(cards);
    }
  }
}
