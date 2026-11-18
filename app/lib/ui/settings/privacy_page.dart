// 隐私与分享: what leaves this phone — the links you shared, a configuration
// to share, anonymous usage statistics, and (when the host has it) the chat
// log upload to DeepSeek. On HarmonyOS, while the saved credentials can't be
// read, also the way to clear them.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/credential_recovery.dart';
import '../../state/engine_settings_state.dart';
import '../engine_settings/namespace_copy.dart';
import '../phone/phone_control_screen.dart';
import '../engine_settings/schema_form.dart';
import '../share_code/profile_share_sheet.dart';
import '../share_hosted/hosted_links_tile.dart';
import '../shell/page_frame.dart';
import 'credential_recovery_dialog.dart';
import 'settings_widgets.dart';
import 'usage_stats_section.dart';

class PrivacyPage extends ConsumerWidget {
  const PrivacyPage({super.key});

  static const logNamespace = 'session-log-deepseek';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final engine = ref.watch(engineSettingsProvider).value;
    return AppPage.list(
      title: l10n.hubPrivacy,
      children: [
        SettingsSection(
          title: l10n.hubPrivacySharing,
          children: [
            const HostedLinksSettingsTile(icon: false),
            SettingsTile(spot: Spots.shareConfig, onTap: () => unawaited(showShareProfileSheet(context))),
          ],
        ),
        if (ref.watch(credentialsUnreadableProvider).value ?? false)
          SettingsSection(
            title: l10n.harmonyCredentialsSection,
            children: [
              SettingsTile(
                title: l10n.harmonyCredentialsClear,
                subtitle: l10n.harmonyCredentialsUnreadable,
                danger: true,
                onTap: () => unawaited(confirmCredentialRecovery(context, ref)),
              ),
            ],
          ),
        const UsageStatsSection(),
        SettingsSection(
          title: l10n.phoneLocalOcrTitle,
          footer: Text('${l10n.phoneLocalOcrDisclosure}\n\n${l10n.phoneLocalOcrDetails}'),
          children: [
            ListTile(
              title: Text(l10n.phoneLocalOcrTitle),
              onTap: () => unawaited(Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => const PhoneControlScreen()),
              )),
            ),
          ],
        ),
        if (engine != null && engine.served(logNamespace))
          ...schemaFormGroups([
            SchemaFormSection(
              title: l10n.engineGeneralData,
              fields: [
                SchemaFieldSpec(logNamespace, const ['enabled'], copy: copyOf(logNamespace, const ['enabled'])),
              ],
            ),
          ], settings: engine),
      ],
    );
  }
}
