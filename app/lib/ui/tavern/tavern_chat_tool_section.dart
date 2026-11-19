// 舞台 › 会话 › 这局的工具 (STAGE1-APP-INTEGRATION §6): the chat's own say on
// dice and memories, over 酒馆设置 › 工具. Each follows the settings, or is on
// or off here; what the chat ends up with is shown as the engine works it
// out, since a chat cannot turn on what the settings turned off.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../settings/settings_widgets.dart';
import 'tavern_tool_policy_group.dart';

/// A chat leaf (roll.enabled, remember.enabled, remember.mode) as a segment:
/// absent, null or not understood follows the settings.
String _leaf(Object? raw, String tool, String key) {
  final value = raw is Map && raw[tool] is Map ? (raw[tool] as Map)[key] : null;
  return switch (value) {
    true => 'on',
    false => 'off',
    'ask' || 'auto' => value! as String,
    _ => 'follow',
  };
}

Object? _value(String segment) => switch (segment) {
  'on' => true,
  'off' => false,
  'follow' => null,
  _ => segment,
};

class TavernChatToolSection extends ConsumerWidget {
  const TavernChatToolSection({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final policy = ref.watch(tavernToolPolicyProvider(chatId)).value;
    // The preview keeps no tools.
    if (policy == null) return const SizedBox.shrink();
    final raw = policy.configuredChat?['raw'];
    final roll = _leaf(raw, 'roll', 'enabled');
    final remember = _leaf(raw, 'remember', 'enabled');
    final mode = _leaf(raw, 'remember', 'mode');
    final scope = policy.effectiveScope;
    final rolls = scope['rollAllow'] == true;
    final remembers = scope['rememberAllow'] == true;
    final auto = scope['rememberMode'] == 'auto';
    // On here, off in the settings: on here does not count.
    final held = (roll == 'on' && !rolls) || (remember == 'on' && !remembers);
    void write(String tool, String key, String segment) => unawaited(
      TavernToolPolicyGroup.write(context, ref, {
        tool: {key: _value(segment)},
      }, chatId: chatId),
    );
    final three = [
      PillSegment('follow', l10n.tavernChatToolFollow),
      PillSegment('on', l10n.tavernChatToolOn),
      PillSegment('off', l10n.tavernChatToolOff),
    ];
    return SettingsSection(
      key: const ValueKey('tavern-chat-tools'),
      title: l10n.tavernChatTools,
      margin: const EdgeInsets.only(bottom: 12),
      // What the chat ends up with, under the card as every settings note is.
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          Text(
            l10n.tavernChatToolNow(
              rolls ? l10n.tavernChatToolOn : l10n.tavernChatToolOff,
              !remembers
                  ? l10n.tavernChatToolOff
                  : auto
                  ? l10n.tavernToolPolicyModeAuto
                  : l10n.tavernToolPolicyModeAsk,
            ),
            key: const ValueKey('tavern-chat-tool-now'),
          ),
          if (held) Text(l10n.tavernChatToolHeld, key: const ValueKey('tavern-chat-tool-held')),
          if (policy.diagnostics.isNotEmpty) Text(l10n.tavernToolPolicyDiagnostics),
        ],
      ),
      children: [
        SettingsSegmentTile<String>(
          key: const ValueKey('tavern-chat-tool-roll'),
          title: l10n.tavernToolPolicyRoll,
          tinted: false,
          segments: three,
          selected: roll,
          onChanged: (s) => write('roll', 'enabled', s),
        ),
        SettingsSegmentTile<String>(
          key: const ValueKey('tavern-chat-tool-remember'),
          title: l10n.tavernToolPolicyRemember,
          tinted: false,
          segments: three,
          selected: remember,
          onChanged: (s) => write('remember', 'enabled', s),
        ),
        if (remembers || mode != 'follow')
          SettingsSegmentTile<String>(
            key: const ValueKey('tavern-chat-tool-mode'),
            title: l10n.tavernToolPolicyMode,
            tinted: false,
            segments: [
              PillSegment('follow', l10n.tavernChatToolFollow),
              PillSegment('ask', l10n.tavernToolPolicyModeAsk),
              PillSegment('auto', l10n.tavernToolPolicyModeAuto),
            ],
            selected: mode,
            onChanged: (s) => write('remember', 'mode', s),
          ),
      ],
    );
  }
}
