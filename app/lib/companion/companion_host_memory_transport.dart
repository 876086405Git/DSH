// Full-mode extraction uses the selected Host provider through one owned HTTP
// attempt. The worker owns the durable reservation and proposal validation.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import 'companion_memory_worker.dart';

class CompanionHostMemoryTransport implements CompanionMemoryTransport {
  const CompanionHostMemoryTransport({required this.client, required this.capability});

  final DshClient client;
  final CompanionAuxiliaryCapability capability;

  @override
  String get provider => capability.provider;

  @override
  String get model => capability.model;

  @override
  bool get configured => capability.supported;

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
    final abort = DshHttpAbort();
    unawaited(cancelled.then((_) => abort.abort()));
    try {
      final result = await client.callCompanionAuxiliary(
        capability,
        requestId: requestId,
        kind: category == 'organize' ? 'consolidate' : category,
        system: system,
        input: input,
        maxTokens: maxTokens,
        abort: abort,
        onDispatchUncertain: onDispatchUncertain,
        onSent: onSent,
        onUsage: onUsage,
      );
      if (!result.complete) {
        throw CompanionAuxiliaryError(
          configuration: _configuration(result.errorCode, result.httpStatus),
          notSent: result.dispatched == false,
          terminal: result.terminal,
        );
      }
      // A complete refusal, truncation or empty answer belongs to the common
      // finite invalid-proposal path. Unknown dispatch does not block content.
      return CompanionAuxiliaryReply(text: result.text, terminal: result.terminal, complete: result.complete);
    } on CompanionAuxiliaryFailure catch (error) {
      throw CompanionAuxiliaryError(
        configuration: _configuration(error.code, error.httpStatus),
        notSent: error.notSent,
        terminal: error.terminal,
      );
    } finally {
      abort.abort();
    }
  }
}

bool _configuration(String? code, int? status) =>
    const {400, 401, 403, 404, 413, 422}.contains(status) ||
    const {
      'route-unavailable',
      'invalid-request',
      'request-limit',
      'companion/auxiliary-forbidden',
      'companion/auxiliary-unavailable',
      'companion/auxiliary-model-unavailable',
      'companion/auxiliary-session-unavailable',
      'INVALID_CREDENTIAL',
      'MISSING_CREDENTIAL',
      'AUTH',
      'UNKNOWN_MODEL',
      'NO_ADAPTER',
      'MODEL_UNSUPPORTED',
      'CLIENT_UPGRADE_REQUIRED',
      'UNSUPPORTED_REASONING_EFFORT',
      'INVALID_REQUEST',
      'COMPANION_AUXILIARY_UNAVAILABLE',
    }.contains(code);
