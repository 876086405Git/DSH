// Full-mode model rounds use the selected Host provider through one owned
// HTTP attempt. The phone caller owns tools and the durable usage receipt.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import 'companion_agent_loop.dart';
import 'companion_light.dart';
import 'companion_memory_worker.dart';

class CompanionHostMemoryTransport implements CompanionAgentModelTransport {
  const CompanionHostMemoryTransport({required this.client, required this.capability, this.isCurrent});

  final DshClient client;
  final CompanionAuxiliaryCapability capability;
  final bool Function()? isCurrent;

  @override
  String get provider => capability.provider;

  @override
  String get model => capability.model;

  @override
  bool get configured => capability.supported;

  @override
  bool get agentConfigured => capability.supported && capability.agentSupported;

  @override
  bool get current => isCurrent?.call() ?? true;

  @override
  Future<CompanionAgentMessage?> readAgent({
    required CompanionAgentModelRequest request,
    required String system,
    required List<Map<String, Object?>> messages,
    required List<CompanionAgentTool> tools,
    required bool Function() isCurrent,
    required void Function(String) onText,
    required void Function() onDispatchUncertain,
    required void Function() onSent,
    required void Function(Map<String, Object?>) onUsage,
    void Function(Map<String, Object?>, {required bool partial})? onUsageSettled,
    int maxTokens = 800,
  }) => request.readHost(
    client: client,
    capability: capability,
    system: system,
    messages: messages,
    tools: tools,
    isCurrent: () => current && isCurrent(),
    onText: onText,
    onDispatchUncertain: () {
      if (!current || !isCurrent()) throw const DshClosedException('Companion Host route changed');
      onDispatchUncertain();
    },
    onSent: onSent,
    onUsage: onUsage,
    onUsageSettled: onUsageSettled,
    maxTokens: maxTokens,
  );

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
      if (!current) throw const DshClosedException('Companion Host route changed');
      final result = await client.callCompanionAuxiliary(
        capability,
        requestId: requestId,
        kind: category == 'organize' ? 'consolidate' : category,
        system: system,
        input: input,
        maxTokens: maxTokens,
        abort: abort,
        onDispatchUncertain: () {
          if (!current) throw const DshClosedException('Companion Host route changed');
          onDispatchUncertain();
        },
        onSent: onSent,
        onUsage: onUsage,
      );
      if (!current) throw const DshClosedException('Companion Host route changed');
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
