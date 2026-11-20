// 酒馆设置 › 工具 (STAGE1-APP-INTEGRATION §6): whether characters may roll
// dice and keep memories, and whether a memory is asked about first. The
// engine's own scope setting, read back after each change: what is shown is
// what it has, also when a change failed after it was taken.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_preview.dart';
import '../../tavern/tavern_provider.dart';
import '../common/brief_notice.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';

/// The tool scope as the engine has it now (no chat: the global one); none
/// for the preview, which keeps none.
final tavernToolPolicyProvider = FutureProvider.autoDispose.family<TavernToolPolicySnapshot?, String?>((
  ref,
  chatId,
) async {
  final tavern = ref.watch(tavernProvider);
  if (tavern is TavernPreview) return null;
  return tavern.readToolPolicy(chatId: chatId);
}, retry: (_, _) => null);

class TavernToolPolicyGroup extends ConsumerWidget {
  const TavernToolPolicyGroup({super.key});

  /// Sends [patch], says when it was refused, and reads the scope back.
  static Future<void> write(BuildContext context, WidgetRef ref, Map<String, Object?> patch, {String? chatId}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    try {
      await ref.read(tavernProvider).setToolPolicy(patch, chatId: chatId);
    } on TavernToolException catch (e) {
      messenger?.showBriefNotice(l10n.tavernToolPolicyFailed(e.message));
    } finally {
      ref.invalidate(tavernToolPolicyProvider(chatId));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final policy = ref.watch(tavernToolPolicyProvider(null)).value;
    if (policy == null) return const SizedBox.shrink();
    final scope = policy.effectiveScope;
    final roll = scope['rollAllow'] == true;
    final remember = scope['rememberAllow'] == true;
    final mode = scope['rememberMode'] == 'auto' ? 'auto' : 'ask';
    // No mode chosen yet: turning memories on asks first, until the player
    // picks 自动 themselves.
    final rememberRaw = switch (policy.configuredGlobal['raw']) {
      {'remember': final Map<String, Object?> r} => r,
      _ => const <String, Object?>{},
    };
    return SettingsSection(
      key: const ValueKey('tavern-tool-policy'),
      title: l10n.tavernToolPolicy,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          if (policy.diagnostics.isNotEmpty) Text(l10n.tavernToolPolicyDiagnostics),
          Text(l10n.tavernToolPolicyNote),
        ],
      ),
      children: [
        SettingsSwitchTile(
          key: const ValueKey('tavern-tool-roll'),
          icon: AppIcons.tool,
          title: l10n.tavernToolPolicyRoll,
          subtitle: l10n.tavernToolPolicyRollSubtitle,
          value: roll,
          onChanged: (on) => unawaited(
            write(context, ref, {
              'roll': {'allow': on},
            }),
          ),
        ),
        SettingsSwitchTile(
          key: const ValueKey('tavern-tool-remember'),
          icon: AppIcons.bookmark,
          title: l10n.tavernToolPolicyRemember,
          subtitle: l10n.tavernToolPolicyRememberSubtitle,
          value: remember,
          onChanged: (on) => unawaited(
            write(context, ref, {
              'remember': {'allow': on, if (on && !rememberRaw.containsKey('mode')) 'mode': 'ask'},
            }),
          ),
        ),
        if (remember)
          SettingsSegmentTile<String>(
            key: const ValueKey('tavern-tool-remember-mode'),
            // Its own glyph, so its title starts where the switches' do.
            icon: AppIcons.askFirst,
            title: l10n.tavernToolPolicyMode,
            segments: [
              PillSegment('ask', l10n.tavernToolPolicyModeAsk),
              PillSegment('auto', l10n.tavernToolPolicyModeAuto),
            ],
            selected: mode,
            onChanged: (m) => unawaited(
              write(context, ref, {
                'remember': {'mode': m},
              }),
            ),
          ),
      ],
    );
  }
}
