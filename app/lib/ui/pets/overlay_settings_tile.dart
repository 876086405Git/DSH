// 宠物设置's 「App 外显示」 group (docs/design/pets.md §2.7, §6.4, §8): the
// switch, 有事时显示 / 一直显示, 「未授权」 with a way back to the permission,
// 悬浮窗里显示 (the pixel pet or the companion from her room) with its 取景,
// the restricted-settings guide on Android 13+, and 今天不再显示. Mounted by
// `PetSettingsPage`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_float.dart';
import '../../companion/companion_state.dart';
import '../../l10n/l10n.dart';
import '../../pets/overlay_channel.dart';
import '../../pets/pet_prefs.dart';
import '../common/expand_reveal.dart';
import '../common/risk_notice.dart';
import '../phone/restricted_settings_guide.dart';
import '../settings/settings_widgets.dart';

/// 「App 外显示」. Nothing without the native side (tests, desktop).
class PetOverlaySettingsSection extends ConsumerStatefulWidget {
  const PetOverlaySettingsSection({super.key});

  @override
  ConsumerState<PetOverlaySettingsSection> createState() => _PetOverlaySettingsSectionState();
}

class _PetOverlaySettingsSectionState extends ConsumerState<PetOverlaySettingsSection> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Back from system settings: check for real (the switch there may lie).
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(ref.read(petOverlayProvider.notifier).refresh()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// On; a permission still to grant is said first, then system settings.
  Future<void> _turnOn(PetOverlayStatus s) async {
    if (!s.permission.usable && !await confirmRisk(context, RiskNotices.petOverlay)) return;
    if (!mounted) return;
    await ref.read(petOverlayProvider.notifier).turnOn();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = ref.watch(petOverlayProvider);
    if (!s.native) return const SizedBox.shrink();
    final overlay = ref.read(petOverlayProvider.notifier);
    final on = s.working;
    final refused = s.refused || (s.enabled && !s.permission.usable);
    // Sideloaded on Android 13+: the system switch may be greyed out until
    // 「允许受限制的设置」. Offered once a trip there came back empty.
    final restricted = s.refused && s.sdk >= 33 && s.permission != PetOverlayPermission.blocked;
    return SettingsSection(
      children: [
        SettingsSwitchTile(
          spot: Spots.petOutsideApp,
          subtitle: refused ? l10n.botsPetNotAuthorized : null,
          value: on,
          onChanged: (v) => unawaited(v ? _turnOn(s) : overlay.turnOff()),
        ),
        ExpandReveal(
          open: on,
          child: SettingsSegmentTile<bool>(
            spot: Spots.petDisplayWhen,
            segments: [PillSegment(false, l10n.botsPetWhenActive), PillSegment(true, l10n.botsPetAlways)],
            selected: s.alwaysShow,
            onChanged: (v) => unawaited(overlay.setAlwaysShow(v)),
          ),
        ),
        if (on) const _OverlayRendererTile(),
        if (on) const _OverlayFramingTile(),
        if (restricted)
          SettingsTile(
            title: l10n.botsPetSwitchDisabled,
            value: Text(l10n.botsPetRestrictedSettings),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const RestrictedSettingsGuidePage(target: RestrictedTarget.overlay),
              ),
            ),
          ),
        if (on && s.snoozed)
          SettingsTile(
            title: l10n.botsPetHiddenToday,
            value: Text(l10n.botsPetRestore),
            chevron: false,
            onTap: () => unawaited(overlay.unsnooze()),
          ),
      ],
    );
  }
}

/// 「悬浮窗里显示」: the pixel pet, or the companion from her room
/// (docs/design/companion-floating.md). She can't be picked while her pack
/// is missing or broken, and the row says why; a choice already made can
/// always be taken back.
class _OverlayRendererTile extends ConsumerWidget {
  const _OverlayRendererTile();

  /// [CompanionPackStore.unavailableReason] and the float session's own
  /// codes, in the three things a person can do about them.
  static String _why(L10n l10n, String reason) => switch (reason) {
    'companion_runtime_missing' => l10n.botsPetOverlayNoPack,
    'companion_runtime_incomplete' ||
    'companion_runtime_mismatch' ||
    'companion_missing_index' ||
    'companion_bad_index' ||
    'companion_no_model' ||
    'companion_missing_model' ||
    'companion_bad_model' ||
    'companion_bad_moc' ||
    'companion_moc_version' ||
    'companion_bad_reference' ||
    'companion_missing_reference' ||
    'companion_missing_texture' ||
    'companion_missing_file' ||
    'companion_bad_json' ||
    'companion_unsafe_path' ||
    'companion_too_large' ||
    'companion_changed' => l10n.botsPetOverlayPackBroken,
    _ => l10n.botsPetOverlayUnavailable,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The iOS PiP source renders pixel frames. It has no native WebView
    // configureCompanion endpoint, so offering this choice would only fail.
    if (ref.watch(petOverlayProvider.select((s) => s.ios))) return const SizedBox.shrink();
    final l10n = context.l10n;
    final availability = ref.watch(companionFloatAvailabilityProvider);
    final running = ref.watch(companionFloatProvider);
    final fallback = ref.watch(petOverlayProvider.select((s) => s.companionFallback));
    final name = ref.watch(companionNameProvider);
    final selected = ref.watch(petPrefsProvider.select((p) => p.overlayRenderer)) == PetOverlayRenderer.companion;
    final available = availability is AsyncData<String?> && availability.value == null;
    final reason = availability.hasError ? 'companion_storage' : availability.asData?.value ?? running.problem;
    final failed = selected && reason == null && fallback && !running.loading;
    final String? subtitle;
    if (selected && (availability.isLoading || running.loading)) {
      subtitle = l10n.botsPetOverlayLoading;
    } else if (reason != null) {
      subtitle = _why(l10n, reason);
    } else if (failed) {
      subtitle = l10n.botsPetOverlayFallback;
    } else {
      subtitle = selected ? l10n.botsPetOverlayCompanionHint : null;
    }
    final theme = Theme.of(context);
    return SettingsSegmentTile<PetOverlayRenderer>(
      spot: Spots.petOverlayShows,
      subtitle: subtitle,
      // The pixel pet is filling in: ask for her again. As small as the line
      // it follows, as tall as a finger needs.
      subtitleAction: failed
          ? TextButton(
              onPressed: () => unawaited(ref.read(companionFloatProvider.notifier).retry()),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: theme.colorScheme.primary,
                textStyle: theme.textTheme.bodySmall,
              ),
              child: Text(l10n.commonRetry),
            )
          : null,
      segments: [
        PillSegment(PetOverlayRenderer.pixel, l10n.botsPetOverlayPixel),
        PillSegment(
          PetOverlayRenderer.companion,
          name == null ? l10n.botsPetOverlayCompanion : l10n.botsPetOverlayCompanionNamed(name),
        ),
      ],
      selected: selected ? PetOverlayRenderer.companion : PetOverlayRenderer.pixel,
      onChanged: selected || available
          ? (value) => unawaited(ref.read(petPrefsProvider.notifier).setOverlayRenderer(value))
          : null,
    );
  }
}

/// 「取景」, while she is the one in the window.
class _OverlayFramingTile extends ConsumerWidget {
  const _OverlayFramingTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final prefs = ref.watch(petPrefsProvider);
    return ExpandReveal(
      open: prefs.overlayRenderer == PetOverlayRenderer.companion,
      child: SettingsSegmentTile<PetOverlayFraming>(
        spot: Spots.petOverlayFraming,
        subtitle: l10n.botsPetOverlayFramingHint,
        segments: [
          PillSegment(PetOverlayFraming.full, l10n.botsPetOverlayFramingFull),
          PillSegment(PetOverlayFraming.half, l10n.botsPetOverlayFramingHalf),
        ],
        selected: PetOverlayFraming.of(prefs),
        onChanged: (framing) =>
            unawaited(ref.read(petPrefsProvider.notifier).setOverlayFraming(zoom: framing.zoom, y: framing.y)),
      ),
    );
  }
}
