import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';

/// What "恢复上次正常配置" would change right now. Refreshes whenever the engine's
/// phase, mode or failure changes.
final lastKnownGoodProvider = FutureProvider.autoDispose<LastKnownGood>((ref) async {
  ref.watch(localRuntimeProvider.select((s) => (s.status.phase, s.status.mode, s.status.failure?.at)));
  try {
    return await ref.read(runtimeBridgeProvider).lastKnownGood();
  } catch (_) {
    return const LastKnownGood.none();
  }
});

/// Home-level files that would also break the safe profile (`/root/.dsh/cordis.patch.yml`,
/// `.env` files with launch-only variables).
final safePreflightProvider = FutureProvider.autoDispose<List<SafeHazard>>((ref) async {
  ref.watch(localRuntimeProvider.select((s) => (s.status.phase, s.status.mode)));
  try {
    return await ref.read(runtimeBridgeProvider).safePreflight();
  } catch (_) {
    return const [];
  }
});

/// A repair prompt waiting for the chat composer (「帮我修复」).
///
/// Safe-mode UI calls [request]; the chat screen listens, opens a new session, puts
/// the text in the composer **without sending it** (it costs tokens; the user decides)
/// and calls [take].
class RepairDraftController extends Notifier<String?> {
  @override
  String? build() => null;

  void request(String text) => state = text;

  /// Returns the pending prompt once and clears it.
  String? take() {
    final text = state;
    state = null;
    return text;
  }
}

final repairDraftProvider = NotifierProvider<RepairDraftController, String?>(RepairDraftController.new);

/// One short Chinese clause for a failure, e.g. "启动失败，可疑插件：foo".
String failureOneLiner(RuntimeFailure f) {
  final what = switch (f.kind) {
    FailureKind.launchFailed => appL10n.phoneFailureLaunch,
    FailureKind.startupFailed => appL10n.stateSafeStartupFailed,
    FailureKind.crashedEarly => appL10n.stateSafeCrashedEarly,
    FailureKind.crashedLate => appL10n.stateSafeCrashedLate,
    FailureKind.killed => f.causeUnknown ? appL10n.harmonyEngineUnclean : appL10n.stateSafeKilled,
    FailureKind.noSpace => appL10n.commonStorageFull,
  };
  // Its summary only says this again, in the native side's language.
  if (f.causeUnknown) return what;
  final culprits = f.culprits;
  if (f.kind != FailureKind.launchFailed && culprits.isNotEmpty) {
    return appL10n.stateSafeSuspectPlugins(what, culprits.take(3).join(appL10n.stateListSeparator));
  }
  if (f.kind != FailureKind.launchFailed && f.requiredRows.isNotEmpty) {
    return appL10n.stateSafePreflightFailed(what, f.requiredRows.take(3).join(appL10n.stateListSeparator));
  }
  final summary = f.summary;
  if (summary != null && summary.isNotEmpty) {
    return appL10n.stateActionReason(what, summary.length > 120 ? '${summary.substring(0, 119)}…' : summary);
  }
  return what;
}

/// The text 「帮我修复」 pre-fills. The agent's briefing (written natively on every safe
/// start) has the details; this only points it there. HarmonyOS writes no briefing
/// and has no `dsh-app-plugins`, so its words name neither.
String repairPrompt(RuntimeStatus status, {bool harmony = false}) {
  final f = status.mainFailure ?? status.failure;
  final what = f == null ? appL10n.stateSafeManualEntry : failureOneLiner(f);
  return harmony ? appL10n.harmonySafeRepairPrompt(what) : appL10n.stateSafeRepairPrompt(what);
}
