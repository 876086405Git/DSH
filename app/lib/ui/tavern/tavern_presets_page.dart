// 资源库 › 预设 (docs/design/roleplay-roadmap.md P0, engine T20): presets
// exported from SillyTavern, and dsh-preset-enhance share packages, imported
// as they are; which one chats use by default; export and delete. Editing a
// preset's prompts and numbers, and a chat choosing its own, come next.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../bots/bot_format.dart' show shortTime;
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_chat_files.dart';
import 'tavern_preset_page.dart';
import 'tavern_report_page.dart';
import 'tavern_widgets.dart';

/// The library's presets, newest first.
final tavernPresetsProvider = StreamProvider<List<TavernPresetSummary>>(
  (ref) => ref.watch(tavernProvider).watchPresets(),
);

/// Which preset a chat (or, for null, a new chat) uses.
final tavernPresetSelectionProvider = FutureProvider.family<TavernPresetSelection, String?>((ref, chatId) {
  ref.watch(tavernPresetsProvider);
  return ref.watch(tavernProvider).presetSelection(chatId: chatId);
});

/// [bytes] as text, a leading BOM kept: the engine keeps a preset's source
/// exactly as it came (Dart's own UTF-8 decoding would drop it).
String tavernTextOf(Uint8List bytes) {
  final bom = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
  final text = utf8.decode(bom ? bytes.sublist(3) : bytes);
  return bom ? '﻿$text' : text;
}

/// Picks preset files and imports each; says how it went.
Future<void> importTavernPresets(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final tavern = ref.read(tavernProvider);
  for (final file in await ref.read(tavernChatPickerProvider)()) {
    String notice;
    try {
      final result = await tavern.importPreset(tavernTextOf(file.bytes), fileName: file.fileName);
      notice = result.issues.isEmpty
          ? l10n.tavernPresetImported(result.preset.name)
          : l10n.tavernPresetImportedWithIssues(result.preset.name, result.issues.length);
    } on FormatException {
      notice = l10n.tavernPresetImportFailed(l10n.tavernPresetNotText);
    } on TavernPresetImportError catch (e) {
      notice = l10n.tavernPresetImportFailed(e.issues.map((i) => '${i.path} ${i.message}').join('；'));
    } on Object catch (e) {
      notice = l10n.tavernPresetImportFailed('$e');
    }
    messenger?.showBriefNotice(notice);
  }
  ref.invalidate(tavernPresetSelectionProvider);
}

/// [presets]' name for [id]; SillyTavern's own for none.
String tavernPresetName(BuildContext context, List<TavernPresetSummary> presets, String? id) =>
    presets.where((p) => p.id == id).firstOrNull?.name ?? context.l10n.tavernPresetStDefault;

/// The sheet where [chatId] picks its own preset, or follows the default.
Future<void> showTavernPresetPicker(BuildContext context, String chatId) => showAppSheet<void>(
  context,
  builder: (sheet) => Consumer(
    builder: (inner, ref, _) {
      final l10n = inner.l10n;
      final presets = ref.watch(tavernPresetsProvider).value ?? const <TavernPresetSummary>[];
      final selection = ref.watch(tavernPresetSelectionProvider(chatId)).value;
      final bound = selection?.boundPresetId;
      // The sheet's ref goes with the sheet: what binding needs, taken first.
      final tavern = ref.read(tavernProvider);
      final container = ProviderScope.containerOf(inner, listen: false);
      Future<void> bind(String? id) async {
        Navigator.of(sheet).pop();
        if (id == bound) return;
        await tavern.bindPreset(chatId, id);
        container.invalidate(tavernPresetSelectionProvider);
      }

      Widget tick(bool on) =>
          on ? Icon(AppIcons.selected, size: 18, color: Theme.of(inner).colorScheme.primary) : const SizedBox.shrink();
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.tavernPresetForChat),
            Flexible(
              child: SingleChildScrollView(
                child: SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    SettingsTile(
                      key: const ValueKey('tavern-chat-preset-follow'),
                      icon: AppIcons.restart,
                      tinted: false,
                      title: l10n.tavernPresetFollowDefault(
                        tavernPresetName(inner, presets, selection?.defaultPresetId),
                      ),
                      value: tick(bound == null),
                      chevron: false,
                      onTap: () => unawaited(bind(null)),
                    ),
                    for (final preset in presets)
                      SettingsTile(
                        key: ValueKey('tavern-chat-preset-${preset.id}'),
                        icon: AppIcons.article,
                        tinted: false,
                        title: preset.name,
                        value: tick(bound == preset.id),
                        chevron: false,
                        onTap: () => unawaited(bind(preset.id)),
                      ),
                  ],
                ),
              ),
            ),
            if (presets.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 16),
                child: Text(
                  l10n.tavernPresetPickerEmpty,
                  style: Theme.of(inner).textTheme.bodySmall?.copyWith(color: DshColors.of(inner).textTertiary),
                ),
              ),
          ],
        ),
      );
    },
  ),
);

/// The sheet where new chats' preset is picked (酒馆设置 › 生成): SillyTavern's
/// own or one from the library.
Future<void> showTavernDefaultPresetPicker(BuildContext context) => showAppSheet<void>(
  context,
  builder: (sheet) => Consumer(
    builder: (inner, ref, _) {
      final l10n = inner.l10n;
      final presets = ref.watch(tavernPresetsProvider).value ?? const <TavernPresetSummary>[];
      final current = ref.watch(tavernPresetSelectionProvider(null)).value?.defaultPresetId;
      final tavern = ref.read(tavernProvider);
      final container = ProviderScope.containerOf(inner, listen: false);
      Future<void> pick(String? id) async {
        Navigator.of(sheet).pop();
        if (id == current) return;
        await tavern.setDefaultPreset(id);
        container.invalidate(tavernPresetSelectionProvider);
      }

      Widget tick(bool on) =>
          on ? Icon(AppIcons.selected, size: 18, color: Theme.of(inner).colorScheme.primary) : const SizedBox.shrink();
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.tavernDefaultPresetPick),
            Flexible(
              child: SingleChildScrollView(
                child: SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    SettingsTile(
                      key: const ValueKey('tavern-default-preset-st'),
                      icon: AppIcons.article,
                      tinted: false,
                      title: l10n.tavernPresetStDefault,
                      subtitle: l10n.tavernPresetStDefaultNote,
                      value: tick(current == null),
                      chevron: false,
                      onTap: () => unawaited(pick(null)),
                    ),
                    for (final preset in presets)
                      SettingsTile(
                        key: ValueKey('tavern-default-preset-${preset.id}'),
                        icon: AppIcons.article,
                        tinted: false,
                        title: preset.name,
                        value: tick(current == preset.id),
                        chevron: false,
                        onTap: () => unawaited(pick(preset.id)),
                      ),
                  ],
                ),
              ),
            ),
            if (presets.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 16),
                child: Text(
                  l10n.tavernDefaultPresetEmpty,
                  style: Theme.of(inner).textTheme.bodySmall?.copyWith(color: DshColors.of(inner).textTertiary),
                ),
              ),
          ],
        ),
      );
    },
  ),
);

class TavernPresetsPage extends ConsumerWidget {
  const TavernPresetsPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernPresetsPage());

  Future<void> _setDefault(WidgetRef ref, String? id) async {
    await ref.read(tavernProvider).setDefaultPreset(id);
    ref.invalidate(tavernPresetSelectionProvider);
  }

  Future<void> _export(BuildContext context, WidgetRef ref, TavernPresetSummary preset) async {
    final text = await ref.read(tavernProvider).exportPreset(preset.id);
    final bytes = Uint8List.fromList(utf8.encode(text));
    await ref.read(tavernChatSinkProvider)([TavernChatFile(fileName: '${preset.name}.json', bytes: bytes)]);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, TavernPresetSummary preset) async {
    final l10n = context.l10n;
    final ok = await confirmTavernDelete(
      context,
      title: l10n.tavernPresetDeleteTitle(preset.name),
      message: l10n.tavernPresetDeleteMessage,
    );
    if (!ok) return;
    await ref.read(tavernProvider).deletePreset(preset.id);
    ref.invalidate(tavernPresetSelectionProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final presets = ref.watch(tavernPresetsProvider).value;
    final defaultId = ref.watch(tavernPresetSelectionProvider(null)).value?.defaultPresetId;
    Widget mark(bool isDefault) => isDefault ? Text(l10n.tavernPresetDefault) : const SizedBox.shrink();
    return AppPage.list(
      title: l10n.tavernPresets,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-preset-import'),
          icon: AppIcons.add,
          tooltip: l10n.tavernPresetImport,
          onPressed: () => unawaited(importTavernPresets(context, ref)),
        ),
      ],
      children: [
        if (presets == null)
          const QuietSpinner()
        else ...[
          SettingsSection(
            // Only the built-in one so far: what can be added, under it.
            footer: presets.isEmpty
                ? Text(l10n.tavernPresetsEmptyMessage, key: const ValueKey('tavern-presets-empty'))
                : null,
            children: [
              SettingsTile(
                key: const ValueKey('tavern-preset-st'),
                title: l10n.tavernPresetStDefault,
                subtitle: l10n.tavernPresetStDefaultNote,
                value: mark(defaultId == null),
                chevron: false,
                onTap: defaultId == null ? null : () => unawaited(_setDefault(ref, null)),
              ),
              for (final preset in presets)
                SettingsTile(
                  key: ValueKey('tavern-preset-${preset.id}'),
                  title: preset.name,
                  subtitle: [
                    shortTime(preset.updatedAt),
                    if (preset.hasEnvelope) l10n.tavernPresetEnvelope,
                  ].join(' · '),
                  value: mark(preset.id == defaultId),
                  onTap: () => unawaited(
                    showTavernActions(context, [
                      if (preset.id == defaultId)
                        (AppIcons.remove, l10n.tavernPresetUnsetDefault, () => unawaited(_setDefault(ref, null)))
                      else
                        (AppIcons.selected, l10n.tavernPresetSetDefault, () => unawaited(_setDefault(ref, preset.id))),
                      (
                        AppIcons.edit,
                        l10n.tavernPresetEdit,
                        () => unawaited(Navigator.of(context).push(TavernPresetPage.route(preset.id))),
                      ),
                      (
                        AppIcons.info,
                        l10n.tavernReport,
                        () => unawaited(
                          Navigator.of(context).push(
                            TavernImportReportPage.route(
                              kind: TavernImportKind.preset,
                              assetId: preset.id,
                              name: preset.name,
                            ),
                          ),
                        ),
                      ),
                      (AppIcons.share, l10n.tavernPresetExport, () => unawaited(_export(context, ref, preset))),
                      (AppIcons.delete, l10n.tavernPresetDelete, () => unawaited(_delete(context, ref, preset))),
                    ]),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
