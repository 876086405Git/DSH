// 设置 › 主题 › 宠物 (docs/design/pets.md §2.1): which pet (with live
// previews), its size, quiet mode, and the out-of-app overlay's group.
// Entry: [PetEntryTile] on the 主题 page.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../pets/pet_library.dart';
import '../../pets/pet_pack.dart';
import '../../pets/pet_prefs.dart';
import '../../pets/pet_signals.dart';
import '../../pets/pet_state.dart';
import '../../state/android_features.dart';
import '../../state/compose_inbox.dart';
import '../../state/ui_mode_state.dart';
import '../../state/web_target.dart';
import '../../ui_config/ui_skill.dart' show petThemeSkillName;
import '../common/expand_reveal.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../shell/page_frame.dart';
import '../workshop/workshop_screen.dart';
import 'overlay_settings_tile.dart';
import 'pet_custom_size.dart';
import 'pet_picker.dart';

/// 设置 › 宠物: the chosen pet (or 不显示) on the right; opens
/// [PetSettingsPage].
class PetEntryTile extends ConsumerWidget {
  const PetEntryTile({super.key, this.tint = 0});

  /// The hub group's hue.
  final int tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(petPrefsProvider.select((p) => p.packId));
    final packName = id == noPetId ? null : ref.watch(petPackProvider(id)).value?.name;
    final name = AppLocale.isEnglish ? petNames[id] ?? packName ?? id : packName ?? petNames[id] ?? id;
    return SettingsTile(
      icon: AppIcons.pet,
      tint: tint,
      spot: SettingsIndex.entry(SettingsPageId.pets),
      value: Text(name),
      onTap: () => PetSettingsPage.open(context),
    );
  }
}

/// 宠物设置.
class PetSettingsPage extends ConsumerWidget {
  const PetSettingsPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PetSettingsPage()));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final hasOutsideOverlay = ref.watch(androidSystemFeaturesProvider) || ref.watch(operatingSystemProvider) == 'ios';
    final prefs = ref.watch(petPrefsProvider);
    final now = ref.watch(petClockProvider)();
    final hidden = prefs.hiddenAt(now) ? prefs.hiddenUntil : null;
    final notifier = ref.read(petPrefsProvider.notifier);
    return AppPage.list(
      title: l10n.botsPets,
      children: [
        SettingsSection(
          footer: Text(_source(l10n, prefs.packId, ref.watch(petPackProvider(prefs.packId)).value)),
          children: const [PetPicker(importable: true)],
        ),
        // 自己带来的素材：交给新对话里的 AI，用 pet-theme 技能转成宠物包.
        SettingsSection(
          children: [
            SettingsTile(
              spot: Spots.petMake,
              icon: AppIcons.skill,
              title: l10n.botsPetMake,
              subtitle: l10n.botsPetMakeSubtitle,
              onTap: () => _makePet(context),
            ),
          ],
        ),
        // 创意工坊: pets other people made. Only where this build has one to open.
        if (ref.watch(workshopAvailableProvider))
          SettingsSection(
            children: [
              SettingsTile(
                spot: Spots.workshop,
                icon: AppIcons.workshop,
                tinted: false,
                subtitle: l10n.workshopEntrySubtitle,
                onTap: () => unawaited(
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WorkshopScreen())),
                ),
              ),
            ],
          ),
        ExpandReveal(
          open: prefs.enabled,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsSection(
                children: [
                  SettingsSegmentTile<PetSize>(
                    spot: Spots.petSize,
                    segments: [for (final s in PetSize.values) PillSegment(s, s.label)],
                    selected: prefs.size,
                    onChanged: (s) => unawaited(notifier.setSize(s)),
                  ),
                  ExpandReveal(open: prefs.size == PetSize.custom, child: const PetCustomSizePanel()),
                  SettingsSwitchTile(
                    spot: Spots.petQuiet,
                    subtitle: l10n.botsPetQuietSubtitle,
                    value: prefs.quiet,
                    onChanged: (v) => unawaited(notifier.setQuiet(v)),
                  ),
                  if (hidden != null)
                    SettingsTile(
                      title: l10n.botsPetShowNow,
                      value: Text(l10n.botsPetHiddenUntil(_clock(hidden))),
                      chevron: false,
                      onTap: () => unawaited(notifier.unhide()),
                    ),
                ],
              ),
              // App 外显示 (the overlay).
              if (hasOutsideOverlay) const PetOverlaySettingsSection(),
            ],
          ),
        ),
      ],
    );
  }

  /// 「让 AI 做一只宠物」: the skill word waits in a new conversation's composer;
  /// sending it, with a link or files, is the person's call.
  static void _makePet(BuildContext context) {
    final container = ProviderScope.containerOf(context, listen: false);
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    final request = ComposeRequest(text: '/$petThemeSkillName ');
    if (container.read(uiModeProvider).web) {
      // The web home has no native composer: the page opens a new chat with it.
      container.read(webOpenProvider.notifier).request(const DshWebTarget(newSession: true), compose: request);
    } else {
      container.read(composeInboxProvider.notifier).push(request);
    }
  }

  /// Who made the chosen pet, as its pack says (docs/design/pets.md §9), and
  /// how to bring your own.
  static String _source(L10n l10n, String id, PetPack? pack) {
    final made = !isUserPet(id)
        ? l10n.botsPetSource
        : [?pack?.author, ?pack?.license].where((s) => s.trim().isNotEmpty).join(' · ');
    return [if (made.isNotEmpty) made, l10n.botsPetImportHint].join('\n');
  }

  static String _clock(DateTime t) => '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
}
