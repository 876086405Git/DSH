// One phone-owned auxiliary request at a time. The SQLite queue outlives the
// room; this worker only runs when the room gives it an opportunity.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/companion.dart';
import 'package:http/http.dart' as http;

import 'companion_light.dart';

enum CompanionMemoryWork { idle, waiting, configuration, stale, committed, invalid }

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
  });

  final CompanionMemoryStore store;
  final CompanionMemoryTransport? Function() transport;
  final int Function() nowMilliseconds;
  final int Function(String) estimateTokens;
  Completer<void>? _cancelled;
  Completer<void>? _finished;

  bool get busy => _cancelled != null;

  /// Call on a control change or room exit. The queue is retained; a late
  /// provider answer cannot commit after this cancellation or a source edit.
  void cancel() {
    final signal = _cancelled;
    if (signal != null && !signal.isCompleted) signal.complete();
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

  Future<CompanionMemoryWork> extract({bool forceTail = false}) async {
    if (busy) return CompanionMemoryWork.idle;
    final route = transport();
    if (route == null || !route.configured) return CompanionMemoryWork.configuration;
    final batch = store.nextBatch(forceTail: forceTail, estimateTokens: estimateTokens);
    if (batch == null) return CompanionMemoryWork.idle;
    return _runBatch(
      route,
      category: 'extract',
      batchId: batch.id,
      system: companionMemoryExtractionPrompt,
      input: jsonEncode(extractionInput(batch, processedAtUtc: nowMilliseconds())),
      isCurrent: () => store.isBatchCurrent(batch),
      parse: (text) => parseExtractionProposal(text, batch),
      commit: (proposal) => store.commitExtraction(batch, proposal),
      invalid: () => store.recordInvalidProposal(batch),
      release: (reason) => store.releaseBatch(batch, reason: reason),
    );
  }

  Future<CompanionMemoryWork> consolidate() async {
    if (busy) return CompanionMemoryWork.idle;
    // This performs exact local merges even without a usable model route.
    final batch = store.nextMergeBatch(estimateTokens: estimateTokens);
    if (batch == null) return CompanionMemoryWork.idle;
    final route = transport();
    if (route == null || !route.configured) {
      store.releaseMergeBatch(batch);
      return CompanionMemoryWork.configuration;
    }
    return _runBatch(
      route,
      category: 'organize',
      batchId: batch.id,
      system: companionMemoryConsolidationPrompt,
      input: jsonEncode(consolidationInput(batch)),
      isCurrent: () => store.isMergeBatchCurrent(batch),
      parse: (text) => parseMergeProposal(text, batch),
      commit: (proposal) => store.commitMerge(batch, proposal),
      invalid: () => store.releaseMergeBatch(batch, examined: true),
      release: (_) => store.releaseMergeBatch(batch),
    );
  }

  /// Extraction and consolidation share the same physical request lifetime.
  Future<CompanionMemoryWork> _runBatch(
    CompanionMemoryTransport route, {
    required String category,
    required String batchId,
    required String system,
    required String input,
    required bool Function() isCurrent,
    required MemoryRow Function(String) parse,
    required bool Function(MemoryRow) commit,
    required void Function() invalid,
    required void Function(String) release,
  }) async {
    final requestId = store.reserveRequest(
      category: category,
      provider: route.provider,
      model: route.model,
      inputTokens: memoryBatchInputTokens,
      outputTokens: memoryBatchOutputTokens,
      batchId: batchId,
    );
    if (requestId == null) {
      release('budget');
      return CompanionMemoryWork.waiting;
    }
    final cancelled = Completer<void>();
    _cancelled = cancelled;
    final finished = _finished = Completer<void>();
    var terminal = 'local_error';
    var dispatched = false;
    var uncertain = false;
    try {
      final reply = await route.call(
        requestId: requestId,
        category: category,
        system: system,
        input: input,
        maxTokens: memoryBatchOutputTokens,
        cancelled: cancelled.future,
        onDispatchUncertain: () {
          if (cancelled.isCompleted || !isCurrent()) throw const _MemoryRequestStale();
          store.markRequestUncertain(requestId);
          uncertain = true;
        },
        onSent: () {
          if (cancelled.isCompleted || !isCurrent()) throw const _MemoryRequestStale();
          store.markRequestSent(requestId);
          dispatched = true;
        },
        onUsage: (usage) => store.recordUsage(requestId, usage),
      );
      terminal = reply.terminal;
      if (cancelled.isCompleted || !isCurrent()) {
        release('stale');
        return CompanionMemoryWork.stale;
      }
      // Network/configuration failures throw at the route. A complete provider
      // answer that was cut off by max_tokens is an invalid proposal, not an
      // empty successful extraction.
      if (!reply.complete) {
        release('network');
        return CompanionMemoryWork.waiting;
      }
      if (reply.terminal != 'complete') {
        invalid();
        return CompanionMemoryWork.invalid;
      }
      final Map<String, Object?> proposal;
      try {
        proposal = parse(reply.text);
      } on FormatException {
        invalid();
        return CompanionMemoryWork.invalid;
      }
      return commit(proposal) ? CompanionMemoryWork.committed : CompanionMemoryWork.stale;
    } on _MemoryRequestStale {
      terminal = dispatched || uncertain ? 'cancelled' : 'not_sent';
      release('stale');
      return CompanionMemoryWork.stale;
    } on CompanionAuxiliaryError catch (error) {
      terminal = error.notSent ? 'not_sent' : error.terminal;
      release(error.configuration ? 'configuration' : 'network');
      return error.configuration ? CompanionMemoryWork.configuration : CompanionMemoryWork.waiting;
    } on Object {
      release('local_error');
      rethrow;
    } finally {
      try {
        store.finishRequest(requestId, terminal: terminal);
      } finally {
        if (!cancelled.isCompleted) cancelled.complete();
        _cancelled = null;
        _finished = null;
        finished.complete();
      }
    }
  }
}

class _MemoryRequestStale implements Exception {
  const _MemoryRequestStale();
}
