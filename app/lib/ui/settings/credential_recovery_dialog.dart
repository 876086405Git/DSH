import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../secrets/secure_storage.dart';
import '../../state/android_features.dart';
import '../../state/credential_recovery.dart';
import '../common/brief_notice.dart';
import '../theme/theme.dart';

/// Says what clearing the saved credentials takes away and, on the person's
/// word, clears them.
Future<void> confirmCredentialRecovery(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final recovery = ref.read(credentialRecoveryProvider);
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.harmonyCredentialsUnreadable),
      content: Text(l10n.harmonyCredentialsClearBody),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: DshColors.of(dialog).danger,
            foregroundColor: DshColors.of(dialog).onDanger,
          ),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(l10n.harmonyCredentialsClearAction),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await recovery.recover();
    messenger?.showBriefNotice(l10n.harmonyCredentialsCleared);
  } catch (_) {
    messenger?.showBriefNotice(l10n.harmonyCredentialsClearFailed);
  }
}

/// At a save that failed: true when [error] means the saved credentials can't
/// be read, after offering to clear them. False leaves the failure to the
/// caller, always so off HarmonyOS.
Future<bool> offerCredentialRecovery(BuildContext context, WidgetRef ref, Object error) async {
  if (ref.read(operatingSystemProvider) != 'ohos' || !credentialsUnreadable(error)) return false;
  await confirmCredentialRecovery(context, ref);
  return true;
}
