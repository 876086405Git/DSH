// HarmonyOS resets in two processes: this one writes a journal, the next one does
// the deleting as the app opens. So a request has three answers, and "failed" is
// only one of them. Android's reset is done when it returns and needs none of this.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../common/brief_notice.dart';
import '../phone/phone_widgets.dart';

/// What the last process knew about the reset it asked for.
const _receiptKey = 'engine_reset_receipt';
const _receiptUnknown = 'unknown';
const _receiptCommitted = 'committed';

Future<void> _keepReceipt(String? value) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove(_receiptKey);
    } else {
      await prefs.setString(_receiptKey, value);
    }
  } catch (_) {}
}

Future<void> _reopen(ProviderContainer container, ScaffoldMessengerState? messenger, String failed) async {
  try {
    await container.read(runtimeBridgeProvider).reopenApp();
  } catch (_) {
    // The system says no while the app isn't on top, or within 3 s of the last time.
    messenger?.showSnackBar(SnackBar(content: Text(failed)));
  }
}

/// The reset entry's request: reinstalls as the app reopens. Host config,
/// preferences and keys were never in its scope.
Future<void> resetOnHarmony(BuildContext context, WidgetRef ref, ResetKeep keep) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  // Before the request: its answer may be the last thing this process hears.
  await _keepReceipt(_receiptUnknown);
  // Its conversations are going: don't reopen one of them.
  if (ref.read(activeHostProvider).isLocal) ref.read(currentSessionProvider.notifier).select(null);
  try {
    await ref.read(localRuntimeProvider.notifier).resetAndReinstall(keep);
    await _keepReceipt(_receiptCommitted);
    messenger?.showSnackBar(SnackBar(content: Text(l10n.harmonyResetReopening)));
  } on RuntimeResetFailure catch (failure) {
    await _keepReceipt(switch (failure.commitState) {
      RuntimeResetCommitState.committed => _receiptCommitted,
      RuntimeResetCommitState.unknown => _receiptUnknown,
      RuntimeResetCommitState.notCommitted => null,
    });
    if (context.mounted) await showResetOutcome(context, failure);
  } catch (_) {
    await _keepReceipt(null);
    messenger?.showSnackBar(SnackBar(content: Text(l10n.phoneEngineResetFailed)));
  }
}

/// Says which of the three answers [failure] is, and offers what's next.
Future<void> showResetOutcome(BuildContext context, RuntimeResetFailure failure) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final code = failure.cause is PlatformException ? (failure.cause as PlatformException).code : null;
  // Refused before anything stopped: there is nothing to reopen for.
  if (code == 'reset_busy') {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.harmonyResetInstalling)));
    return;
  }
  final (title, body) = switch (failure.commitState) {
    RuntimeResetCommitState.committed => (l10n.harmonyResetCommittedTitle, l10n.harmonyResetCommittedBody),
    RuntimeResetCommitState.unknown => (l10n.harmonyResetUnknownTitle, l10n.harmonyResetUnknownBody),
    RuntimeResetCommitState.notCommitted when code == 'ohos_reset_pending' => (
      l10n.harmonyResetOlderPendingTitle,
      l10n.harmonyResetOlderPendingBody,
    ),
    RuntimeResetCommitState.notCommitted => (l10n.harmonyResetNotCommittedTitle, l10n.harmonyResetNotCommittedBody),
  };
  final container = ProviderScope.containerOf(context, listen: false);
  final again = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonLater)),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.harmonyReopenApp)),
      ],
    ),
  );
  if (again == true) await _reopen(container, messenger, l10n.engineReopenFailed);
}

/// The engine page while a committed reset waits for the app to reopen.
class ResetPendingNote extends ConsumerWidget {
  const ResetPendingNote({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return PhoneNote(
      tone: NoteTone.warn,
      title: l10n.harmonyResetPendingTitle,
      text: l10n.harmonyResetPendingBody,
      action: TextButton(
        onPressed: () => unawaited(
          _reopen(
            ProviderScope.containerOf(context, listen: false),
            ScaffoldMessenger.maybeOf(context),
            l10n.engineReopenFailed,
          ),
        ),
        child: Text(l10n.harmonyReopenApp),
      ),
    );
  }
}

/// Back after a reset was asked for: says how it came out, once. An unknown
/// commit can't tell a finished reset from one that never was, so it says that.
/// Put it once inside the home route (the home shell does, on HarmonyOS).
class ResetReceiptHost extends ConsumerStatefulWidget {
  const ResetReceiptHost({super.key});

  @override
  ConsumerState<ResetReceiptHost> createState() => _ResetReceiptHostState();
}

class _ResetReceiptHostState extends ConsumerState<ResetReceiptHost> {
  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    String? receipt;
    try {
      receipt = (await SharedPreferences.getInstance()).getString(_receiptKey);
    } catch (_) {}
    if (receipt == null || !mounted) return;
    // Still pending: the engine page says so, and this waits for the open that finishes it.
    if (ref.read(localRuntimeProvider).status.resetPending) return;
    await _keepReceipt(null);
    if (!mounted) return;
    final l10n = context.l10n;
    showBriefNotice(context, receipt == _receiptCommitted ? l10n.harmonyResetDone : l10n.harmonyResetMaybeDone);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
