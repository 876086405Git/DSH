// The phone owns the model/tool loop. A window subscribes to its words; tool
// adapters retain their original store, task and foreground contracts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../notify/chat_alerts.dart' show companionHostKey;
import '../state/connection_state.dart';
import '../state/android_features.dart';
import '../state/hosts_state.dart';
import '../state/models_state.dart';
import '../state/read_list_identity.dart';
import '../state/run_pulse.dart' show estimateTokens;
import '../state/settings_state.dart';
import 'companion_agent_loop.dart';
import 'companion_agent_phone_tools.dart';
import 'companion_agent_photo_tools.dart';
import 'companion_memory_id.dart';
import 'companion_agent_task_tools.dart';
import 'companion_agent_task_ui.dart';
import 'companion_agent_tools.dart';
import 'companion_context.dart';
import 'companion_host_memory_transport.dart';
import 'companion_light.dart';
import 'companion_memory.dart';
import 'companion_notice_triage.dart';
import 'companion_memory_worker.dart';
import 'companion_keeper.dart';
import 'companion_initiative.dart';
import 'companion_initiative_owner.dart';
import 'companion_maps.dart';
import 'companion_moves.dart';
import 'companion_pack.dart';
import 'companion_public_lookup.dart';
import 'companion_recall_prefs.dart';
import 'companion_reminder.dart';
import 'companion_reply.dart';
import 'companion_resident_signals.dart';
import 'companion_signals.dart';
import 'companion_state.dart';
import 'companion_widget.dart';

part 'companion_agent_visit.dart';
part 'companion_agent_resident.dart';
part 'companion_agent_notices.dart';
part 'companion_agent_screen_classifier.dart';

/// One phone loop in either room mode. The caller supplies the tool bindings
/// once per original user source, including any genuine foreground capability.
class CompanionAgent extends ChangeNotifier {
  /// Lets the agent's own helpers (visit, tools) announce a change.
  void changed() => notifyListeners();

  CompanionAgent({
    required this._client,
    required this._apiKey,
    this._onUsage,
    this._onUsageSettled,
    this._ref,
    this._memoryTransport,
    this._host,
  });

  final Ref? _ref;
  final CompanionMemoryTransport Function()? _memoryTransport;
  final ({HostRef host, DshClient? client})? Function()? _host;
  _CompanionAgentVisit? _visit;
  final _noticePending = <_PendingNotice>[];
  String? get noticeFailure => _visit?.notices?.failure;

  /// The Page keeps this particular attachment. Old window actions never
  /// resolve through a later current visit on this process owner.
  CompanionAgentAttachment attach({
    required Future<Directory> root,
    required CompanionCharacter character,
    required CompanionMoves moves,
    required CompanionAgentRoomUi ui,
    required CompanionMapHandoff mapHandoff,
  }) {
    final ref = _ref;
    if (_disposed || ref == null || _memoryTransport == null || _host == null) {
      throw const DshClosedException('Companion room owner is not available');
    }
    final retained = _visit;
    if (retained != null && retained.residentUi != null && !retained.closed) {
      return retained.attachWindow(ui, mapHandoff);
    }
    retained?.close();
    final visit = _CompanionAgentVisit(this, ref, root, character, moves);
    _visit = visit;
    return visit.attachWindow(ui, mapHandoff);
  }

  /// The foreground service retains this lease; a Page owns a separate window
  /// handle. Both use the same visit, database and model/tool loop.
  CompanionAgentResident retainAlwaysOn({
    required Future<Directory> root,
    required CompanionCharacter character,
    required CompanionMoves moves,
    required String? sourceKey,
    required CompanionAgentRoomUi ui,
    required CompanionMapHandoff mapHandoff,
  }) {
    final ref = _ref;
    if (_disposed || ref == null || _memoryTransport == null || _host == null) {
      throw const DshClosedException('Companion owner is not available');
    }
    final visit = _visit ??= _CompanionAgentVisit(this, ref, root, character, moves);
    if (visit.residentUi != null) throw const DshClosedException('Companion resident already retained');
    visit.residentUi = ui;
    visit.residentMapHandoff = mapHandoff;
    if (visit.window == null) visit.updateCharacter(character, moves, sourceKey);
    return CompanionAgentResident._(visit, ui);
  }

  DateTime? get lastUserInteractionAt => _visit?.lastUserInteractionAt;
  int? get lastUserInteractionAtMs => lastUserInteractionAt?.millisecondsSinceEpoch;
  void Function(String)? onScreenUserText;
  void Function(String requestId, int atMs, double? estimatedCny)? onScreenCost;
  void Function()? onScreenRouteChanged;

  final http.Client Function() _client;
  final String Function() _apiKey;
  final void Function(CompanionUsage)? _onUsage;
  final void Function(Map<String, Object?>, {required bool partial})? _onUsageSettled;
  _CompanionAgentRun? _run;
  CompanionAgentModelRequest? _asideRequest;
  DshHttpAbort? _asideAbort;
  int _asideGeneration = 0;
  int _replies = 0;
  bool _disposed = false;

  bool get running => (_run?.running ?? false) || _asideRequest != null;
  String get text => _run?.text ?? '';
  CompanionLightError? get error => _run?.error;

  /// The original SQLite user source, not the tools' separate journal turn ID.
  String? get sourceId => _run?.source['id'] as String?;

  /// A retry gets fresh subtitle/speech progress; this is not a tool identity.
  String? get replyId => _run?.replyId;
  int? get controlRevision => _run?.controlRevision;

  bool acceptsControl(CompanionMemoryOwner memory, int revision) {
    final run = _run;
    return run != null &&
        run.running &&
        !run.cancelled &&
        identical(run.memory, memory) &&
        run.controlRevision == revision;
  }

  /// Called synchronously after an own tool transaction and before changed().
  /// Its before revision belongs to this run; a late call cannot acknowledge an
  /// intervening external control or a retry's newer store revision.
  void confirmControlRevision({
    required CompanionMemoryOwner memory,
    required String sourceId,
    required int beforeRevision,
    required int revision,
  }) {
    final run = _run;
    if (run == null ||
        !run.running ||
        run.cancelled ||
        !identical(run.memory, memory) ||
        run.source['id'] != sourceId ||
        run.controlRevision != beforeRevision ||
        memory.store.archive['control_revision'] != revision) {
      return;
    }
    // The actual returning tool decides whether this own change revoked text.
    // Merely adding a fact must not discard an earlier lookup report.
    run.controlRevision = revision;
  }

  /// The source has already been committed by the actual send transaction.
  /// This future drains the logical turn; each physical model request retains
  /// and settles its own receipt even after another source becomes current.
  Future<void> say({
    required CompanionMemoryOwner memory,
    required MemoryRow source,
    required String system,
    CompanionTurnContext? context,
    String? assistantPage,
    required List<
      ({CompanionAgentTool definition, Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute})
    >
    tools,
    required bool Function() isCurrent,
    void Function(MemorySelection)? onSelected,
    void Function()? onStop,
  }) async {
    if (_disposed) throw const DshClosedException('Companion agent closed');
    stop();
    if (source['role'] == 'user') onScreenUserText?.call(source['text']! as String);
    final run = _CompanionAgentRun(
      replyId: 'companion-${++_replies}',
      memory: memory,
      source: Map<String, Object?>.unmodifiable(source),
      system: system,
      context: context,
      assistantPage: assistantPage,
      tools: List.unmodifiable(tools),
      isCurrent: isCurrent,
      onSelected: onSelected,
      onStop: onStop,
      controlRevision: memory.store.archive['control_revision'] as int,
    )..externalWebContent = assistantPage != null;
    if (context?.data['noticeReply'] != null) _markNoticeContent(run);
    _run = run;
    memory.retainReceipt(run.settled.future);
    notifyListeners();
    try {
      await _loop(run);
    } on Object catch (error) {
      if (_current(run)) {
        run.error = error is CompanionLightError ? error : CompanionLightError(CompanionLightFailure.server, '$error');
      }
    } finally {
      run.running = false;
      if (!_disposed && identical(_run, run)) notifyListeners();
      run.settled.complete();
    }
  }

  // A reply keeps the permission generation in which it first received
  // notice content, including when that content came from a memory tool.
  void _markNoticeContent(_CompanionAgentRun run) {
    if (run.externalNoticeContent) return;
    run.externalNoticeContent = true;
    run.noticeDeliveryEpoch = _visit?.notices?.readableEpoch;
  }

  bool _current(_CompanionAgentRun run) => _turnCurrent(run) && (run.modelCurrent?.call() ?? true);

  bool _turnCurrent(_CompanionAgentRun run) =>
      !_disposed &&
      identical(_run, run) &&
      run.running &&
      !run.cancelled &&
      run.isCurrent() &&
      run.memory.store.archive['control_revision'] == run.controlRevision;

  /// Resolve before reserving a physical request. The Session supplies only
  /// the selected model; this stateless route never reads its old transcript
  /// or starts its AgentLoop. Every round uses the phone's current context.
  Future<CompanionMemoryTransport?> _modelTransport({
    required bool Function() isCurrent,
    bool forMemory = false,
  }) async {
    if (!isCurrent()) throw const DshClosedException('Companion turn changed');
    final ref = _ref;
    if (ref == null) {
      final route = _memoryTransport?.call();
      if (forMemory || route is CompanionHostMemoryTransport) {
        return route ?? CompanionLightMemoryTransport(apiKey: _apiKey, client: _client);
      }
      return CompanionLightMemoryTransport(apiKey: _apiKey, client: _client);
    }
    final mode = ref.read(companionModeProvider);
    final connection = ref.read(activeConnectionProvider).value;
    if (mode == CompanionMode.light || (mode == null && connection == null)) {
      // The existing background route may deliberately be unconfigured while
      // chat has its own valid key/client. Keep those Light contracts separate.
      return forMemory
          ? _memoryTransport?.call() ?? CompanionLightMemoryTransport(apiKey: _apiKey, client: _client)
          : CompanionLightMemoryTransport(apiKey: _apiKey, client: _client);
    }
    // Full keeps its source and tools when only this model round uses the phone.
    final phone = CompanionLightMemoryTransport(apiKey: _apiKey, client: _client);
    if (connection == null) {
      if (phone.configured) return phone;
      throw const CompanionHostError(CompanionHostFailure.disconnected);
    }
    final host = ref.read(activeHostProvider);
    final client = connection.client;
    final scope = ref.read(modelSelectionScopeProvider);
    bool current() =>
        !_disposed &&
        ref.mounted &&
        isCurrent() &&
        ref.read(companionModeProvider) == mode &&
        ref.read(activeHostProvider) == host &&
        identical(ref.read(activeConnectionProvider).value?.client, client) &&
        identical(ref.read(modelSelectionScopeProvider), scope);
    CompanionMemoryTransport phoneOrFail(CompanionHostError error) {
      if (!current()) throw const DshClosedException('Companion Host route changed');
      if (phone.configured) return phone;
      throw error;
    }

    try {
      // Resolve the current full Session each round. A phone tool may retire
      // its previous binding without cancelling this same logical turn.
      final selected = await ref.read(companionSessionsProvider.notifier).ensure();
      if (!current()) throw const DshClosedException('Companion Host route changed');
      final capability = await client.readCompanionAuxiliaryCapability(selected.sessionId);
      if (capability == null || !capability.supported) {
        return phoneOrFail(const CompanionHostError(CompanionHostFailure.unavailable));
      }
      if (!current()) throw const DshClosedException('Companion Host route changed');
      if (!capability.agentSupported && phone.configured) return phone;
      // Without a phone key, legacy auxiliary can still serve no-tool followup.
      return CompanionHostMemoryTransport(client: client, capability: capability, isCurrent: current);
    } on CompanionAuxiliaryFailure catch (error) {
      return phoneOrFail(CompanionHostError(companionHostFailure(error.code), error.code));
    } on DshClosedException {
      return phoneOrFail(const CompanionHostError(CompanionHostFailure.disconnected));
    } on DshException catch (error) {
      return phoneOrFail(CompanionHostError(CompanionHostFailure.unavailable, '$error'));
    }
  }

  // Only the explicitly allowed additive/read paths remain after web data.
  // These names are the current memory adapter's mutators, not task commands.
  static const _afterWebMemoryChanges = {
    'forget',
    'revise',
    'quiet',
    'cancel',
    'postpone',
    'merge',
    'person',
    'diary',
    'impression',
    'relationship',
  };

  bool _toolAvailable(_CompanionAgentRun run, CompanionAgentToolCall call) =>
      !run.externalWebContent ||
      (!_afterWebMemoryChanges.contains(call.name) && !(call.name == 'remember' && call.input['card'] != null));

  List<CompanionAgentTool> _definitions(_CompanionAgentRun run) => [
    for (final tool in run.tools)
      if ((!run.externalNoticeContent || CompanionAgentMemoryTools.allowedAfterNotice(tool.definition.name)) &&
          (!run.externalWebContent || !_afterWebMemoryChanges.contains(tool.definition.name)))
        if (run.externalNoticeContent && tool.definition.name == 'forget')
          CompanionAgentMemoryTools.noticeForget
        else if ((run.externalWebContent || run.externalNoticeContent) && tool.definition.name == 'remember')
          CompanionAgentTool(
            name: tool.definition.name,
            description: tool.definition.description,
            inputSchema: {
              ...tool.definition.inputSchema,
              'properties': {
                for (final entry in (tool.definition.inputSchema['properties']! as Map).entries)
                  if (entry.key != 'card') (entry.key as String): entry.value,
              },
            },
          )
        else
          tool.definition,
  ];

  Future<void> _loop(_CompanionAgentRun run) async {
    await runCompanionAgentLoop(
      tools: [
        for (final binding in run.tools)
          (
            definition: binding.definition,
            execute: (call) async {
              // The execution gate is checked for every call, including a
              // later call in the same already-decoded model response.
              if (run.externalNoticeContent &&
                  (!CompanionAgentMemoryTools.allowedAfterNotice(call.name) ||
                      (call.name == 'forget' && !CompanionAgentMemoryTools.pureDeletion(call.input)) ||
                      (call.name == 'remember' && call.input['card'] != null))) {
                return const CompanionAgentToolResult(
                  content: '{"applied":false,"code":"memory_change_after_notice","message":"This turn includes a recent event from an external notification. New memories are fine; existing ones cannot be rewritten until the next message."}',
                  isError: true,
                );
              }
              if (!_toolAvailable(run, call)) {
                return const CompanionAgentToolResult(
                  content: '{"applied":false,"code":"memory_change_after_web","message":"This memory change is unavailable for the rest of this turn after public web content. It was not applied."}',
                  isError: true,
                );
              }
              if (call.name == 'public_lookup') run.externalWebContent = true;
              final result = await binding.execute(call);
              if (result.externalWebContent) run.externalWebContent = true;
              if (result.externalNoticeContent) _markNoticeContent(run);
              return result;
            },
          ),
      ],
      retainToolOutcomes: true,
      exchanges: run.exchanges,
      isCurrent: () => _current(run),
      controlRevision: () => run.controlRevision,
      onToolDispatch: () => run.toolDispatchStarted = true,
      onNotice: (requestId, callId, words) => _notice(run, requestId, callId, words),
      request: () async {
        final selection = await run.memory.selectForAgent(
          run.source['text'] as String,
          explicitUserInput: run.source['text'] as String,
          characterId: run.source['character_id'] as String?,
          offsetMinutes: run.source['offset_minutes']! as int,
          isCurrent: () => _current(run),
        );
        if (!_current(run)) return null;
        if (companionSelectionHasNotice(selection)) _markNoticeContent(run);
        run.onSelected?.call(selection);

        // Current control has already filtered the historical raw lines. The
        // active instruction is kept separately: forget can move it below the
        // history cutoff to prevent extraction from recreating a deleted card.
        final history = run.memory.store.modelMessages(
          sessionId: run.source['session_id'] as String,
          characterId: run.source['character_id'] as String?,
          limit: CompanionLightHistory.window + run.savedRows,
        );
        final oldLines = [
          for (final row in history)
            if ((row['first_seq'] as int) < (run.source['first_seq'] as int))
              row['role'] == 'user'
                  ? CompanionLine.user(row['text'] as String)
                  : CompanionLine.her(row['text'] as String),
        ];
        List<Map<String, Object?>> messagesFrom(int skip) {
          final lines = companionLightContext([
            ...oldLines.skip(skip),
            CompanionLine.user(run.source['text'] as String),
          ]);
          final messages = companionRequestMessages(
            [for (final line in lines) (role: line.role, text: line.text)],
            context: run.context,
            memory: selection,
            assistantPage: run.assistantPage,
          );
          for (final exchange in run.exchanges) {
            messages.add(exchange.assistant.toRequest());
            messages.add({'role': 'user', 'content': exchange.results});
          }
          return messages;
        }

        return _request(run, messagesFrom, oldLines.length);
      },
    );
  }

  Future<({CompanionAgentMessage message, String requestId})?> _request(
    _CompanionAgentRun run,
    List<Map<String, Object?>> Function(int skip) messagesFrom,
    int historyCount,
  ) async {
    final selected = await _modelTransport(isCurrent: () => _turnCurrent(run));
    if (!_current(run)) return null;
    if (selected is! CompanionAgentModelTransport) {
      throw const CompanionHostError(CompanionHostFailure.unavailable);
    }
    if (!selected.agentConfigured) {
      if (selected is CompanionLightMemoryTransport) throw const CompanionLightError(CompanionLightFailure.noKey);
      throw const CompanionHostError(CompanionHostFailure.unavailable);
    }
    // A phone fallback still belongs to this captured Host selection and turn.
    run.modelCurrent = () => selected.current;
    if (!_current(run)) return null;
    final system = '${run.system}${run.memory.relationshipContext(run.source['character_id'] as String?)}';
    final definitions = _definitions(run);
    final toolJson = [for (final tool in definitions) tool.toJson()];
    CompanionAgentModelTransport route = selected;
    while (true) {
      if (!_current(run)) return null;
      var messages = messagesFrom(0);
      final requestId = run.memory.store.reserveRequest(
        category: 'chat',
        provider: route.provider,
        model: route.model,
        inputTokens: estimateTokens(
          jsonEncode({'system': system, 'messages': messages, 'tools': toolJson}),
        ).ceil(),
        outputTokens: 800,
      )!;
      final request = _CompanionAgentRequest(requestId);
      run.request = request;
      run.memory.retainReceipt(request.settled.future);
      final priorText = run.text;
      CompanionLightMemoryTransport? fallback;
      try {
        if (route is CompanionHostMemoryTransport) {
          var skipped = 0;
          while (companionAgentRequestBytes(
                route.capability,
                requestId: requestId,
                system: system,
                messages: messages,
                tools: toolJson,
                maxTokens: 800,
              ) > companionAgentRequestMaxBytes &&
              skipped < historyCount) {
            // Rebuild from raw old lines: adjacent users may have been merged
            // with the current input. Current data and exchanges stay intact.
            messages = messagesFrom(++skipped);
          }
        }
        final message = await route.readAgent(
          request: request,
          system: system,
          messages: messages,
          tools: definitions,
          isCurrent: () => route is CompanionHostMemoryTransport ? _turnCurrent(run) : _current(run),
          onText: (delta) {
            if (request.text.isEmpty && run.text.isNotEmpty && delta.isNotEmpty) run.text += '\n';
            request.text += delta;
            run.text += delta;
            notifyListeners();
          },
          onDispatchUncertain: () {
            if (!_current(run)) throw const DshClosedException('Companion turn changed');
            run.memory.store.markRequestUncertain(requestId);
            request.uncertain = true;
          },
          onSent: () {
            // Host callbacks report an observed dispatch, even after this turn
            // retires. Light checks its permission before sending instead.
            run.memory.store.markRequestSent(requestId);
            request.sent = true;
          },
          onUsage: (usage) {
            // These identities never come from current UI/turn fields.
            run.memory.store.recordUsage(requestId, usage);
            run.memory.store.finishRequest(requestId, terminal: usage['terminal']! as String);
            request.finalized = true;
            run.memory.changed();
            if (!_disposed) _onUsage?.call(CompanionUsage.fromReceipt(usage));
          },
          onUsageSettled: (usage, {required partial}) {
            if (!_disposed) _onUsageSettled?.call(usage, partial: partial);
          },
        );
        if (message != null && route is CompanionHostMemoryTransport && _current(run)) {
          // Some adapters emit complete block text only at block-end. Keep the
          // real deltas live, then seal this request with the validated message.
          request.text = message.text;
          run.text = [if (priorText.isNotEmpty) priorText, if (request.text.isNotEmpty) request.text].join('\n');
          notifyListeners();
        }
        return message == null ? null : (message: message, requestId: requestId);
      } on CompanionHostError {
        final phone = CompanionLightMemoryTransport(apiKey: _apiKey, client: _client);
        if (route is! CompanionHostMemoryTransport ||
            !request.notSentProven ||
            request.sent ||
            !_current(run) ||
            !phone.configured) {
          rethrow;
        }
        fallback = phone;
      } finally {
        request.client?.close();
        try {
          await request.drain();
        } finally {
          try {
            if (request.notSentProven && !request.sent) {
              run.memory.store.finishRequest(requestId, terminal: 'not_sent');
            } else if (!request.finalized) {
              run.memory.store.finishRequest(requestId, terminal: request.sent || request.uncertain ? 'cancelled' : 'not_sent');
            }
            _saveReply(run, request);
          } finally {
            request.settled.complete();
            if (identical(run.request, request)) run.request = null;
          }
        }
      }
      // Drain and settle the Host attempt before reserving a separate phone
      // request. A thrown finalizer or a retired selection cannot start it.
      if (!_current(run)) return null;
      route = fallback;
    }
  }

  void _saveReply(_CompanionAgentRun run, _CompanionAgentRequest request) {
    if (request.saved ||
        run.externalNoticeContent ||
        run.discard ||
        request.text.trim().isEmpty ||
        run.memory.store.archive['control_revision'] != run.controlRevision) {
      return;
    }
    final id = 'reply:${run.source['id']}:${request.id}';
    _save(run, id, request.text);
    request.saved = true;
    run.unpresentedReplies[id] = (start: run.text.length - request.text.length, end: run.text.length);
  }

  void _save(_CompanionAgentRun run, String id, String words) {
    final now = DateTime.now();
    run.memory.store.submitMessage(
      id: id,
      sessionId: run.source['session_id'] as String,
      role: 'assistant',
      text: words,
      saidAtUtc: now.toUtc().millisecondsSinceEpoch,
      offsetMinutes: now.timeZoneOffset.inMinutes,
      characterId: run.source['character_id'] as String?,
    );
    run.savedRows++;
    run.memory.changed();
  }

  void _notice(_CompanionAgentRun run, String requestId, String callId, String words) {
    if (words.trim().isEmpty || run.memory.store.archive['control_revision'] != run.controlRevision) return;
    final id = 'reply:${run.source['id']}:$requestId:notice:$callId';
    if (!run.externalNoticeContent) _save(run, id, words);
    // A committed deletion keeps its acknowledgement in the original chat.
    // An old call never takes over another source's current bubble or speech.
    if (!_disposed && identical(_run, run) && !run.discard) {
      if (run.text.isNotEmpty) run.text += '\n';
      run.text += words;
      if (!run.externalNoticeContent) {
        run.unpresentedReplies[id] = (start: run.text.length - words.length, end: run.text.length);
      }
      notifyListeners();
    }
  }

  /// Retire presentation immediately. Its captured request still drains to
  /// the original owner; neither a new turn nor a new window inherits it.
  void cancelScreenObservation() {
    _asideGeneration++;
    _asideAbort?.abort();
    final aside = _asideRequest;
    if (aside != null) {
      aside.client?.close();
      unawaited(aside.drain().catchError((Object _) {}));
    }
  }

  void screenRouteChanged() {
    cancelScreenObservation();
    onScreenRouteChanged?.call();
  }

  void modelRouteChanged() {
    screenRouteChanged();
    _visit?.connectionChanged(generationChanged: true);
  }

  void stop({bool discard = false}) {
    cancelScreenObservation();
    if (_visit?.residentUi case final CompanionAgentAmbientUi background) background.stopSpeech();
    final run = _run;
    if (run == null || !run.running) return;
    run.onStop?.call();
    run.cancelled = true;
    run.running = false;
    run.discard = discard;
    // A photo she is looking at for this turn is a request of its own.
    for (final abort in run.aborts.toList()) {
      abort.abort();
    }
    final request = run.request;
    if (request != null) {
      try {
        _saveReply(run, request);
      } on Object catch (error) {
        run.error = CompanionLightError(CompanionLightFailure.server, '$error');
      }
      request.client?.close();
      // Both transports retain the first drain. Host cancellation waits for
      // its SDK receipt/finally just as Light waits for iterator cancellation.
      unawaited(request.drain().catchError((Object _) {}));
    }
    if (discard) run.text = '';
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _noticePending.clear();
    _visit?.close();
    _disposed = true;
    stop(discard: true);
    super.dispose();
  }
}

class _CompanionAgentRun {
  _CompanionAgentRun({
    required this.replyId,
    required this.memory,
    required this.source,
    required this.system,
    required this.context,
    required this.assistantPage,
    required this.tools,
    required this.isCurrent,
    required this.onSelected,
    required this.onStop,
    required this.controlRevision,
  });

  final String replyId;
  final void Function()? onStop;
  final CompanionMemoryOwner memory;
  final MemoryRow source;
  final String system;
  final CompanionTurnContext? context;
  final String? assistantPage;
  final List<
    ({CompanionAgentTool definition, Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute})
  >
  tools;
  final bool Function() isCurrent;
  bool Function()? modelCurrent;
  final void Function(MemorySelection)? onSelected;
  final settled = Completer<void>();
  final exchanges = <CompanionAgentExchange>[];
  // Only real Page frame acknowledgements turn these saved assistant sources
  // into presentation facts. A saved reply alone is not a shown question.
  // UTF-16 ranges in this same run.text, before the Page removes stage marks.
  final unpresentedReplies = <String, ({int start, int end})>{};
  int controlRevision;
  bool running = true;
  bool cancelled = false;
  bool discard = false;
  bool toolDispatchStarted = false;
  // This capability narrowing belongs only to this original user run.
  bool externalWebContent = false;
  // Monotonic for this logical user turn, including later HTTP continuations.
  bool externalNoticeContent = false;
  int? noticeDeliveryEpoch;
  int savedRows = 0;
  // Tool-side model requests (a photo look) that Stop must abort with the turn.
  final aborts = <DshHttpAbort>{};
  String text = '';
  CompanionLightError? error;
  _CompanionAgentRequest? request;
}

class _CompanionAgentRequest extends CompanionAgentModelRequest {
  _CompanionAgentRequest(super.id);

  bool saved = false;
}
