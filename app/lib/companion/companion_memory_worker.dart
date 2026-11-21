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
  CompanionLightMemoryTransport({required this.apiKey, http.Client Function()? client}) : _client = client ?? http.Client.new;

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
        configuration: error.failure == CompanionLightFailure.noKey || error.failure == CompanionLightFailure.badKey ||
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
  final CompanionMemoryTransport Function() transport;
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

  Future<CompanionMemoryWork> extract({bool forceTail = false}) async {
    if (busy) return CompanionMemoryWork.idle;
    final route = transport();
    if (!route.configured) return CompanionMemoryWork.configuration;
    final batch = store.nextBatch(forceTail: forceTail, estimateTokens: estimateTokens);
    if (batch == null) return CompanionMemoryWork.idle;
    final requestId = store.reserveRequest(
      category: 'extract',
      provider: route.provider,
      model: route.model,
      inputTokens: memoryBatchInputTokens,
      outputTokens: memoryBatchOutputTokens,
      batchId: batch.id,
    );
    if (requestId == null) {
      store.releaseBatch(batch, reason: 'budget');
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
        category: 'extract',
        system: companionMemoryExtractionPrompt,
        input: jsonEncode(extractionInput(batch, processedAtUtc: nowMilliseconds())),
        maxTokens: memoryBatchOutputTokens,
        cancelled: cancelled.future,
        onDispatchUncertain: () {
          if (cancelled.isCompleted || !store.isBatchCurrent(batch)) throw const _MemoryRequestStale();
          store.markRequestUncertain(requestId);
          uncertain = true;
        },
        onSent: () {
          if (cancelled.isCompleted || !store.isBatchCurrent(batch)) throw const _MemoryRequestStale();
          store.markRequestSent(requestId);
          dispatched = true;
        },
        onUsage: (usage) => store.recordUsage(requestId, usage),
      );
      terminal = reply.terminal;
      if (cancelled.isCompleted || !store.isBatchCurrent(batch)) {
        store.releaseBatch(batch, reason: 'stale');
        return CompanionMemoryWork.stale;
      }
      // Network/configuration failures throw at the route. A complete provider
      // answer that was cut off by max_tokens is an invalid proposal, not an
      // empty successful extraction.
      if (!reply.complete) {
        store.releaseBatch(batch, reason: 'network');
        return CompanionMemoryWork.waiting;
      }
      if (reply.terminal != 'complete') {
        store.recordInvalidProposal(batch);
        return CompanionMemoryWork.invalid;
      }
      final Map<String, Object?> proposal;
      try {
        proposal = parseExtractionProposal(reply.text, batch);
      } on FormatException {
        store.recordInvalidProposal(batch);
        return CompanionMemoryWork.invalid;
      }
      return store.commitExtraction(batch, proposal) ? CompanionMemoryWork.committed : CompanionMemoryWork.stale;
    } on _MemoryRequestStale {
      terminal = dispatched || uncertain ? 'cancelled' : 'not_sent';
      store.releaseBatch(batch, reason: 'stale');
      return CompanionMemoryWork.stale;
    } on CompanionAuxiliaryError catch (error) {
      terminal = error.notSent ? 'not_sent' : error.terminal;
      store.releaseBatch(batch, reason: error.configuration ? 'configuration' : 'network');
      return error.configuration ? CompanionMemoryWork.configuration : CompanionMemoryWork.waiting;
    } on Object {
      store.releaseBatch(batch, reason: 'local_error');
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
