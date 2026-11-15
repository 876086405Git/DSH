// Optional iOS picture-in-picture pet. Phone control uses system continued tasks;
// enabling or recovering this window remains an explicit native choice.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../pets/overlay_channel.dart';
import '../common/list_page_row.dart';
import '../pets/pet_settings_page.dart';
import '../theme/app_icons.dart';
import 'phone_widgets.dart';

/// Why picture-in-picture stopped, in words.
String petPipErrorText(L10n l10n, String code) => switch (code) {
  'overlay_pet_not_selected' => l10n.iosPetPipErrorNoPet,
  'overlay_unsupported' => l10n.iosPetPipErrorUnsupported,
  'overlay_device_locked' => l10n.iosPetPipErrorLocked,
  'overlay_audio_busy' ||
  'overlay_audio_failed' ||
  'overlay_audio_replaced' ||
  'overlay_audio_interrupted' ||
  'overlay_media_reset' => l10n.iosPetPipErrorAudio,
  'overlay_pack_missing' || 'overlay_pack_invalid' || 'overlay_sheet_invalid' => l10n.iosPetPipErrorPack,
  'overlay_pip_start_failed' ||
  'overlay_source_missing' ||
  'overlay_buffer_failed' ||
  'overlay_display_stalled' ||
  'overlay_render_invalid' ||
  'overlay_render_too_small' ||
  'overlay_render_failed' => l10n.iosPetPipErrorStart,
  _ => l10n.iosPetPipErrorOther(code.replaceFirst('overlay_', '')),
};

class IosPetPipSection extends ConsumerWidget {
  const IosPetPipSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final s = ref.watch(petOverlayProvider);
    if (!s.native || !s.ios) return const SizedBox.shrink();
    final overlay = ref.read(petOverlayProvider.notifier);
    // With 始终显示 on and no phone task, the native side has nowhere to show the pet in the app and
    // says so with this code. That is waiting for the next task, not a failure to recover from.
    final error = s.errorCode == 'overlay_source_missing' && !s.phoneTaskActive ? null : s.errorCode;
    final noPet = error == 'overlay_pet_not_selected';
    // A pack problem is fixed by choosing another pet; the rest by trying again.
    final choosePet =
        noPet || const {'overlay_pack_missing', 'overlay_pack_invalid', 'overlay_sheet_invalid'}.contains(error);
    void openPets() =>
        unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PetSettingsPage())));

    final String line;
    if (!s.enabled) {
      line = l10n.iosPetPipRequired;
    } else if (error case final code?) {
      line = petPipErrorText(l10n, code);
    } else if (s.snoozed) {
      line = l10n.iosPetPipErrorClosed;
    } else if (s.keepingAlive) {
      line = l10n.iosPetPipKeepingAlive;
    } else {
      line = l10n.iosPetPipReady;
    }
    final stopped = s.enabled && (error != null || s.snoozed);

    return ListPageCard(
      children: [
        ListPageRow(
          icon: AppIcons.pet,
          title: l10n.iosPetPipTitle,
          subtitle: line,
          trailing: Switch.adaptive(value: s.enabled, onChanged: (on) => unawaited(overlay.iosSetEnabled(on))),
        ),
        if (stopped)
          ListPageRow(
            icon: choosePet ? AppIcons.pet : AppIcons.refresh,
            title: choosePet ? l10n.iosPetPipChoosePetHint : l10n.iosPetPipReopen,
            trailing: choosePet
                ? FixButton(label: l10n.iosPetPipChoosePet, onPressed: openPets)
                : FixButton(label: l10n.iosPetPipResume, onPressed: () => unawaited(overlay.iosResume())),
          ),
        if (s.taskPaused)
          ListPageRow(
            icon: AppIcons.paused,
            title: l10n.iosPetPipPaused,
            trailing: FixButton(label: l10n.iosPetPipReview, onPressed: () => unawaited(overlay.iosReviewPausedTask())),
          ),
        if (s.enabled && s.phoneTaskActive && !s.pipActive && !stopped)
          ListPageRow(
            icon: AppIcons.pet,
            title: l10n.iosPetPipStart,
            subtitle: l10n.iosPetPipStartHint,
            subtitleMaxLines: 2,
            onTap: () => unawaited(overlay.iosStart()),
          ),
        if (s.enabled)
          MergeSemantics(
            child: ListPageRow(
              icon: AppIcons.keepAlive,
              title: l10n.iosPetPipAlways,
              onTap: () => unawaited(overlay.iosSetAlwaysShow(!s.alwaysShow)),
              trailing: Switch.adaptive(
                value: s.alwaysShow,
                onChanged: (on) => unawaited(overlay.iosSetAlwaysShow(on)),
              ),
            ),
          ),
      ],
    );
  }
}
