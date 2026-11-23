// Every companion window shares the phone model loop. Host availability only
// determines which real computer tools a new turn can offer.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../companion/companion_agent.dart';
import '../companion/companion_memory_worker.dart';
import '../companion/companion_state.dart';
import '../usage/usage_stats.dart';
import 'connection_state.dart';
import 'hosts_state.dart';
import 'settings_state.dart';

/// A mode or connection change does not create a second chat runtime. Windows
/// attach to this owner; disposing a window does not dispose the provider.
final companionAgentProvider = Provider<CompanionAgent>((ref) {
  final agent = CompanionAgent(
    ref: ref,
    memoryTransport: () => ref.read(companionAgentMemoryTransportProvider),
    host: () => ref.read(companionAgentHostProvider),
    client: () {
      if (!ref.mounted) {
        throw const DshClosedException('Companion agent closed');
      }
      return ref.read(companionLightClientProvider)();
    },
    apiKey: () => ref.read(settingsProvider).apiKey,
    onUsage: (usage) {
      if (!ref.mounted) return;
      final input = usage.reportedInputTokens;
      if (input != null || usage.outputTokens != null) {
        ref.read(usageStatsProvider.notifier).tokens(input ?? 0, usage.outputTokens ?? 0);
      }
    },
    onUsageSettled: (usage, {required partial}) {
      if (ref.mounted) {
        ref.read(usageStatsProvider.notifier).tokenUsage(UsageTokenSource.companion, usage, partial: partial);
      }
    },
  );
  ref.onDispose(agent.dispose);
  return agent;
});

/// Until the background manager uses the tool loop too, both modes keep the
/// existing worker on the same phone transport, without a stale host Session.
final companionAgentMemoryTransportProvider = Provider<CompanionMemoryTransport>((ref) {
  return CompanionLightMemoryTransport(
    apiKey: () => ref.read(settingsProvider).apiKey,
    client: () => ref.read(companionLightClientProvider)(),
  );
});

typedef CompanionAgentHost = ({HostRef host, DshClient? client});

/// The existing unset preference means full with a connection, light without
/// one. A disconnected selected Host only identifies saved originals for the
/// three offline queue tools; it is not a live capability or a Host session.
/// Explicit light mode continues to offer only phone tools.
final companionAgentHostProvider = Provider<CompanionAgentHost?>((ref) {
  final mode = ref.watch(companionModeProvider);
  final connection = ref.watch(activeConnectionProvider).value;
  final host = ref.watch(activeHostProvider);
  if (mode == CompanionMode.light) return null;
  return (host: host, client: connection?.client);
});
