// 酒馆设置 (docs/design/roleplay-ui.md §1; grouped as the optimization doc's
// §3.4 has it): 模型与连接, 生成, 显示, 安全, 数据, 你.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_mode_state.dart';
import '../../state/attachments.dart' show formatBytes;
import '../../state/settings_state.dart';
import '../../tavern/tavern_generation.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_quick_replies.dart';
import '../../tavern/tavern_settings.dart';
import '../../tavern/tavern_st_theme.dart';
import '../../tavern/tavern_storage.dart';
import '../chat/render/markdown_body.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../modes/mode_switch.dart';
import '../onboarding/api_key_page.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_backup.dart';
import 'tavern_channels_page.dart' show TavernAuxiliaryTile;
import 'tavern_import_files.dart';
import 'tavern_model_rows.dart';
import 'tavern_number_tile.dart';
import 'tavern_personas.dart';
import 'tavern_preset_page.dart';
import 'tavern_presets_page.dart';
import 'tavern_quick_replies_page.dart';
import 'tavern_reading.dart';
import 'tavern_usage_page.dart';
import 'tavern_tool_policy_group.dart';

class TavernSettingsPage extends ConsumerWidget {
  const TavernSettingsPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernSettingsPage());

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      AppPage.list(title: context.l10n.tavernSettings, children: tavernSettingsGroups(context, ref));
}

/// 酒馆设置's groups: on a page of their own, and as 我的 on the tavern's home.
List<Widget> tavernSettingsGroups(BuildContext context, WidgetRef ref) {
  final l10n = context.l10n;
  final settings = ref.watch(tavernSettingsProvider);
  final stTheme = ref.watch(tavernStThemeProvider);
  final hasKey = ref.watch(settingsProvider.select((s) => s.hasApiKey));
  final startup = ref.watch(appModeProvider.select((s) => s.startup));
  final controller = ref.read(tavernSettingsProvider.notifier);
  final defaultPersona = ref.watch(tavernPersonaSelectionProvider(null)).value?.persona;
  final generation = ref.watch(tavernGenerationProvider).value ?? TavernGeneration.standard;
  final generate = ref.read(tavernGenerationProvider.notifier);
  // A preset from the library, once it is the default, is what new chats
  // use: the numbers below would change ST's own, which then goes unused.
  final presets = ref.watch(tavernPresetsProvider).value ?? const <TavernPresetSummary>[];
  final defaultPreset = ref.watch(tavernPresetSelectionProvider(null)).value?.defaultPresetId;
  final defaultName = tavernPresetName(context, presets, defaultPreset);
  final storage = ref.watch(tavernStorageProvider);
  final you = SettingsSection(
    title: l10n.tavernSettingsYou,
    children: [
      SettingsTile(
        key: const ValueKey('tavern-personas'),
        icon: AppIcons.profile,
        title: l10n.tavernDefaultPersona,
        value: _ValueText(defaultPersona?.name ?? l10n.tavernPersonaNotSet),
        onTap: () => unawaited(Navigator.of(context).push(TavernPersonasPage.route())),
      ),
      SettingsTile(
        key: const ValueKey('tavern-quick-replies'),
        icon: AppIcons.reply,
        title: l10n.tavernQuickReplies,
        value: Text(switch (ref.watch(tavernQuickRepliesProvider).length) {
          0 => l10n.tavernPersonaNotSet,
          final n => l10n.tavernQuickReplyCount(n),
        }),
        onTap: () => unawaited(Navigator.of(context).push(TavernQuickRepliesPage.route())),
      ),
    ],
  );
  final model = SettingsSection(
    key: const ValueKey('tavern-connection'),
    title: l10n.tavernSettingsConnection,
    children: [
      ...tavernModelRows(context, ref, keyPrefix: 'tavern'),
      const TavernAuxiliaryTile(),
      // An added channel's key is on that channel.
      if (settings.activeChannel == null)
        SettingsTile(
          key: const ValueKey('tavern-key'),
          icon: hasKey ? AppIcons.apiKey : AppIcons.noApiKey,
          title: l10n.tavernApiKey,
          value: Text(hasKey ? l10n.tavernApiKeySet : l10n.tavernApiKeyMissing),
          onTap: () =>
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ApiKeyPage(onboarding: false))),
        ),
    ],
  );
  final generating = SettingsSection(
    key: const ValueKey('tavern-generation'),
    title: l10n.tavernSettingsGeneration,
    footer: Text(defaultPreset == null ? l10n.tavernGenerationNote : l10n.tavernGenerationPresetNote(defaultName)),
    children: [
      SettingsTile(
        key: const ValueKey('tavern-default-preset'),
        icon: AppIcons.article,
        title: l10n.tavernDefaultPreset,
        value: _ValueText(defaultName),
        onTap: () => unawaited(showTavernDefaultPresetPicker(context)),
      ),
      if (defaultPreset != null)
        SettingsTile(
          key: const ValueKey('tavern-default-preset-edit'),
          icon: AppIcons.edit,
          title: l10n.tavernGenerationInPreset(defaultName),
          onTap: () => unawaited(Navigator.of(context).push(TavernPresetPage.route(defaultPreset))),
        )
      else ...[
        TavernNumberTile(
          key: const ValueKey('tavern-max-context'),
          icon: AppIcons.tavernContext,
          title: l10n.tavernMaxContext,
          presets: tavernContextSizes,
          presetLabel: tavernContextLabel,
          value: generation.maxContext,
          min: tavernContextRange.min,
          max: tavernContextRange.max,
          integer: true,
          onChanged: (tokens) => unawaited(generate.setMaxContext(tokens.toInt())),
        ),
        TavernNumberTile(
          key: const ValueKey('tavern-max-reply'),
          icon: AppIcons.tavernReplyLength,
          title: l10n.tavernMaxReply,
          presets: tavernReplySizes,
          value: generation.maxReply,
          min: tavernReplyRange.min,
          max: tavernReplyRange.max,
          integer: true,
          onChanged: (tokens) => unawaited(generate.setMaxReply(tokens.toInt())),
        ),
        TavernNumberTile(
          key: const ValueKey('tavern-temperature'),
          icon: AppIcons.tavernTemperature,
          title: l10n.tavernTemperature,
          presets: tavernTemperatures,
          presetLabel: (t) => t.toStringAsFixed(1),
          value: generation.temperature,
          min: tavernTemperatureRange.min,
          max: tavernTemperatureRange.max,
          onChanged: (t) => unawaited(generate.setTemperature(t.toDouble())),
        ),
      ],
      TavernNumberTile(
        key: const ValueKey('tavern-cost-alert'),
        icon: AppIcons.notifications,
        title: l10n.tavernCostAlert,
        subtitle: l10n.tavernCostAlertSubtitle,
        presets: tavernCostAlerts,
        presetLabel: (usd) => usd == 0 ? l10n.tavernCostAlertOff : '\$${usd.toStringAsFixed(2)}',
        label: (usd) => '\$${tavernNumberText(usd)}',
        value: settings.costAlert,
        min: tavernCostAlertRange.min,
        max: tavernCostAlertRange.max,
        onChanged: (usd) => unawaited(controller.setCostAlert(usd.toDouble())),
      ),
    ],
  );
  final display = SettingsSection(
    title: l10n.tavernSettingsDisplay,
    children: [
      SettingsSegmentTile<TavernLayout>(
        key: const ValueKey('tavern-layout'),
        icon: AppIcons.phoneLayout,
        title: l10n.tavernLayout,
        segments: [
          PillSegment(TavernLayout.bubble, l10n.tavernLayoutBubble),
          PillSegment(TavernLayout.novel, l10n.tavernLayoutNovel),
          PillSegment(TavernLayout.visualNovel, l10n.tavernLayoutVisualNovel),
        ],
        selected: settings.layout,
        onChanged: (layout) => unawaited(controller.setLayout(layout)),
      ),
      // How 视觉小说 types out each page.
      SettingsSegmentTile<TavernTextSpeed>(
        key: const ValueKey('tavern-text-speed'),
        icon: AppIcons.textSpeed,
        title: l10n.tavernTextSpeed,
        segments: [
          PillSegment(TavernTextSpeed.slow, l10n.tavernTextSlow),
          PillSegment(TavernTextSpeed.normal, l10n.tavernTextNormal),
          PillSegment(TavernTextSpeed.fast, l10n.tavernTextFast),
          PillSegment(TavernTextSpeed.instant, l10n.tavernTextInstant),
        ],
        selected: settings.textSpeed,
        onChanged: (speed) => unawaited(controller.setTextSpeed(speed)),
      ),
      TavernNumberTile(
        key: const ValueKey('tavern-text-size'),
        icon: AppIcons.selectText,
        title: l10n.tavernTextSize,
        presets: tavernTextSizes,
        presetLabel: (size) => [
          l10n.tavernTextSmall,
          l10n.tavernTextMedium,
          l10n.tavernTextLarge,
          l10n.tavernTextHuge,
        ][tavernTextSizes.indexOf(size.toDouble())],
        value: settings.textSize,
        min: tavernTextSizeRange.min,
        max: tavernTextSizeRange.max,
        onChanged: (size) => unawaited(controller.setTextSize(size.toDouble())),
      ),
      TavernNumberTile(
        key: const ValueKey('tavern-line-height'),
        icon: AppIcons.compact,
        title: l10n.tavernLineHeight,
        presets: tavernLineHeights,
        presetLabel: (height) => [
          l10n.tavernLineTight,
          l10n.tavernLineNormal,
          l10n.tavernLineLoose,
        ][tavernLineHeights.indexOf(height.toDouble())],
        value: settings.lineHeight,
        min: tavernLineHeightRange.min,
        max: tavernLineHeightRange.max,
        onChanged: (height) => unawaited(controller.setLineHeight(height.toDouble())),
      ),
      SettingsSegmentTile<TavernPalette>(
        key: const ValueKey('tavern-palette'),
        icon: AppIcons.theme,
        title: l10n.tavernPalette,
        segments: [
          PillSegment(TavernPalette.plain, l10n.tavernPalettePlain),
          PillSegment(TavernPalette.ember, l10n.tavernPaletteEmber),
          PillSegment(TavernPalette.ocean, l10n.tavernPaletteOcean),
          PillSegment(TavernPalette.rose, l10n.tavernPaletteRose),
          if (stTheme != null) PillSegment(TavernPalette.st, l10n.tavernPaletteSt),
        ],
        // ST with its theme gone reads as 暖, as it is drawn.
        selected: settings.palette == TavernPalette.st && stTheme == null ? TavernPalette.ember : settings.palette,
        onChanged: (palette) => unawaited(controller.setPalette(palette)),
      ),
      // What a reply will look like, right under the rows that shape it.
      Padding(
        key: const ValueKey('tavern-reading-preview'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: TavernReading(child: MarkdownBody(text: l10n.tavernReadingSample, selectable: false)),
      ),
      // The ST theme the colours can come from: taken in through 导入, like
      // every other file; here to see which, or to let it go.
      if (stTheme != null)
        SettingsTile(
          key: const ValueKey('tavern-st-theme'),
          icon: AppIcons.file,
          title: l10n.tavernStTheme(stTheme.name),
          subtitle: l10n.tavernStThemeNote,
          value: TextButton(
            key: const ValueKey('tavern-st-theme-remove'),
            onPressed: () async {
              await ref.read(tavernStThemeProvider.notifier).clear();
              if (settings.palette == TavernPalette.st) await controller.setPalette(TavernPalette.ember);
            },
            child: Text(l10n.tavernStThemeRemove),
          ),
          chevron: false,
        )
      else
        SettingsTile(
          key: const ValueKey('tavern-st-theme-import'),
          icon: AppIcons.file,
          title: l10n.tavernStThemeImport,
          subtitle: l10n.tavernStThemeImportNote,
          onTap: () => unawaited(importTavernFiles(context, ref)),
        ),
      // Its custom CSS goes into the whole-story canvas with ST's colours;
      // one that unsettles the page can be let go, the colours kept.
      if (stTheme?.customCss != null)
        SettingsSwitchTile(
          key: const ValueKey('tavern-st-theme-css'),
          icon: AppIcons.code,
          title: l10n.tavernStThemeCss,
          subtitle: l10n.tavernStThemeCssSubtitle,
          value: stTheme!.useCss,
          onChanged: (on) => unawaited(ref.read(tavernStThemeProvider.notifier).setUseCss(on)),
        ),
    ],
  );
  // What goes into each message: a card of its own, under 显示's.
  final messages = SettingsSection(
    key: const ValueKey('tavern-messages'),
    children: [
      SettingsSwitchTile(
        key: const ValueKey('tavern-show-usage'),
        icon: AppIcons.chart,
        title: l10n.tavernShowUsage,
        subtitle: l10n.tavernShowUsageSubtitle,
        value: settings.showUsage,
        onChanged: (show) => unawaited(controller.setShowUsage(show)),
      ),
      SettingsSwitchTile(
        key: const ValueKey('tavern-card-theme'),
        icon: AppIcons.color,
        title: l10n.tavernCardTheme,
        subtitle: l10n.tavernCardThemeSubtitle,
        value: settings.cardTheme,
        onChanged: (use) => unawaited(controller.setCardTheme(use)),
      ),
      SettingsSwitchTile(
        key: const ValueKey('tavern-novel-indent'),
        icon: AppIcons.textSize,
        title: l10n.tavernNovelIndent,
        subtitle: l10n.tavernNovelIndentSubtitle,
        value: settings.novelIndent,
        onChanged: (indent) => unawaited(controller.setNovelIndent(indent)),
      ),
      SettingsSwitchTile(
        key: const ValueKey('tavern-islands'),
        icon: AppIcons.web,
        title: l10n.tavernIslands,
        subtitle: l10n.tavernIslandsSubtitle,
        value: settings.islands,
        onChanged: (on) => unawaited(controller.setIslands(on)),
      ),
      SettingsSwitchTile(
        key: const ValueKey('tavern-canvas'),
        icon: AppIcons.webApp,
        title: l10n.tavernCanvas,
        subtitle: l10n.tavernCanvasSubtitle,
        value: settings.canvas,
        onChanged: (on) => unawaited(controller.setCanvas(on)),
      ),
    ],
  );
  // Protections the user may choose; off unless they do.
  final safety = SettingsSection(
    key: const ValueKey('tavern-safety'),
    title: l10n.tavernSettingsSafety,
    children: [
      SettingsSwitchTile(
        key: const ValueKey('tavern-island-no-scripts'),
        icon: AppIcons.code,
        title: l10n.tavernIslandNoScripts,
        subtitle: l10n.tavernIslandNoScriptsSubtitle,
        value: settings.islandNoScripts,
        onChanged: (on) => unawaited(controller.setIslandNoScripts(on)),
      ),
      SettingsSwitchTile(
        key: const ValueKey('tavern-island-offline'),
        icon: AppIcons.link,
        title: l10n.tavernIslandOffline,
        subtitle: l10n.tavernIslandOfflineSubtitle,
        value: settings.islandOffline,
        onChanged: (on) => unawaited(controller.setIslandOffline(on)),
      ),
    ],
  );
  final startupGroup = SettingsSection(
    children: [
      SettingsTile(
        key: const ValueKey('tavern-startup'),
        icon: AppIcons.modes,
        title: l10n.modeStartup,
        value: Text(appModeShortLabel(l10n, startup)),
        onTap: () => unawaited(showModeSheet(context, current: AppMode.tavern)),
      ),
    ],
  );
  // The whole tavern in one ZIP, and back (engine T24); and how much room it takes.
  final data = SettingsSection(
    key: const ValueKey('tavern-data'),
    title: l10n.tavernData,
    children: [
      SettingsTile(
        key: const ValueKey('tavern-backup'),
        icon: AppIcons.archive,
        title: l10n.tavernBackup,
        subtitle: l10n.tavernBackupSubtitle,
        onTap: () => unawaited(backupTavern(context, ref)),
      ),
      SettingsTile(
        key: const ValueKey('tavern-restore'),
        icon: AppIcons.history,
        title: l10n.tavernRestore,
        subtitle: l10n.tavernRestoreSubtitle,
        onTap: () => unawaited(restoreTavern(context, ref)),
      ),
      SettingsTile(
        key: const ValueKey('tavern-usage-stats'),
        icon: AppIcons.chart,
        title: l10n.tavernUsageStats,
        subtitle: l10n.tavernUsageStatsSubtitle,
        onTap: () => unawaited(Navigator.of(context).push(TavernUsagePage.route())),
      ),
      SettingsTile(
        key: const ValueKey('tavern-storage'),
        icon: AppIcons.phoneStorage,
        title: l10n.tavernStorage,
        value: Text(switch (storage) {
          AsyncData(:final value) => formatBytes(value.total),
          AsyncError() => '—',
          _ => l10n.tavernStorageCounting,
        }),
        onTap: switch (storage) {
          AsyncData(:final value) => () => unawaited(_showStorage(context, value)),
          _ => null,
        },
      ),
    ],
  );
  return [model, generating, const TavernToolPolicyGroup(), display, messages, safety, data, you, startupGroup];
}

/// What the room goes to, part by part.
Future<void> _showStorage(BuildContext context, TavernStorage storage) => showAppSheet<void>(
  context,
  builder: (sheet) {
    final l10n = sheet.l10n;
    Widget row(String key, IconData icon, String title, int bytes) => SettingsTile(
      key: ValueKey('tavern-storage-$key'),
      icon: icon,
      tinted: false,
      title: title,
      value: Text(formatBytes(bytes)),
      chevron: false,
    );
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar('${l10n.tavernStorage} · ${formatBytes(storage.total)}'),
          SheetGroup(
            margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 8),
            children: [
              row('characters', AppIcons.profile, l10n.tavernStorageCharacters, storage.characters),
              row('chats', AppIcons.chat, l10n.tavernStorageChats, storage.chats),
              row('live2d', AppIcons.pet, l10n.tavernStorageLive2d, storage.live2d),
              row('other', AppIcons.folder, l10n.tavernStorageOther, storage.other),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 4, SheetTitleBar.inset + 12, 16),
            child: Text(
              l10n.tavernStorageNote,
              style: Theme.of(sheet).textTheme.bodySmall
                  ?.copyWith(color: DshColors.of(sheet).textTertiary, height: 1.5),
            ),
          ),
        ],
      ),
    );
  },
);

/// A row's value that may be long (a preset's or a persona's name): one line, cut short
/// where it would push the row's four-character title onto two lines, as it would on a 320 wide
/// phone. What the rest of the row takes: the page's gutters (16 a side), the card's inset (16),
/// the icon and its gap (32 + 12), the gap before the value (12), the chevron with its gap and
/// pad (4 + 20 + 12), the title (4 × 15), and 4 to spare.
class _ValueText extends StatelessWidget {
  const _ValueText(this.text);

  final String text;

  static const _rest = 16 * 2 + 16 + 32 + 12 + 12 + 4 + 20 + 12 + 4 * 15 + 4.0;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: math.max(80, MediaQuery.sizeOf(context).width - _rest)),
    child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
  );
}
