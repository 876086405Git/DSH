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
import '../state/hosts_state.dart';
import '../state/run_pulse.dart' show estimateTokens;
import 'companion_memory_id.dart';
import 'companion_agent_task_tools.dart';
import 'companion_agent_task_ui.dart';
import 'companion_agent_tools.dart';
import 'companion_context.dart';
import 'companion_light.dart';
import 'companion_memory.dart';
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
import 'companion_state.dart';
import 'companion_widget.dart';

part 'companion_agent_visit.dart';

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
  final ({HostRef host, DshClient client})? Function()? _host;
  _CompanionAgentVisit? _visit;

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
    _visit?.close();
    final visit = _CompanionAgentVisit(this, ref, root, character, moves, ui, mapHandoff);
    _visit = visit;
    return CompanionAgentAttachment._(visit);
  }

  final http.Client Function() _client;
  final String Function() _apiKey;
  final void Function(CompanionUsage)? _onUsage;
  final void Function(Map<String, Object?>, {required bool partial})? _onUsageSettled;
  _CompanionAgentRun? _run;
  int _replies = 0;
  bool _disposed = false;

  bool get running => _run?.running ?? false;
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
    if (revision != beforeRevision) run.exchanges.clear();
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
    required List<
      ({CompanionAgentTool definition, Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute})
    >
    tools,
    required bool Function() isCurrent,
    void Function(MemorySelection)? onSelected,
  }) async {
    if (_disposed) throw const DshClosedException('Companion agent closed');
    stop();
    final run = _CompanionAgentRun(
      replyId: 'companion-${++_replies}',
      memory: memory,
      source: Map<String, Object?>.unmodifiable(source),
      system: system,
      context: context,
      tools: List.unmodifiable(tools),
      isCurrent: isCurrent,
      onSelected: onSelected,
      controlRevision: memory.store.archive['control_revision'] as int,
    );
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

  bool _current(_CompanionAgentRun run) =>
      !_disposed &&
      identical(_run, run) &&
      run.running &&
      !run.cancelled &&
      run.isCurrent() &&
      run.memory.store.archive['control_revision'] == run.controlRevision;

  Future<void> _loop(_CompanionAgentRun run) async {
    while (_current(run)) {
      final selection = run.memory.select(run.source['text'] as String);
      run.onSelected?.call(selection);
      if (!_current(run)) return;

      // Current control has already filtered the historical raw lines. The
      // active instruction is kept separately: forget can move it below the
      // history cutoff to prevent extraction from recreating a deleted card.
      final history = run.memory.store.messages(
        sessionId: run.source['session_id'] as String,
        forModel: true,
        limit: CompanionLightHistory.window + run.savedRows,
      );
      final lines = companionLightContext([
        for (final row in history)
          if ((row['first_seq'] as int) < (run.source['first_seq'] as int))
            row['role'] == 'user'
                ? CompanionLine.user(row['text'] as String)
                : CompanionLine.her(row['text'] as String),
        CompanionLine.user(run.source['text'] as String),
      ]);
      final messages = companionRequestMessages(
        [for (final line in lines) (role: line.role, text: line.text)],
        context: run.context,
        memory: selection,
      );
      for (final exchange in run.exchanges) {
        messages.add({'role': 'assistant', 'content': exchange.assistant.content});
        messages.add({'role': 'user', 'content': exchange.results});
      }

      final response = await _request(run, messages);
      if (!_current(run) || response == null) return;
      final calls = response.message.calls;
      if (response.message.stopReason != 'tool_use' || calls.isEmpty) return;

      final results = <Map<String, Object?>>[];
      for (final call in calls) {
        if (!_current(run)) return;
        // Even an unavailable/read-only call retires the no-tool retry path.
        // Record entry before lookup or an executor can synchronously commit.
        run.toolDispatchStarted = true;
        final before = run.controlRevision;
        final binding = run.tools.where((tool) => tool.definition.name == call.name).firstOrNull;
        CompanionAgentToolResult result;
        if (binding == null) {
          result = const CompanionAgentToolResult(
            content: '{"ok":false,"error":"unavailable_tool","message":"This tool is not available in this turn."}',
            isError: true,
          );
        } else {
          try {
            result = await binding.execute(call);
          } on Object {
            result = const CompanionAgentToolResult(
              content:
                  '{"ok":false,"error":"tool_failed","message":"The operation did not return a confirmed result."}',
              isError: true,
            );
          }
        }
        if (result.notice case final notice?) {
          _notice(run, response.requestId, call.id, notice);
        }
        if (!_current(run)) return;
        if (run.controlRevision != before) {
          // Keep this assistant's matching IDs while retiring any earlier
          // result body in the same batch (for example recall, then forget).
          for (final previous in results) {
            previous['content'] =
                'This earlier result was retired after memory changed. Use the current memory context.';
          }
        }
        results.add({
          'type': 'tool_result',
          'tool_use_id': call.id,
          'content': result.content,
          if (result.isError) 'is_error': true,
        });
      }
      run.exchanges.add((assistant: response.message, results: results));
    }
  }

  Future<({CompanionAgentMessage message, String requestId})?> _request(
    _CompanionAgentRun run,
    List<Map<String, Object?>> messages,
  ) async {
    final key = _apiKey().trim();
    if (key.isEmpty) throw const CompanionLightError(CompanionLightFailure.noKey);
    final definitions = [for (final tool in run.tools) tool.definition];
    final requestId = run.memory.store.reserveRequest(
      category: 'chat',
      provider: 'deepseek',
      model: companionLightModel,
      inputTokens: estimateTokens(
        jsonEncode({
          'system': run.system,
          'messages': messages,
          'tools': [for (final tool in definitions) tool.toJson()],
        }),
      ).ceil(),
      outputTokens: 800,
    )!;
    final request = _CompanionAgentRequest(requestId);
    run.request = request;
    run.memory.retainReceipt(request.settled.future);
    CompanionAgentMessage? message;
    try {
      final client = request.client = _client();
      final stream = request.stream = StreamIterator(
        streamCompanionAgentReply(
          client: client,
          apiKey: key,
          system: run.system,
          messages: messages,
          tools: definitions,
          onMessage: (value) => message = value,
          onSent: () {
            if (!_current(run)) throw const DshClosedException('Companion turn changed');
            run.memory.store.markRequestSent(requestId);
            request.sent = true;
          },
          onUsage: (usage) {
            // These identities never come from current UI/turn fields.
            run.memory.store.recordUsage(requestId, usage.toJson());
            run.memory.store.finishRequest(requestId, terminal: usage.terminal);
            request.finalized = true;
            run.memory.changed();
            if (!_disposed) _onUsage?.call(usage);
          },
          onUsageSettled: (usage, {required partial}) {
            if (!_disposed) _onUsageSettled?.call(usage, partial: partial);
          },
        ),
      );
      while (await stream.moveNext()) {
        if (!_current(run)) return null;
        final delta = stream.current;
        if (request.text.isEmpty && run.text.isNotEmpty && delta.isNotEmpty) run.text += '\n';
        request.text += delta;
        run.text += delta;
        notifyListeners();
      }
      return message == null ? null : (message: message!, requestId: requestId);
    } finally {
      request.client?.close();
      try {
        final stream = request.stream;
        if (stream != null) await (request.cancellation ??= stream.cancel());
      } finally {
        try {
          if (!request.finalized) {
            run.memory.store.finishRequest(requestId, terminal: request.sent ? 'cancelled' : 'not_sent');
          }
          _saveReply(run, request);
        } finally {
          request.settled.complete();
          if (identical(run.request, request)) run.request = null;
        }
      }
    }
  }

  void _saveReply(_CompanionAgentRun run, _CompanionAgentRequest request) {
    if (request.saved ||
        run.discard ||
        request.text.trim().isEmpty ||
        run.memory.store.archive['control_revision'] != run.controlRevision) {
      return;
    }
    _save(run, 'reply:${run.source['id']}:${request.id}', request.text);
    request.saved = true;
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
    );
    run.savedRows++;
    run.memory.changed();
  }

  void _notice(_CompanionAgentRun run, String requestId, String callId, String words) {
    if (words.trim().isEmpty || run.memory.store.archive['control_revision'] != run.controlRevision) return;
    _save(run, 'reply:${run.source['id']}:$requestId:notice:$callId', words);
    // A committed deletion keeps its acknowledgement in the original chat.
    // An old call never takes over another source's current bubble or speech.
    if (!_disposed && identical(_run, run) && !run.discard) {
      if (run.text.isNotEmpty) run.text += '\n';
      run.text += words;
      notifyListeners();
    }
  }

  /// Retire presentation immediately. Its captured request still drains to
  /// the original owner; neither a new turn nor a new window inherits it.
  void stop({bool discard = false}) {
    final run = _run;
    if (run == null || !run.running) return;
    run.cancelled = true;
    run.running = false;
    run.discard = discard;
    final request = run.request;
    if (request != null) {
      try {
        _saveReply(run, request);
      } on Object catch (error) {
        run.error = CompanionLightError(CompanionLightFailure.server, '$error');
      }
      request.client?.close();
      final stream = request.stream;
      if (stream != null) {
        // StreamIterator clears its subscription on the first cancel. A second
        // call can finish early, so both paths must await this original drain.
        request.cancellation ??= stream.cancel();
        unawaited(request.cancellation!.catchError((Object _) {}));
      }
    }
    if (discard) run.text = '';
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
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
    required this.tools,
    required this.isCurrent,
    required this.onSelected,
    required this.controlRevision,
  });

  final String replyId;
  final CompanionMemoryOwner memory;
  final MemoryRow source;
  final String system;
  final CompanionTurnContext? context;
  final List<
    ({CompanionAgentTool definition, Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute})
  >
  tools;
  final bool Function() isCurrent;
  final void Function(MemorySelection)? onSelected;
  final settled = Completer<void>();
  final exchanges = <({CompanionAgentMessage assistant, List<Map<String, Object?>> results})>[];
  int controlRevision;
  bool running = true;
  bool cancelled = false;
  bool discard = false;
  bool toolDispatchStarted = false;
  int savedRows = 0;
  String text = '';
  CompanionLightError? error;
  _CompanionAgentRequest? request;
}

class _CompanionAgentRequest {
  _CompanionAgentRequest(this.id);

  final String id;
  final settled = Completer<void>();
  http.Client? client;
  StreamIterator<String>? stream;
  Future<void>? cancellation;
  bool sent = false;
  bool finalized = false;
  bool saved = false;
  String text = '';
}
