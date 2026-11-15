// Tool calls that were sent off but never came back. The in-process engine on iOS and
// HarmonyOS records each call as it goes, so after an interruption it knows a call may or
// may not have run. It then refuses that session's further tools until the user decides.
//
// Nothing here runs on its own: loading, reconnecting and reading never acknowledge.

import 'dart:io' show Platform;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';

/// Whether the local engine keeps that record. Android's has no such route.
final durableCallsHostProvider = Provider<bool>((ref) => Platform.isIOS || Platform.operatingSystem == 'ohos');

/// A session's record, as read from one client.
class UnknownResults {
  const UnknownResults(this.client, this.snapshot);

  final DshClient client;
  final LifecycleSnapshot snapshot;

  bool get pending => snapshot.hasUnknownResult;

  /// The engine couldn't write its record. Nothing the user decides here repairs that.
  bool get blocked => snapshot.blocked;

  List<String> get toolNames => [for (final call in snapshot.unresolvedCalls) call.identity.name];
}

/// Null where there's nothing to read, or it can't be read now: the banner stays away, and
/// a tool refused for this reason still says so in the conversation.
final unknownResultsProvider = FutureProvider.autoDispose.family<UnknownResults?, String>((ref, sessionId) async {
  if (!ref.watch(durableCallsHostProvider)) return null;
  final connection = ref.watch(activeConnectionProvider).value;
  if (connection == null || !connection.isLocal) return null;
  try {
    return UnknownResults(connection.client, await connection.client.getLifecycleStatus(sessionId));
  } on DshException {
    return null;
  }
});

enum AbandonOutcome { done, changed }

/// Continues past the calls the user was shown, once the user has said so.
///
/// The engine's acknowledgement covers whatever is unknown in the session at that moment.
/// So this reads again first, and stops if that's no longer what the user saw. It still
/// can't rule out a change between that read and the acknowledgement. [isCurrent]
/// must stay false once the connection or confirmation owner has changed.
Future<AbandonOutcome> abandonUnknownResults(UnknownResults seen, {required bool Function() isCurrent}) async {
  if (!isCurrent()) return AbandonOutcome.changed;
  final sessionId = seen.snapshot.sessionId;
  final now = await seen.client.getLifecycleStatus(sessionId);
  if (!isCurrent() || now.bootId != seen.snapshot.bootId || !_sameCalls(now, seen.snapshot)) {
    return AbandonOutcome.changed;
  }
  await seen.client.acknowledgeLifecycleUnknown(sessionId, userConfirmed: true);
  return AbandonOutcome.done;
}

bool _sameCalls(LifecycleSnapshot a, LifecycleSnapshot b) {
  final seen = {for (final call in b.unresolvedCalls) call.identity.callSeq};
  final now = {for (final call in a.unresolvedCalls) call.identity.callSeq};
  return seen.length == now.length && seen.containsAll(now);
}
