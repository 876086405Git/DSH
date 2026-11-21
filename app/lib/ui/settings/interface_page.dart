// 界面: which home the app opens to (原生 / 网页), the native start page,
// then everything about the
// web app — opening it once, its phone layout, and the display and sending
// preferences the official General settings keep on the host's engine (only
// the web app reads them; they were 通用设置).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_mode_state.dart';
import '../../state/engine_settings_state.dart';
import '../../state/quick_panel_state.dart';
import '../../state/settings_state.dart';
import '../../state/table_tint_state.dart';
import '../../state/ui_mode_state.dart';
import '../engine_settings/namespace_copy.dart';
import '../modes/mode_switch.dart';
import '../engine_settings/schema_form.dart';
import '../shell/page_frame.dart';
import '../shell/quick_panel.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/dsh_web_launcher.dart';
import 'quick_panel_items_sheet.dart';
import 'settings_widgets.dart';

SchemaFieldSpec _field(String ns, String key) => SchemaFieldSpec(ns, [key], copy: copyOf(ns, [key]));

class InterfacePage extends ConsumerWidget {
  const InterfacePage({super.key});

  /// The web app's settings on the host's engine.
  static const namespaces = ['ui-settings', 'ui-chat', 'ui-conversation'];

  /// The new home takes over from the bottom of the stack (this page closes
  /// with the rest; the way back is the new home).
  static void choose(BuildContext context, WidgetRef ref, UiMode mode) {
    if (mode == ref.read(uiModeProvider).mode) return;
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    unawaited(ref.read(uiModeProvider.notifier).set(mode));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final mode = ref.watch(uiModeProvider.select((s) => s.mode));
    final settings = ref.watch(settingsProvider);
    final tableTint = ref.watch(tableTintProvider);
    final engine = ref.watch(engineSettingsProvider).value;
    final quickPanel = ref.watch(quickPanelProvider);
    final startup = ref.watch(appModeProvider.select((s) => s.startup));
    return AppPage.list(
      title: l10n.hubSettingsInterface,
      children: [
        SettingsSection(
          title: l10n.modeSheetTitle,
          children: [
            SettingsSegmentTile<AppMode>(
              key: const ValueKey('interface-startup-mode'),
              title: l10n.modeStartup,
              segments: [for (final m in AppMode.values) PillSegment(m, appModeShortLabel(l10n, m))],
              selected: startup,
              onChanged: (m) => unawaited(ref.read(appModeProvider.notifier).setStartup(m)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.hubInterfaceHome,
          spot: Spots.uiMode,
          children: [
            for (final m in UiMode.values)
              Semantics(
                checked: m == mode,
                inMutuallyExclusiveGroup: true,
                child: SettingsTile(
                  key: ValueKey('ui-mode-${m.name}'),
                  title: m.label,
                  subtitle: m == UiMode.web ? l10n.hubInterfaceWebHint : null,
                  trailing: SizedBox.square(
                    dimension: 32,
                    child: Icon(m == mode ? AppIcons.radioOn : AppIcons.radioOff, size: 24),
                  ),
                  onTap: () => choose(context, ref, m),
                ),
              ),
          ],
        ),
        SettingsSection(
          title: l10n.hubStartPage,
          children: [
            SettingsSwitchTile(
              spot: Spots.chatSuggestions,
              subtitle: l10n.hubChatSuggestionsHint,
              value: settings.chatSuggestions,
              onChanged: (v) => unawaited(ref.read(settingsProvider.notifier).setChatSuggestions(v)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.commonWeb,
          spot: Spots.webApp,
          children: [
            SettingsTile(
              spot: Spots.openWeb,
              // The active host's DSH Web; in 网页模式 it is the home underneath.
              onTap: () => mode == UiMode.web
                  ? Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst)
                  : openDshWeb(context, ref),
            ),
            SettingsSwitchTile(
              spot: Spots.webPhoneLayout,
              subtitle: l10n.hubSettingsWebPhoneLayoutHint,
              value: settings.webPhoneLayout,
              onChanged: (v) => unawaited(ref.read(settingsProvider.notifier).setWebPhoneLayout(v)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.hubSettingsChat,
          children: [
            SettingsSwitchTile(
              spot: Spots.hardwareEnterSends,
              subtitle: l10n.hubHardwareEnterSendsHint,
              value: settings.hardwareEnterSends,
              onChanged: (v) => unawaited(ref.read(settingsProvider.notifier).setHardwareEnterSends(v)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.hubQuickPanel,
          spot: Spots.quickPanel,
          children: [
            SettingsSwitchTile(
              key: const ValueKey('quick-panel-swipe'),
              title: l10n.hubQuickPanelSwipe,
              subtitle: l10n.hubQuickPanelSwipeHint,
              value: quickPanel.swipe,
              onChanged: (v) => unawaited(ref.read(quickPanelProvider.notifier).setSwipe(v)),
            ),
            SettingsTile(
              key: const ValueKey('quick-panel-items'),
              title: l10n.hubQuickPanelItems,
              subtitle: quickPanel.items.isEmpty
                  ? l10n.hubQuickPanelItemsNone
                  : quickPanel.items.map((d) => d.label(l10n)).join(l10n.shellListSeparator),
              onTap: () => unawaited(showQuickPanelItems(context)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.hubTableTint,
          spot: Spots.tableTint,
          children: [
            for (final tint in TableTint.values)
              Semantics(
                checked: tint == tableTint,
                inMutuallyExclusiveGroup: true,
                child: SettingsTile(
                  key: ValueKey('table-tint-${tint.name}'),
                  title: switch (tint) {
                    TableTint.follow => l10n.hubTableTintFollow,
                    TableTint.fill => l10n.hubTableTintFill,
                    TableTint.none => l10n.hubTableTintNone,
                  },
                  subtitle: switch (tint) {
                    TableTint.follow => l10n.hubTableTintFollowHint,
                    TableTint.fill => l10n.hubTableTintFillHint,
                    TableTint.none => l10n.hubTableTintNoneHint,
                  },
                  // 一眼看出这一档长什么样：缩略图和正文表格同一套配色。
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _TableTintPreview(tint: tint, selected: tint == tableTint),
                      const SizedBox(width: 10),
                      Icon(
                        tint == tableTint ? AppIcons.radioOn : AppIcons.radioOff,
                        size: 24,
                        color: tint == tableTint ? Theme.of(context).colorScheme.primary : null,
                      ),
                    ],
                  ),
                  onTap: () => unawaited(ref.read(tableTintProvider.notifier).set(tint)),
                ),
              ),
          ],
        ),
        // The host's own: only once it has said what it keeps.
        if (engine != null && namespaces.any(engine.served))
          ...schemaFormGroups([
            SchemaFormSection(
              title: l10n.engineGeneralWebDisplay,
              footer: l10n.engineGeneralWebOnlyHint,
              fields: [
                _field('ui-settings', 'enabled'),
                _field('ui-chat', 'transcriptView'),
                _field('ui-chat', 'collapseTiming'),
                _field('ui-chat', 'performanceUsage'),
              ],
            ),
            SchemaFormSection(
              title: l10n.engineGeneralWebSending,
              footer: l10n.engineGeneralWebOnlyHint,
              fields: [_field('ui-conversation', 'busyEnter'), _field('ui-chat', 'linkOpening')],
            ),
          ], settings: engine),
      ],
    );
  }
}

/// 表格底色每档的迷你示意：两列三行，表头一档、隔行一档，和正文表格
/// 用同一套颜色，深浅主题都对得上。
class _TableTintPreview extends StatelessWidget {
  const _TableTintPreview({required this.tint, required this.selected});

  final TableTint tint;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dsh = DshColors.of(context);
    return SizedBox(
      width: 58,
      height: 38,
      child: CustomPaint(
        painter: _TableTintPainter(
          header: tint == TableTint.none ? null : dsh.codeWellHeader,
          stripe: tint == TableTint.fill ? colors.onSurface.withValues(alpha: 0.05) : null,
          line: colors.outlineVariant,
          border: selected ? colors.primary : colors.outlineVariant,
          borderWidth: selected ? 1.4 : 0.8,
        ),
      ),
    );
  }
}

class _TableTintPainter extends CustomPainter {
  const _TableTintPainter({
    required this.header,
    required this.stripe,
    required this.line,
    required this.border,
    required this.borderWidth,
  });

  final Color? header;
  final Color? stripe;
  final Color line;
  final Color border;
  final double borderWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final row = size.height / 3;
    final outline = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(5));

    // 填充和网格都裁进圆角里，和修好之后的正文表格一个规矩。
    canvas.save();
    canvas.clipRRect(outline);
    final fill = Paint();
    if (header != null) {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, row), fill..color = header!);
    }
    if (stripe != null) {
      canvas.drawRect(Rect.fromLTWH(0, row * 2, size.width, row), fill..color = stripe!);
    }
    final grid = Paint()
      ..color = line
      ..strokeWidth = 0.7
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
      Path()
        ..moveTo(size.width / 2, 0)
        ..lineTo(size.width / 2, size.height)
        ..moveTo(0, row)
        ..lineTo(size.width, row)
        ..moveTo(0, row * 2)
        ..lineTo(size.width, row * 2),
      grid,
    );
    canvas.restore();

    canvas.drawRRect(
      outline,
      Paint()
        ..color = border
        ..strokeWidth = borderWidth
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_TableTintPainter old) =>
      old.header != header ||
      old.stripe != stripe ||
      old.line != line ||
      old.border != border ||
      old.borderWidth != borderWidth;
}
