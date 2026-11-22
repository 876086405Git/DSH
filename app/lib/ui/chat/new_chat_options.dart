// The new conversation's options on the empty state: the agent preset it
// starts with, its permissions and the drawer folder it is filed in. One light
// row under the workspace chip; each item opens a short sheet. (The model is
// the header's model chip.) Preset and permission picks are held in
// pendingNewChatModesProvider and applied when the first message creates the
// session (chat_screen.dart `_ensureSession`), before the prompt.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../state/connection_state.dart';
import '../../state/features_state.dart';
import '../../state/models_state.dart' show modelSelectionScopeProvider;
import '../../state/new_chat_modes.dart';
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../../state/settings_state.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_format.dart';
import '../features/permission_page.dart' show confirmPermission;
import '../theme/app_icons.dart';
import '../theme/theme.dart' show DshThemeStyle, ThemeEmptyLayout;
import 'empty_actions.dart';

/// The longest a single option may grow before its label is cut.
const _itemMaxWidth = 200.0;

/// Presets a new chat can start with, in the Host's order.
List<AgentPresetInfo> newChatPresets(List<AgentPresetInfo>? all) => [
  for (final preset in all ?? const <AgentPresetInfo>[])
    if (!hiddenNewChatPresets.contains(preset.id)) preset,
];

/// The Host's default preset among [presets] (the first when none is marked,
/// or when the marked one is hidden from new chats).
AgentPresetInfo? defaultPreset(List<AgentPresetInfo> presets) {
  for (final preset in presets) {
    if (preset.isDefault) return preset;
  }
  return presets.isEmpty ? null : presets.first;
}

/// The preset to apply to a new session for [picked] (null: the offered
/// default), given the Host's whole list [all]. A pick the Host no longer
/// offers falls back to the default, as its chip already shows. When the
/// Host's own default is a hidden preset, the offered default is applied
/// explicitly: the session would otherwise start in the hidden one. Null
/// keeps the Host default.
String? newChatPresetToApply(List<AgentPresetInfo>? all, String? picked) {
  if (all == null) return picked;
  final presets = newChatPresets(all);
  if (picked != null && presets.any((p) => p.id == picked && p.broken == null)) return picked;
  final hiddenDefault = all.any((p) => p.isDefault && hiddenNewChatPresets.contains(p.id));
  final fallback = defaultPreset(presets);
  return hiddenDefault && fallback != null && fallback.broken == null ? fallback.id : null;
}

/// The permission to apply to a new session for [picked]: null (keep the
/// effective default) when nothing is picked or the Host no longer offers it.
String? newChatPermissionToApply(PermissionState? state, String? picked) {
  if (picked == null || state == null) return picked;
  return state.options.any((o) => o.value == picked) ? picked : null;
}

IconData presetIcon(String id) => switch (id) {
  'standard' => AppIcons.presetStandard,
  'ptc' => AppIcons.presetPtc,
  'minimal' => AppIcons.presetMinimal,
  'cordis' => AppIcons.presetCordis,
  _ => AppIcons.configure,
};

/// The permission a new session gets without a pick: on this device with
/// 自动批准命令 on (and outside safe mode) session creation switches to full
/// access (sessions_state.dart `createForConnection`); elsewhere the Host's
/// default for new sessions.
String effectiveNewChatPermission(
  PermissionState state, {
  required bool local,
  required bool autoApprove,
  required bool safeMode,
}) => local && autoApprove && !safeMode ? 'danger-full-access' : state.hostDefault;

/// [effectiveNewChatPermission] for this screen, read once (callbacks).
String _readEffectivePermission(WidgetRef ref, PermissionState state) => effectiveNewChatPermission(
  state,
  local: ref.read(activeConnectionProvider).value?.isLocal ?? false,
  autoApprove: ref.read(settingsProvider).autoApproveCommands,
  safeMode: ref.read(localRuntimeProvider).status.inSafeMode,
);

/// The options row: the agent preset, the permissions and (with folders) the
/// drawer folder this new chat starts with — light items in one centred line.
/// The preset and permission items appear once the Host has said what it
/// offers, and only when there is a real choice.
class NewChatOptions extends ConsumerWidget {
  const NewChatOptions({super.key, this.folderLabel, this.onFolder});

  /// The drawer-folder item, when there are folders.
  final String? folderLabel;
  final VoidCallback? onFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final pending = ref.watch(pendingNewChatModesProvider);

    final presets = newChatPresets(ref.watch(agentPresetsProvider).value);
    final fallbackPreset = defaultPreset(presets);
    AgentPresetInfo? shownPreset = fallbackPreset;
    for (final preset in presets) {
      if (preset.id == pending.preset && preset.broken == null) shownPreset = preset;
    }

    final permissions = ref.watch(permissionStateProvider(null)).value;
    final hasPermissions = permissions != null && permissions.options.isNotEmpty;
    final local = ref.watch(activeConnectionProvider.select((c) => c.value?.isLocal ?? false));
    final autoApprove = ref.watch(settingsProvider.select((s) => s.autoApproveCommands));
    final safeMode = ref.watch(localRuntimeProvider.select((s) => s.status.inSafeMode));
    final permission = hasPermissions
        ? pending.permission ??
              effectiveNewChatPermission(permissions, local: local, autoApprove: autoApprove, safeMode: safeMode)
        : null;
    String? permissionLabel;
    if (permissions != null && permission != null) {
      String? hostName;
      for (final option in permissions.options) {
        if (option.value == permission) hostName = option.name;
      }
      permissionLabel = permissionName(permission, hostName);
    }

    Widget item(Key key, IconData icon, String label, String name, VoidCallback onTap) => ConstrainedBox(
      key: key,
      constraints: const BoxConstraints(maxWidth: _itemMaxWidth),
      child: SetupItem(
        icon: icon,
        label: label,
        semanticsLabel: '$name: $label',
        onTapHint: l10n.viewNewChatChange,
        onTap: onTap,
      ),
    );

    final items = <Widget>[
      if (presets.length > 1 && shownPreset != null)
        item(
          const ValueKey('new-chat-preset'),
          presetIcon(shownPreset.id),
          agentPresetName(shownPreset),
          l10n.featuresAgentPresets,
          () => unawaited(_pickPreset(context, ref)),
        ),
      if (permissionLabel != null)
        item(
          const ValueKey('new-chat-permission'),
          AppIcons.permissions,
          permissionLabel,
          l10n.featuresPermissions,
          () => unawaited(_pickPermission(context, ref)),
        ),
      if (folderLabel != null && onFolder != null)
        item(const ValueKey('new-chat-folder'), AppIcons.folder, folderLabel!, l10n.viewNewChatFolder, onFolder!),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    // The editorial empty state is set left; a centred second line would step off its left line.
    final editorial = DshThemeStyle.of(context).emptyState.layout == ThemeEmptyLayout.editorial;
    return Wrap(alignment: editorial ? WrapAlignment.start : WrapAlignment.center, spacing: 2, children: items);
  }

  /// A pick belongs to the screen it was made on: the same host/connection
  /// and still no session.
  static bool Function() _owner(WidgetRef ref) {
    final scope = ref.read(modelSelectionScopeProvider);
    return () => identical(ref.read(modelSelectionScopeProvider), scope) && ref.read(currentSessionProvider) == null;
  }

  Future<void> _pickPreset(BuildContext context, WidgetRef ref) async {
    final current = _owner(ref);
    final presets = newChatPresets(ref.read(agentPresetsProvider).value);
    final fallback = defaultPreset(presets);
    if (presets.isEmpty || fallback == null) return;
    final selected = ref.read(pendingNewChatModesProvider).preset ?? fallback.id;
    final pick = await showAppSheet<String>(
      context,
      isScrollControlled: true,
      builder: (sheet) => _ChoiceSheet(
        title: sheet.l10n.viewNewChatPresetTitle,
        rows: [
          for (final preset in presets)
            _Choice(
              value: preset.id,
              icon: presetIcon(preset.id),
              title: agentPresetName(preset),
              subtitle: preset.broken != null ? sheet.l10n.viewNewChatUnavailable : agentPresetDescription(preset),
              meta: preset.id == fallback.id ? sheet.l10n.viewNewChatDefault : null,
              enabled: preset.broken == null,
            ),
        ],
        selected: selected,
      ),
    );
    // The options may be gone by now (a session opened): `ref` with them.
    if (pick == null || !context.mounted || !current()) return;
    ref.read(pendingNewChatModesProvider.notifier).selectPreset(pick == fallback.id ? null : pick);
  }

  Future<void> _pickPermission(BuildContext context, WidgetRef ref) async {
    final current = _owner(ref);
    final state = ref.read(permissionStateProvider(null)).value;
    if (state == null || state.options.isEmpty) return;
    final fallback = _readEffectivePermission(ref, state);
    final selected = ref.read(pendingNewChatModesProvider).permission ?? fallback;
    final pick = await showAppSheet<String>(
      context,
      isScrollControlled: true,
      builder: (sheet) => _ChoiceSheet(
        title: sheet.l10n.viewNewChatPermissionTitle,
        rows: [
          for (final option in state.options)
            _Choice(
              value: option.value,
              icon: option.value == 'danger-full-access' || option.value == 'auto'
                  ? AppIcons.securityWarning
                  : AppIcons.permissions,
              title: permissionName(option.value, option.name),
              subtitle: permissionHint(option.value, option.description),
              meta: option.value == fallback ? sheet.l10n.viewNewChatDefault : null,
            ),
        ],
        selected: selected,
      ),
    );
    if (pick == null || pick == selected || !context.mounted || !current()) return;
    // Full access and auto review ask once, as on the 权限 page.
    if (pick != fallback && !await confirmPermission(context, pick)) return;
    if (!context.mounted || !current()) return;
    ref.read(pendingNewChatModesProvider.notifier).selectPermission(pick == fallback ? null : pick);
  }
}

class _Choice {
  const _Choice({
    required this.value,
    required this.icon,
    required this.title,
    this.subtitle,
    this.meta,
    this.enabled = true,
  });

  final String value;
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? meta;
  final bool enabled;
}

/// One short list to pick from: the rows, a check on the selected one.
class _ChoiceSheet extends StatelessWidget {
  const _ChoiceSheet({required this.title, required this.rows, required this.selected});

  final String title;
  final List<_Choice> rows;
  final String selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(title),
              SheetGroup(
                margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                children: [
                  for (final row in rows)
                    ListPageRow(
                      icon: row.icon,
                      title: row.title,
                      subtitle: row.subtitle,
                      subtitleMaxLines: 2,
                      meta: row.meta,
                      trailing: row.value == selected
                          ? Icon(AppIcons.selected, size: 20, color: scheme.primary)
                          : const SizedBox(width: 20),
                      onTap: row.enabled ? () => Navigator.of(context).pop(row.value) : null,
                    ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}
