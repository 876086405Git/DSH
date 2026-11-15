// 手机操控 → 本机连接 (iOS): three steps (pairing record, developer connection, check), the
// developer disk image, the borrowed clipboard and the XCTest enhancement. Every question is the
// native side's own dialog (tooling/ios/phone-control/UI-CONTRACT.md): this page never answers
// one, and shows a failure as it came back instead of retrying some other way.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../phone/ios_phone_link.dart';
import '../../state/ios_phone_link_state.dart';
import '../bots/bot_sheets.dart' show confirmDelete;
import '../common/list_page_row.dart';
import '../session/workspace_files.dart' show formatBytes;
import '../theme/app_icons.dart';
import 'phone_widgets.dart';

/// What a failed step's code means for the user. Null for codes that need no words.
String phoneLinkFailureText(L10n l10n, String code) => switch (code) {
  'ERR_PHONE_BUSY' => l10n.iosPhoneLinkErrorBusy,
  'ERR_PHONE_FOREGROUND_REQUIRED' || 'ERR_PHONE_CLIPBOARD_FOREGROUND_REQUIRED' => l10n.iosPhoneLinkErrorForeground,
  'ERR_PHONE_PAIRING_INVALID' || 'ERR_PHONE_PAIRING_TOO_LARGE' => l10n.iosPhoneLinkErrorPairingInvalid,
  'ERR_PHONE_PAIRING_STORAGE' => l10n.iosPhoneLinkErrorStorage,
  'ERR_PHONE_PAIRING_LOCKED' => l10n.iosPhoneLinkPairingLocked,
  'ERR_PHONE_PAIRING_REQUIRED' || 'ERR_PHONE_LINK_DISABLED' => l10n.iosPhoneLinkErrorPairingRequired,
  'ERR_PHONE_PAIRING_REVOKED' || 'ERR_PHONE_PAIRING_CHANGED' => l10n.iosPhoneLinkErrorPairingRejected,
  'ERR_PHONE_TUNNEL' || 'ERR_PHONE_CORE_NOT_READY' || 'ERR_PHONE_PREPARATION_TIMEOUT' => l10n.iosPhoneLinkErrorTunnel,
  'ERR_PHONE_CORE_SERVICE_UNAVAILABLE' || 'ERR_PHONE_DDI_ALREADY_PRESENT' => l10n.iosPhoneLinkErrorServices,
  'ERR_PHONE_DDI_REQUIRED' || 'ERR_PHONE_DDI_CACHE_REQUIRED' => l10n.iosPhoneLinkErrorDdiNeeded,
  'ERR_PHONE_DDI_DOWNLOAD' || 'ERR_PHONE_DDI_CACHE' => l10n.iosPhoneLinkErrorDdiDownload,
  'ERR_PHONE_DDI_INTEGRITY' => l10n.iosPhoneLinkErrorDdiIntegrity,
  'ERR_PHONE_DDI_UNSUPPORTED_DEVICE' => l10n.iosPhoneLinkErrorDdiUnsupported,
  'ERR_PHONE_DDI_MOUNT' ||
  'ERR_PHONE_DDI_PERSONALIZATION' ||
  'ERR_PHONE_FOREIGN_MEDIA_SESSION' => l10n.iosPhoneLinkErrorDdiMount,
  'ERR_PHONE_CLIPBOARD_CHANGED' => l10n.iosPhoneLinkErrorClipboardChanged,
  'ERR_PHONE_STOP_UNCONFIRMED' => l10n.iosPhoneLinkFaultedHint,
  _ => l10n.iosPhoneLinkErrorOther(code.replaceFirst('ERR_PHONE_', '')),
};

/// The borrowed clipboard, shown above everything else while it waits to be put back.
class PhoneLinkClipboardCard extends ConsumerWidget {
  const PhoneLinkClipboardCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final view = ref.watch(phoneLinkProvider);
    if (!(view.status?.clipboardPending ?? false)) return const SizedBox.shrink();
    final link = ref.read(phoneLinkProvider.notifier);
    final changed = view.failure == 'ERR_PHONE_CLIPBOARD_CHANGED';
    final busy = view.busy;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ListPageCard(
        children: [
          ListPageRow(
            icon: AppIcons.paste,
            iconColor: Theme.of(context).colorScheme.primary,
            title: l10n.iosPhoneLinkClipboardTitle,
            subtitle: changed ? l10n.iosPhoneLinkErrorClipboardChanged : l10n.iosPhoneLinkClipboardHint,
            subtitleMaxLines: 3,
            trailing: FixButton(
              label: l10n.iosPhoneLinkClipboardRestore,
              onPressed: busy ? null : () => unawaited(link.restoreClipboard()),
            ),
          ),
          if (changed)
            ListPageRow(
              icon: AppIcons.paste,
              title: l10n.iosPhoneLinkClipboardOverwrite,
              onTap: busy ? null : () => unawaited(link.restoreClipboard(overwriteChanged: true)),
            ),
          ListPageRow(
            icon: AppIcons.delete,
            title: l10n.iosPhoneLinkClipboardDiscard,
            danger: true,
            onTap: busy ? null : () => unawaited(link.discardClipboard()),
          ),
        ],
      ),
    );
  }
}

/// 本机连接: the steps, then the disk image and what is under way.
class PhoneLinkSection extends ConsumerWidget {
  const PhoneLinkSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final view = ref.watch(phoneLinkProvider);
    final status = view.status;
    if (status == null) return const SizedBox.shrink();
    final link = ref.read(phoneLinkProvider.notifier);
    final busy = view.busy;
    void run(PhoneLinkStep step) => unawaited(link.run(step));

    if (!status.buildAvailable) {
      return ListPageCard(
        title: l10n.iosPhoneLinkTitle,
        children: [ListPageRow(icon: AppIcons.unsupported, title: l10n.iosPhoneLinkUnavailable, subtitleMaxLines: 2)],
      );
    }

    final paired = status.pairingPresent;
    // The last connection never confirmed it closed: nothing connects again until the app restarts.
    final faulted = status.phase == PhoneLinkPhase.faulted;
    final checked = !faulted && (view.checked || (status.lastCheck != null && status.lastCheckCode == 'OK'));
    String failureFor(Set<PhoneLinkStep> steps) =>
        view.failure != null && steps.contains(view.failedStep) ? phoneLinkFailureText(l10n, view.failure!) : '';
    String pick(String failure, String fallback) => failure.isNotEmpty ? failure : fallback;

    final pairingLine = pick(
      failureFor({PhoneLinkStep.importPairing, PhoneLinkStep.migratePairing, PhoneLinkStep.clearPairing}),
      switch (status.pairingCode) {
        'OK' when paired => switch (status.storage) {
          PhoneLinkStorage.session => l10n.iosPhoneLinkPairingSession,
          _ => l10n.iosPhoneLinkPairingDevice,
        },
        'OK' => l10n.iosPhoneLinkPairingHint,
        'ERR_PHONE_PAIRING_LOCKED' => l10n.iosPhoneLinkPairingLocked,
        _ => l10n.iosPhoneLinkPairingUnreadable,
      },
    );
    final enableLine = pick(
      failureFor({PhoneLinkStep.enable, PhoneLinkStep.disable}),
      paired || status.enabled ? l10n.iosPhoneLinkEnableHint : l10n.iosPhoneLinkErrorPairingRequired,
    );
    final checkLine = pick(
      failureFor({PhoneLinkStep.check, PhoneLinkStep.mount}),
      checked
          ? (status.lastCheckCapabilities['touch'] == false ? l10n.iosPhoneLinkReadOnly : l10n.iosPhoneLinkChecked)
          : l10n.iosPhoneLinkCheckHint,
    );
    final canCheck = status.enabled && paired && !busy && !faulted;
    final mounted = status.lastCheckChecks['ddiMounted'] ?? false;

    return ListPageCard(
      title: l10n.iosPhoneLinkTitle,
      children: [
        PhoneStepRow(
          step: 1,
          done: paired,
          title: l10n.iosPhoneLinkStepPairing,
          subtitle: pairingLine,
          trailing: FixButton(
            label: paired ? l10n.iosPhoneLinkReplace : l10n.iosPhoneLinkImport,
            onPressed: busy ? null : () => run(PhoneLinkStep.importPairing),
          ),
        ),
        if (status.legacyPairing)
          ListPageRow(
            icon: AppIcons.apiKey,
            title: l10n.iosPhoneLinkLegacy,
            subtitle: l10n.iosPhoneLinkLegacyHint,
            subtitleMaxLines: 3,
            trailing: FixButton(
              label: l10n.iosPhoneLinkMigrate,
              onPressed: busy ? null : () => run(PhoneLinkStep.migratePairing),
            ),
          ),
        PhoneStepRow(
          step: 2,
          done: status.enabled,
          title: l10n.iosPhoneLinkStepEnable,
          subtitle: enableLine,
          trailing: Switch.adaptive(
            value: status.enabled,
            // Off always works; on needs a record (the native side asks first).
            onChanged: busy || (!status.enabled && !paired)
                ? null
                : (on) => run(on ? PhoneLinkStep.enable : PhoneLinkStep.disable),
          ),
        ),
        PhoneStepRow(
          step: 3,
          done: checked,
          title: l10n.iosPhoneLinkStepCheck,
          subtitle: checkLine,
          trailing: FixButton(
            label: l10n.iosPhoneLinkCheck,
            onPressed: canCheck ? () => run(PhoneLinkStep.check) : null,
          ),
        ),
        if (status.enabled && paired)
          ListPageRow(
            icon: AppIcons.download,
            title: l10n.iosPhoneLinkDdi,
            subtitle: l10n.iosPhoneLinkDdiHint,
            subtitleMaxLines: 4,
            trailing: mounted
                ? DoneMark(label: l10n.iosPhoneLinkDdiMounted)
                : FixButton(
                    label: l10n.iosPhoneLinkDdiPrepare,
                    onPressed: canCheck ? () => run(PhoneLinkStep.mount) : null,
                  ),
          ),
        if (faulted)
          ListPageRow(
            icon: AppIcons.warning,
            title: l10n.iosPhoneLinkFaulted,
            subtitle: l10n.iosPhoneLinkFaultedHint,
            subtitleMaxLines: 4,
          ),
        if (busy)
          ListPageRow(
            leading: const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round),
            ),
            title: status.downloading
                ? l10n.iosPhoneLinkDownloading(formatBytes(status.downloaded), formatBytes(status.downloadTotal))
                : l10n.iosPhoneLinkWorking,
            trailing: FixButton(label: l10n.commonCancel, onPressed: () => unawaited(link.cancel())),
          ),
      ],
    );
  }
}

/// XCTest, off unless chosen, and clearing the record.
class PhoneLinkExtrasSection extends ConsumerWidget {
  const PhoneLinkExtrasSection({super.key});

  /// The native side clears at once, so the question is asked here first.
  static Future<void> _clear(BuildContext context, PhoneLinkController link) async {
    final l10n = context.l10n;
    if (!await confirmDelete(context, title: l10n.iosPhoneLinkClearConfirm, body: l10n.iosPhoneLinkClearHint)) return;
    await link.run(PhoneLinkStep.clearPairing);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final view = ref.watch(phoneLinkProvider);
    final status = view.status;
    if (status == null || !status.buildAvailable) return const SizedBox.shrink();
    final link = ref.read(phoneLinkProvider.notifier);
    final busy = view.busy;
    final xctestFailure =
        view.failure != null && {PhoneLinkStep.xctestOn, PhoneLinkStep.xctestOff}.contains(view.failedStep)
        ? phoneLinkFailureText(l10n, view.failure!)
        : null;
    return ListPageCard(
      title: l10n.iosPhoneLinkEnhanceTitle,
      children: [
        ListPageRow(
          icon: AppIcons.operate,
          title: l10n.iosPhoneLinkXctest,
          subtitle: xctestFailure ?? l10n.iosPhoneLinkXctestHint,
          subtitleMaxLines: 4,
          trailing: Switch.adaptive(
            value: status.xctestEnabled,
            onChanged: busy ? null : (on) => unawaited(link.run(on ? PhoneLinkStep.xctestOn : PhoneLinkStep.xctestOff)),
          ),
        ),
        if (status.xctestEnabled)
          ListPageRow(
            icon: AppIcons.phoneControl,
            title: l10n.phoneIosServiceTitle,
            subtitle: l10n.phoneIosServiceHint,
            subtitleMaxLines: 4,
          ),
        if (status.pairingPresent)
          ListPageRow(
            icon: AppIcons.delete,
            title: l10n.iosPhoneLinkClear,
            subtitle: l10n.iosPhoneLinkClearHint,
            subtitleMaxLines: 3,
            danger: true,
            onTap: busy ? null : () => unawaited(_clear(context, link)),
          ),
      ],
    );
  }
}
