// SPDX-FileCopyrightText: 2026 DSH Remote contributors
// SPDX-License-Identifier: MIT
// Ported from ds-harness-remote 77604776 packages/protocol/src/close-semantics.ts.

/// Close reasons, not bare application codes, distinguish a Server restart
/// from heartbeat expiry. Unknown application codes are terminal.
class ControlCloseClassification {
  const ControlCloseClassification({
    required this.serverShutdown,
    required this.heartbeatTimeout,
    required this.retryable,
    required this.replaced,
  });

  final bool serverShutdown;
  final bool heartbeatTimeout;
  final bool retryable;
  final bool replaced;
}

ControlCloseClassification classifyControlClose(int? code, String? reason) {
  final normalized = reason?.trim() ?? '';
  final shutdown = const [4009, 4001, 1013].contains(code) && normalized == 'server shutdown';
  final heartbeat =
      (code == 4009 && normalized == 'heartbeat timeout') || (code == 4001 && normalized == 'CONNECTION_FAILED');
  return ControlCloseClassification(
    serverShutdown: shutdown,
    heartbeatTimeout: heartbeat,
    retryable: shutdown || heartbeat || const [1000, 1001, 1006, 1011, 1012, 1013].contains(code ?? 1006),
    replaced: code == 4003,
  );
}
