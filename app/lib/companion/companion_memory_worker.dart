// One phone-owned auxiliary request at a time. The SQLite queue outlives the
// room; this worker only runs when the room gives it an opportunity.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/companion.dart';
import 'package:dsh_client/dsh_client.dart' show DshClosedException;
import 'package:http/http.dart' as http;

import 'companion_agent_loop.dart';
import 'companion_agent_tools.dart';
import 'companion_light.dart';

enum CompanionMemoryWork { idle, waiting, configuration, stale, committed, invalid }

typedef CompanionMaintenanceTools = CompanionAgentMemoryTools Function(
  MemoryRow turn,
  bool Function() isCurrent,
  CompanionAgentMaintenanceCommit onCommitted,
);

class CompanionAuxiliaryReply {
  const CompanionAuxiliaryReply({required this.text, required this.terminal, required this.complete});

  final String text;
  final String terminal;
  final bool complete;
}

class CompanionAuxiliaryError implements Exception {
  const CompanionAuxiliaryError({required this.configuration, required this.notSent, required this.terminal});

  final bool configuration;

  /// An explicit preflight failure or a host receipt proving no dispatch.
  /// A disconnected HTTP proxy cannot establish this by itself.
  final bool notSent;
  final String terminal;
}

/// A real provider route, not a chat Session. Implementations send only the
/// given system/input, with no tools or conversation history.
abstract interface class CompanionMemoryTransport {
  String get provider;
  String get model;
  bool get configured;

  Future<CompanionAuxiliaryReply> call({
    required String requestId,
    required String category,
    required String system,
    required String input,
    required int maxTokens,
    required Future<void> cancelled,
    required void Function() onDispatchUncertain,
    required void Function() onSent,
    required void Function(Map<String, Object?>) onUsage,
  });
}

class CompanionLightMemoryTransport implements CompanionMemoryTransport {
  CompanionLightMemoryTransport({required this.apiKey, http.Client Function()? client})
    : _client = client ?? http.Client.new;

  final String Function() apiKey;
  final http.Client Function() _client;

  @override
  String get provider => 'deepseek';

  @override
  String get model => companionLightModel;

  @override
  bool get configured => apiKey().trim().isNotEmpty;

  @override
  Future<CompanionAuxiliaryReply> call({
    required String requestId,
    required String category,
    required String system,
    required String input,
    required int maxTokens,
    required Future<void> cancelled,
    required void Function() onDispatchUncertain,
    required void Function() onSent,
    required void Function(Map<String, Object?>) onUsage,
  }) async {
    final client = _client();
    unawaited(cancelled.then((_) => client.close()));
    final text = StringBuffer();
    CompanionUsage? receipt;
    var sent = false;
    try {
      await for (final delta in streamCompanionReply(
        client: client,
        apiKey: apiKey(),
        system: system,
        lines: [CompanionLine.user(input)],
        maxTokens: maxTokens,
        onSent: () {
          onSent();
          sent = true;
        },
        onUsage: (usage) {
          receipt = usage;
          onUsage(usage.toJson());
        },
      )) {
        text.write(delta);
      }
      // The production stream emits a receipt for every sent request. A clean
      // end requires message_stop; truncated JSON still goes to the validator.
      return CompanionAuxiliaryReply(text: text.toString(), terminal: receipt!.terminal, complete: receipt!.complete);
    } on CompanionLightError catch (error) {
      throw CompanionAuxiliaryError(
        configuration:
            error.failure == CompanionLightFailure.noKey ||
            error.failure == CompanionLightFailure.badKey ||
            const {400, 404, 413, 422}.contains(receipt?.httpStatus),
        notSent: !sent,
        terminal: receipt?.terminal ?? 'preflight',
      );
    } finally {
      client.close();
    }
  }
}

class CompanionMemoryWorker {
  CompanionMemoryWorker({
    required this.store,
    required this.transport,
    required this.nowMilliseconds,
    required this.estimateTokens,
    this.maintenanceTools,
  });

  final CompanionMemoryStore store;
  final CompanionMemoryTransport? Function() transport;
  final int Function() nowMilliseconds;
  final int Function(String) estimateTokens;
  // The original followup-only callers need no maintenance adapter. The real
  // phone owner supplies the same memory tools used by the foreground Agent.
  final CompanionMaintenanceTools? maintenanceTools;
  Completer<void>? _cancelled;
  Completer<void>? _finished;
  CompanionAgentModelRequest? _request;
  String? _maintenanceTurn;
  int? _maintenanceControl;

  bool get busy => _cancelled != null;

  /// Call on a control change or room exit. The queue is retained; a late
  /// provider answer cannot commit after this cancellation or a source edit.
  void cancel() {
    final signal = _cancelled;
    if (signal != null && !signal.isCompleted) signal.complete();
    final request = _request;
    if (request != null) {
      request.client?.close();
      unawaited(request.drain().catchError((Object _) {}));
    }
  }

  bool acceptsControl(int revision) {
    final turn = _maintenanceTurn;
    return turn != null &&
        _cancelled?.isCompleted == false &&
        _maintenanceControl == revision &&
        store.archive['control_revision'] == revision &&
        store.isAgentTurnCurrent(turn);
  }

  Future<void> stop() {
    cancel();
    return _finished?.future ?? Future<void>.value();
  }

  /// One selected opportunity, with the same lane and usage journal as
  /// extraction. Wording exists only for this caller's captured room ticket.
  Future<String?> followup(
    MemoryRow captured, {
    required String persona,
    required int offsetMinutes,
    required bool Function() isCurrent,
  }) async {
    if (busy) {
      return null;
    }
    bool current() => isCurrent() && store.isFollowupCurrent(captured, nowMs: nowMilliseconds());
    if (!current()) {
      return null;
    }
    final route = transport();
    if (route == null || !route.configured) {
      return null;
    }
    final card = store.cards().singleWhere((row) => row['id'] == captured['card_id']);
    final sources = store.messages();
    Map<String, Object?> evidence(String id, String quote) {
      final source = sources.singleWhere((row) => row['id'] == id);
      return {
        'message_id': source['id'],
        'source_rev': source['source_rev'],
        'said_at_utc': DateTime.fromMillisecondsSinceEpoch(
          source['said_at_utc']! as int,
          isUtc: true,
        ).toIso8601String(),
        'offset_minutes': source['offset_minutes'],
        'quote': quote,
      };
    }

    final input = jsonEncode({
      'card': {'text': card['text']},
      'persona': persona,
      'invitation': evidence(captured['message_id']! as String, captured['invitation']! as String),
      'support': [
        if (captured['support_message_id'] != null)
          evidence(captured['support_message_id']! as String, captured['support_quote']! as String),
      ],
      'now_utc': DateTime.fromMillisecondsSinceEpoch(nowMilliseconds(), isUtc: true).toIso8601String(),
      'offset_minutes': offsetMinutes,
    });
    // A small complete input or silence; do not cut an original qualification
    // or persona to make it fit. These are implementation caps, not billing.
    const inputLimit = 2000;
    const outputLimit = 128;
    if (estimateTokens('$companionMemoryFollowupPrompt\n$input') > inputLimit) {
      return null;
    }
    final requestId = store.reserveRequest(
      category: 'followup',
      provider: route.provider,
      model: route.model,
      inputTokens: inputLimit,
      outputTokens: outputLimit,
      batchId: 'followup:${captured['id']}:${captured['row_rev']}',
    );
    if (requestId == null) {
      return null;
    }
    final cancelled = _cancelled = Completer<void>();
    final finished = _finished = Completer<void>();
    var terminal = 'local_error';
    var dispatched = false;
    var uncertain = false;
    try {
      final reply = await route.call(
        requestId: requestId,
        category: 'followup',
        system: companionMemoryFollowupPrompt,
        input: input,
        maxTokens: outputLimit,
        cancelled: cancelled.future,
        onDispatchUncertain: () {
          if (cancelled.isCompleted || !current()) {
            throw const _MemoryRequestStale();
          }
          store.markRequestUncertain(requestId);
          uncertain = true;
        },
        onSent: () {
          if (cancelled.isCompleted || !current()) {
            throw const _MemoryRequestStale();
          }
          store.markRequestSent(requestId);
          dispatched = true;
        },
        onUsage: (usage) => store.recordUsage(requestId, usage),
      );
      terminal = reply.terminal;
      if (cancelled.isCompleted || !current() || !reply.complete || reply.terminal != 'complete') {
        return null;
      }
      return parseFollowupProposal(reply.text);
    } on _MemoryRequestStale {
      terminal = dispatched || uncertain ? 'cancelled' : 'not_sent';
      return null;
    } on CompanionAuxiliaryError catch (error) {
      terminal = error.notSent ? 'not_sent' : error.terminal;
      return null;
    } on Object {
      // Invalid wording, a broken connection or a local failure is not a
      // displayed question. The sent/uncertain reservation is still settled.
      return null;
    } finally {
      try {
        store.finishRequest(requestId, terminal: terminal);
      } finally {
        if (!cancelled.isCompleted) {
          cancelled.complete();
        }
        _cancelled = null;
        _finished = null;
        finished.complete();
      }
    }
  }

  Future<CompanionMemoryWork> extract({bool forceTail = false, int? offsetMinutes}) => _maintain(
    kind: 'extract',
    forceTail: forceTail,
    offsetMinutes: offsetMinutes ?? DateTime.now().timeZoneOffset.inMinutes,
  );

  Future<CompanionMemoryWork> consolidate({int? offsetMinutes}) =>
      _maintain(kind: 'organize', offsetMinutes: offsetMinutes ?? DateTime.now().timeZoneOffset.inMinutes);

  /// One fixed scope of the real parent claim per opportunity. Later scopes
  /// use the same parent budget, but never inherit another role's transcript.
  Future<CompanionMemoryWork> _maintain({
    required String kind,
    required int offsetMinutes,
    bool forceTail = false,
  }) async {
    if (busy) return CompanionMemoryWork.idle;
    if (kind == 'organize' && store.mergeAgentExactDuplicates() > 0) {
      return CompanionMemoryWork.committed;
    }
    final route = transport();
    final createTools = maintenanceTools;
    // Both actual room modes inject the phone transport. A legacy Host-only
    // route remains a receipt/followup reader, not a fabricated tool Session.
    if (route is! CompanionLightMemoryTransport || !route.configured || createTools == null) {
      return CompanionMemoryWork.configuration;
    }
    // The Store selects whole original sources/cards using this very scope's
    // complete wire body, including presentation metadata and actual tools.
    // JSON escaping makes source estimates plus a fixed overhead nonadditive.
    final claim = store.nextAgentMaintenance(
      kind: kind,
      offsetMinutes: offsetMinutes,
      estimateTokens: estimateTokens,
      forceTail: forceTail,
      estimateContextTokens: (context) => _inputTokens([
        {'role': 'user', 'content': jsonEncode(_maintenanceContext(kind, context))},
      ], CompanionAgentMemoryTools.definitionsFor(originKind: kind, characterId: context['character_id'] as String?)),
    );
    if (claim == null) return CompanionMemoryWork.idle;
    final completed = (claim['completed_scopes']! as List).cast<String>().toSet();
    final scopes = (claim['scope_characters']! as List)
        .cast<String?>()
        .where((scope) => !completed.contains(scope ?? ''))
        .toList();
    if (scopes.isEmpty) return CompanionMemoryWork.idle;
    final characterId = scopes.first;
    final claimId = claim['id']! as String;
    final turn = store.beginAgentMaintenance(kind: kind, claimId: claimId, characterId: characterId);
    if (turn['closed'] != 0) return CompanionMemoryWork.stale;
    final turnId = turn['id']! as String;
    final cancelled = _cancelled = Completer<void>();
    final finished = _finished = Completer<void>();
    _maintenanceTurn = turnId;
    _maintenanceControl = turn['control_revision']! as int;
    final exchanges = <CompanionAgentExchange>[];
    bool current() =>
        identical(_cancelled, cancelled) &&
        !cancelled.isCompleted &&
        _maintenanceTurn == turnId &&
        store.isAgentTurnCurrent(turnId);
    CompanionAgentMemoryTools? tools;
    var complete = false;
    try {
      final adapter = tools = createTools(turn, current, ({
        required memory,
        required turnId,
        required beforeRevision,
        required revision,
      }) {
        if (!identical(memory.store, store) ||
            _maintenanceTurn != turnId ||
            cancelled.isCompleted ||
            _maintenanceControl != beforeRevision ||
            store.archive['control_revision'] != revision ||
            !store.isAgentTurnCurrent(turnId)) {
          return;
        }
        _maintenanceControl = revision;
        if (beforeRevision != revision) exchanges.clear();
      });
      final message = await runCompanionAgentLoop(
        tools: adapter.bindings,
        exchanges: exchanges,
        isCurrent: current,
        controlRevision: () => _maintenanceControl!,
        request: () async {
          if (!current()) return null;
          // Re-read the same live claim after every own write. In particular,
          // forget's current cutoff cannot be bypassed by the first input.
          final fresh = store.beginAgentMaintenance(kind: kind, claimId: claimId, characterId: characterId);
          if (fresh['id'] != turnId || fresh['closed'] != 0 || !current()) return null;
          final cards = (fresh['cards']! as List).cast<MemoryRow>();
          adapter.grantCards(cards);
          final messages = <Map<String, Object?>>[
            {'role': 'user', 'content': jsonEncode(_maintenanceContext(kind, fresh))},
            for (final exchange in exchanges) ...[
              {'role': 'assistant', 'content': exchange.assistant.content},
              {'role': 'user', 'content': exchange.results},
            ],
          ];
          return _maintenanceRequest(route, adapter, turnId, messages, current);
        },
      );
      if (!current()) return CompanionMemoryWork.stale;
      complete = message?.stopReason == 'end_turn';
      return complete ? CompanionMemoryWork.committed : CompanionMemoryWork.invalid;
    } on _MemoryRequestBudget {
      return CompanionMemoryWork.waiting;
    } on DshClosedException {
      return CompanionMemoryWork.stale;
    } on CompanionAuxiliaryError catch (error) {
      if (!current()) return CompanionMemoryWork.stale;
      return error.configuration ? CompanionMemoryWork.configuration : CompanionMemoryWork.waiting;
    } on CompanionLightError catch (error) {
      if (!current()) return CompanionMemoryWork.stale;
      return const [CompanionLightFailure.noKey, CompanionLightFailure.badKey].contains(error.failure)
          ? CompanionMemoryWork.configuration
          : CompanionMemoryWork.waiting;
    } finally {
      try {
        // Each physical request has drained and settled before the claim can
        // close. The adapter's later close(false) cannot reopen or undo it.
        store.finishAgentMaintenance(turnId: turnId, complete: complete);
      } finally {
        try {
          tools?.close();
        } finally {
          if (!cancelled.isCompleted) cancelled.complete();
          _maintenanceTurn = null;
          _maintenanceControl = null;
          _cancelled = null;
          _finished = null;
          finished.complete();
        }
      }
    }
  }

  Future<CompanionAgentResponse?> _maintenanceRequest(
    CompanionLightMemoryTransport route,
    CompanionAgentMemoryTools tools,
    String turnId,
    List<Map<String, Object?>> messages,
    bool Function() current,
  ) async {
    final key = route.apiKey().trim();
    if (key.isEmpty) throw const CompanionLightError(CompanionLightFailure.noKey);
    final definitions = [for (final tool in tools.bindings) tool.definition];
    final inputTokens = _inputTokens(messages, definitions);
    // The first request budgets the whole selected context. A continuation
    // sends its fresh view again, so its allowance counts the added tool
    // transcript. Compare complete wire bodies with the same current prefix;
    // do not add estimates of fragments or subtract an obsolete context.
    // The physical request still reserves its full input cost below.
    final budgetTokens = messages.length == 1 ? inputTokens : inputTokens - _inputTokens([messages.first], definitions);
    if (budgetTokens > memoryBatchInputTokens) throw const _MemoryRequestBudget();
    final id = store.reserveAgentMaintenanceRequest(
      turnId: turnId,
      provider: route.provider,
      model: route.model,
      inputTokens: inputTokens,
      outputTokens: memoryBatchOutputTokens,
    );
    if (id == null) throw const _MemoryRequestBudget();
    final request = _request = CompanionAgentModelRequest(id);
    CompanionUsage? receipt;
    try {
      final message = await request.read(
        client: route._client(),
        apiKey: key,
        system: _maintenancePrompt,
        messages: messages,
        tools: definitions,
        isCurrent: current,
        maxTokens: memoryBatchOutputTokens,
        onText: (_) {},
        onSent: () {
          if (!current()) throw const DshClosedException('Memory maintenance changed');
          store.markRequestSent(id);
          request.sent = true;
        },
        onUsage: (usage) {
          receipt = usage;
          store.recordUsage(id, usage.toJson());
          store.finishRequest(id, terminal: usage.terminal);
          request.finalized = true;
        },
      );
      return message == null ? null : (message: message, requestId: id);
    } on CompanionLightError {
      if (const {400, 404, 413, 422}.contains(receipt?.httpStatus)) {
        throw CompanionAuxiliaryError(
          configuration: true,
          notSent: !request.sent,
          terminal: receipt?.terminal ?? 'preflight',
        );
      }
      rethrow;
    } finally {
      request.client?.close();
      try {
        await request.drain();
      } finally {
        try {
          if (!request.finalized) {
            store.finishRequest(id, terminal: request.sent ? 'cancelled' : 'not_sent');
          }
        } finally {
          if (identical(_request, request)) _request = null;
          request.settled.complete();
        }
      }
    }
  }

  int _inputTokens(List<Map<String, Object?>> messages, List<CompanionAgentTool> tools) => estimateTokens(
    jsonEncode(
      companionAgentRequestBody(
        system: _maintenancePrompt,
        messages: messages,
        tools: tools,
        maxTokens: memoryBatchOutputTokens,
      ),
    ),
  );
}

Map<String, Object?> _maintenanceContext(String kind, MemoryRow turn) => {
  'type': 'memory_maintenance_context',
  'kind': kind,
  'processed_at_utc': turn['processed_at_utc'],
  'character_id': turn['character_id'],
  'local_day': turn['local_day'],
  'zone_id': turn['zone_id'],
  'source_coverage': 'selected_original_messages',
  // These are new wire maps. The full Store rows remain the source of scope,
  // revision grants and writes; database bookkeeping is not model context.
  'sources': [
    for (final source in (turn['sources']! as List).cast<MemoryRow>())
      {
        ..._maintenanceFields(source, const [
          'id',
          'source_rev',
          'first_seq',
          'event_seq',
          'role',
          'scope',
          'text',
          'said_at_utc',
          'offset_minutes',
          'edited_at_utc',
          'zone_id',
          'offset_seconds',
        ]),
        'character_id': source['character_id'],
      },
  ],
  'cards': [
    for (final card in (turn['cards']! as List).cast<MemoryRow>())
      {
        ..._maintenanceFields(card, const [
          'id',
          'row_rev',
          'kind',
          'text',
          'keywords',
          'collection',
          'scope',
          'eligible',
          'status',
          'manual',
          'pinned',
          'topic_mode',
          'source_at_ms',
          'event_time',
          'followup',
          'plan_state',
          'expires_at_ms',
          'local_day',
          'day_zone_id',
          'aliases',
        ]),
        'character_id': card['character_id'],
        'current_basis_seq': card['current_basis_seq'],
        if (card['reality_unconfirmed'] == true) 'reality_unconfirmed': true,
        // Keep every full quote and its original AND/OR group. Only the
        // repeated outer card_id is omitted from each proof row.
        'evidence': [
          for (final proof in (card['evidence']! as List).cast<MemoryRow>())
            _maintenanceFields(proof, const [
              'support_group',
              'message_id',
              'source_rev',
              'quote',
              'role',
              'scope',
              'first_seq',
              'said_at_utc',
              'offset_minutes',
              'edited_at_utc',
            ]),
        ],
      },
  ],
  'presentations': turn['presentations'],
};

MemoryRow _maintenanceFields(MemoryRow row, List<String> fields) => {
  for (final field in fields)
    if (row[field] != null) field: row[field],
};

const _maintenancePrompt = '''
You maintain the companion's phone memory using the supplied memory tools.
This is a maintenance opportunity, not a new message from the person. Never
invent a user source, a presentation, a task or an interaction. Use only the
source IDs and actual card IDs/revisions supplied in this fixed data domain.
Successful recall or related results can grant further actual IDs. For writes,
source/sources name supplied original messages; references name supplied cards
on which the wording depends. The Store binds their revisions; never invent them.
For event_time, copy first-source wording and use its original said_at_utc and
offset_minutes, never edit or processing time. Unknown local_date is null; omit
event_time when there is no evidence.
Decide meaning from the original context. Shared sources are candidates for
comparison, not proof that independent facts are the same. Read related cards
before a correction or deletion and prepare the complete effect set before
the first write. Preserve independent facts in compound cards. Merge actual
duplicates with the merge tool; do not simulate a merge with revise/forget.
At most three distinct cards may change in the entire parent opportunity,
including its other role contexts. Fewer changes, or none, are valid.
For organize, the shared completed-day diary has priority. It may use only
the supplied selected original messages; do not claim to know the whole day.
Do not copy a private role's assistant words or stories into shared records.
An impression belongs only to the captured role. Quietly lower the relevance
of old incidental matters; age alone never authorizes deletion, quiet, expiry
or rewriting them as past. Ask-later opportunities need an actual invitation.
Relationship events require a real supplied display receipt and/or original
user source. Decide whether the shown words were a question and whether the
person actually answered or confided; do not infer display from punctuation,
count ordinary chat as confiding, invent a score, or backfill settled days.
After a control change the new sources/cards replace earlier recall context.
When finished, end the turn. Your concluding prose is not saved as user chat.
''';

class _MemoryRequestBudget implements Exception {
  const _MemoryRequestBudget();
}

class _MemoryRequestStale implements Exception {
  const _MemoryRequestStale();
}
