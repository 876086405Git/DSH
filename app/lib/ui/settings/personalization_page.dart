// 个性化: what AI should know about you (个人偏好), how it answers (可视化回复)
// and how it works (Agent 预设). The first two live in this phone's engine,
// so a remote host shows only the presets.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../companion/companion_state.dart' show companionLightClientProvider;
import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../share_code/guest_fs.dart';
import '../../state/engine_control.dart';
import '../../state/hosts_state.dart';
import '../../state/prompt_enhance_local.dart';
import '../../state/settings_state.dart';
import '../features/agent_presets_page.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';
import 'reply_prefs_page.dart';
import 'settings_widgets.dart';

/// Whether 个人偏好 can be read and written here: this phone's engine, with
/// its files at hand.
bool canEditReplyPrefs(WidgetRef ref) =>
    ref.watch(activeHostProvider).isLocal && ref.watch(guestFsProvider).value != null;

/// The first line of 个人偏好, or null when there is none.
String? replyPrefsSummary(WidgetRef ref) {
  final line = ref.watch(replyPrefsProvider).value?.trim().split('\n').first.trim();
  return line == null || line.isEmpty ? null : line;
}

class PersonalizationPage extends ConsumerStatefulWidget {
  const PersonalizationPage({super.key});

  @override
  ConsumerState<PersonalizationPage> createState() => _PersonalizationPageState();
}

class _PersonalizationPageState extends ConsumerState<PersonalizationPage> {
  /// 「测试连接」的在途状态与结果。
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  /// The engine reads its instructions at launch, so the switch takes effect on
  /// the next start; offer one now rather than restarting behind the user's back.
  Future<void> _onVisualReplies(BuildContext context, WidgetRef ref, bool next) async {
    await ref.read(settingsProvider.notifier).setVisualReplies(next);
    if (!context.mounted || ref.read(localRuntimeProvider).status.phase != RuntimePhase.running) return;
    final container = ProviderScope.containerOf(context, listen: false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(context.l10n.hubSettingsRestartRequired),
          persist: false,
          action: SnackBarAction(
            label: context.l10n.hubSettingsRestartNow,
            onPressed: () => unawaited(EngineControl.restart(container)),
          ),
        ),
      );
  }

  /// 「测试连接」：发一次最小请求，确认 key、模型、网络三样都通。
  Future<void> _testConnection() async {
    final settings = ref.read(settingsProvider);
    setState(() {
      _testing = true;
      _testResult = null;
    });
    http.Client? client;
    try {
      client = ref.read(companionLightClientProvider)();
      final reply = await testPromptEnhanceConnection(
        client: client,
        apiKey: settings.apiKey,
        model: settings.promptEnhanceModel,
      );
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = true;
        _testResult = reply.isEmpty
            ? context.l10n.settingsEnhanceTestOk
            : context.l10n.settingsEnhanceTestOkReply(reply);
      });
    } on PromptEnhanceLocalError catch (error) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testResult = switch (error.failure) {
          PromptEnhanceLocalFailure.noKey => context.l10n.settingsEnhanceNoKey,
          PromptEnhanceLocalFailure.badKey => context.l10n.settingsEnhanceBadKey,
          PromptEnhanceLocalFailure.busy => context.l10n.settingsEnhanceBusy,
          PromptEnhanceLocalFailure.network => context.l10n.settingsEnhanceNetwork,
          PromptEnhanceLocalFailure.server => context.l10n.settingsEnhanceServer,
          PromptEnhanceLocalFailure.incomplete => context.l10n.settingsEnhanceIncomplete,
        };
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testResult = context.l10n.settingsEnhanceNetwork;
      });
    } finally {
      client?.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final local = ref.watch(activeHostProvider).isLocal;
    final prefs = canEditReplyPrefs(ref);
    final summary = prefs ? replyPrefsSummary(ref) : null;
    final settings = ref.watch(settingsProvider);
    return AppPage.list(
      title: l10n.hubPersonalization,
      children: [
        if (prefs)
          SettingsSection(
            title: l10n.hubPersonalizationAboutYou,
            children: [
              SettingsTile(
                spot: SettingsIndex.entry(SettingsPageId.replyPrefs),
                subtitle: summary ?? l10n.commonNotSet,
                onTap: () => _push(context, const ReplyPrefsPage()),
              ),
            ],
          ),
        if (local)
          SettingsSection(
            title: l10n.hubPersonalizationReplies,
            children: [
              SettingsSwitchTile(
                spot: Spots.visualReplies,
                subtitle: l10n.hubSettingsVisualRepliesHint,
                value: settings.visualReplies,
                onChanged: (v) => unawaited(_onVisualReplies(context, ref, v)),
              ),
            ],
          ),
        // 提示词增强：手机本地直连模型，本机与远程主机都能用。
        SettingsSection(
          title: l10n.settingsEnhanceTitle,
          children: [
            SettingsTile(
              spot: null,
              title: l10n.settingsEnhanceModel,
              subtitle: settings.promptEnhanceModel,
              trailing: Icon(Icons.chevron_right, color: DshColors.of(context).textTertiary),
              onTap: () => _pickModel(context, ref),
            ),
            SettingsTile(
              spot: null,
              title: l10n.settingsEnhanceTest,
              subtitle: _testing
                  ? l10n.settingsEnhanceTesting
                  : (_testResult ?? l10n.settingsEnhanceTestHint),
              onTap: _testing ? null : () => unawaited(_testConnection()),
            ),
            if (_testResult case final result?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  result,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: _testOk ? DshColors.of(context).success : DshColors.of(context).danger,
                  ),
                ),
              ),
          ],
        ),
        SettingsSection(
          title: l10n.hubPersonalizationWorkStyle,
          children: [
            SettingsTile(
              spot: SettingsIndex.entry(SettingsPageId.agentPresets),
              onTap: () => _push(context, const AgentPresetsPage()),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickModel(BuildContext context, WidgetRef ref) async {
    final current = ref.read(settingsProvider).promptEnhanceModel;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final model in promptEnhanceModels)
              ListTile(
                title: Text(model),
                trailing: model == current
                    ? Icon(Icons.check, color: DshColors.of(sheetContext).success)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(model),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == current) return;
    await ref.read(settingsProvider.notifier).setPromptEnhanceModel(picked);
    if (mounted) setState(() => _testResult = null);
  }
}
