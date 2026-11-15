import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/local_footprint.dart';
import '../../runtime/runtime_state.dart';
import '../../state/account_state.dart';
import '../../state/android_features.dart';
import '../../state/ask_ai.dart' show askAiAvailableProvider;
import '../../state/balance_state.dart';
import '../../state/connection_state.dart';
import '../../state/engine_settings_state.dart';
import '../../state/features_state.dart';
import '../../state/hosts_state.dart';
import '../../state/phone_state.dart';
import '../../state/plugins_state.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/ui_mode_state.dart';
import '../../state/update_state.dart';
import '../account/account_page.dart';
import '../account/account_widgets.dart';
import '../chat/balance_widgets.dart' show formatMoney;
import '../common/ask_ai.dart';
import '../common/overview_card.dart';
import '../common/search_capsule.dart';
import '../common/status_chip.dart';
import '../engine/engine_screen.dart';
import '../engine/engine_status.dart';
import '../engine_settings/engine_settings_hub.dart';
import '../engine_settings/web_search_page.dart';
import 'media_settings_page.dart';
import '../features/feature_catalog.dart' show communityPage;
import '../features/feature_format.dart' show permissionName;
import '../features/permission_page.dart';
import '../onboarding/api_key_page.dart' show maskApiKey;
import '../pets/pet_settings_page.dart';
import '../phone/phone_control_screen.dart';
import '../plugins/plugins_screen.dart';
import '../plugins/seats/plugin_settings_tiles.dart';
import '../plugins/seats/seat_probe.dart';
import '../providers/providers_page.dart';
import '../remote/host_status.dart';
import '../remote/remote_screen.dart';
import '../shell/brand_mark.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../update/update_tiles.dart' show UpdateBadge;
import 'about_page.dart';
import 'appearance/appearance_page.dart';
import 'background_guide_page.dart';
import 'diagnostics_page.dart';
import 'interface_page.dart';
import 'language_tile.dart';
import 'notification_settings.dart';
import 'performance_page.dart';
import 'personalization_page.dart';
import 'privacy_page.dart';
import 'search/settings_search_page.dart';
import 'settings_widgets.dart';
import 'system_access_page.dart';
import 'voice_settings_page.dart';

/// One hue per group on the hub: rows of a group share it.
abstract final class SettingsHues {
  static const ai = 0;
  static const abilities = 4;
  static const appearance = 1;
  static const general = 5;
  static const hosts = 6;
  static const help = 7;
}

/// Settings hub: search, the overview card (account, balance, engine), then
/// six groups by what people come to do — AI, 能力, 外观, 通用, 主机, 帮助与
/// 关于 (docs/design/settings-ia.md §4.2). Every row that opens a page says
/// where it stands; nothing here loosens a safeguard or deletes anything:
/// those live on their own pages.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider);
    final runtime = ref.watch(localRuntimeProvider);
    final engine = EngineStatusView.of(runtime);
    final colors = DshColors.of(context);
    final notifier = ref.read(settingsProvider.notifier);
    final android = ref.watch(androidSystemFeaturesProvider);
    final ios = ref.watch(operatingSystemProvider) == 'ios';
    final uiMode = ref.watch(uiModeProvider.select((s) => s.mode));
    final host = ref.watch(activeHostProvider);
    Widget? text(String? value, {Color? color}) =>
        value == null ? null : Text(value, style: color == null ? null : TextStyle(color: color));

    // AI.
    final permission = _permissionValue(ref);
    final prefs = canEditReplyPrefs(ref)
        ? (replyPrefsSummary(ref) == null ? l10n.commonNotSet : l10n.hubValueSet)
        : null;
    // 能力.
    final phone = android || ios ? ref.watch(phoneProvider) : null;
    final phoneValue = phone == null || !phone.loaded || !phone.status.ready
        ? null
        : !phone.status.enabled
        ? l10n.hubValueOff
        : (ios ? phone.status.bridgeListening : phone.status.a11y.ok)
        ? l10n.pluginsTurnedOn
        : l10n.hubValueOneStep;
    final plugins = ref.watch(installedPluginsProvider.select((s) => s.value?.length));
    // Read only once the host's settings are at hand: the hub asks for nothing.
    final search = ref.exists(engineSettingsProvider) ? ref.watch(engineSettingsProvider).value : null;
    final newApi = search == null
        ? null
        : search.valueOf(const FieldRef(WebSearchSettingsPage.webNs, ['searchProvider'])) == 'deepseek-search-api';
    // 通用. HarmonyOS has no battery exemption to report.
    final exempt = android ? ref.watch(batteryExemptProvider).value : null;
    // 主机.
    final ssh = ref.watch(hostsProvider.select((s) => s.ssh.length));
    final hostName = host.isLocal ? l10n.commonThisPhone : ref.watch(hostNameProvider(host)) ?? l10n.commonRemoteHost;
    // 帮助与关于.
    final update = ref.watch(appUpdateProvider);
    final newVersion = update.hasUpdate && !update.isSkipped;

    final page = AppPage.list(
      title: l10n.commonSettings,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SearchCapsuleButton(
            key: const ValueKey('settings-search'),
            hint: l10n.searchSettingsHint,
            onTap: () => Navigator.of(context).push(SettingsSearchPage.route()),
          ),
        ),
        const SettingsOverview(),
        SettingsSection(
          title: l10n.hubGroupAi,
          children: [
            SettingsTile(
              icon: AppIcons.providers,
              tint: SettingsHues.ai,
              spot: SettingsIndex.entry(SettingsPageId.models),
              onTap: () => _push(context, const ProvidersPage()),
            ),
            SettingsTile(
              icon: AppIcons.permissions,
              tint: SettingsHues.ai,
              spot: SettingsIndex.entry(SettingsPageId.permission),
              value: text(permission?.$1, color: permission?.$2 == true ? colors.warning : null),
              onTap: () => _push(context, PermissionPage(sessionId: ref.read(currentSessionProvider))),
            ),
            SettingsTile(
              icon: AppIcons.profile,
              tint: SettingsHues.ai,
              spot: SettingsIndex.entry(SettingsPageId.personalization),
              value: text(prefs),
              onTap: () => _push(context, const PersonalizationPage()),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.hubGroupCapabilities,
          children: [
            if (android || ios)
              SettingsTile(
                icon: AppIcons.phoneControl,
                tint: SettingsHues.abilities,
                spot: SettingsIndex.entry(SettingsPageId.phone),
                value: text(phoneValue, color: phoneValue == l10n.hubValueOneStep ? colors.warning : null),
                onTap: () => _push(context, const PhoneControlScreen()),
              ),
            SettingsTile(
              icon: AppIcons.webSearch,
              tint: SettingsHues.abilities,
              spot: SettingsIndex.entry(SettingsPageId.webSearch),
              value: text(newApi == null ? null : (newApi ? l10n.engineSearchNewApiBadge : l10n.commonDefault)),
              onTap: () => _push(context, const WebSearchSettingsPage()),
            ),
            SettingsTile(
              icon: AppIcons.generateMedia,
              tint: SettingsHues.abilities,
              spot: SettingsIndex.entry(SettingsPageId.media),
              onTap: () => _push(context, const MediaSettingsPage()),
            ),
            SettingsTile(
              icon: AppIcons.plugin,
              tint: SettingsHues.abilities,
              spot: SettingsIndex.entry(SettingsPageId.plugins),
              value: plugins == null || plugins == 0
                  ? null
                  : Text(
                      l10n.hubValuePlugins(plugins),
                      style: AppType.tabular(Theme.of(context).textTheme.bodyMedium!),
                    ),
              onTap: () => _push(context, const PluginsScreen()),
            ),
            // The plugins' own settings sections, when the host has any.
            ...pluginSettingsTiles(ref, tint: SettingsHues.abilities),
          ],
        ),
        SettingsSection(
          title: l10n.hubSettingsAppearance,
          children: [
            const AppearanceEntryTile(tint: SettingsHues.appearance),
            SettingsSegmentTile<double>(
              icon: AppIcons.textSize,
              tint: SettingsHues.appearance,
              spot: Spots.chatTextSize,
              segments: [for (final (scale, label) in chatTextScales) PillSegment(scale, label)],
              selected: settings.chatTextScale,
              onChanged: (scale) => unawaited(notifier.setChatTextScale(scale)),
            ),
            SettingsSwitchTile(
              icon: AppIcons.foldTurns,
              tint: SettingsHues.appearance,
              spot: Spots.foldTurns,
              value: settings.foldCompletedTurns,
              onChanged: (v) => unawaited(notifier.setFoldCompletedTurns(v)),
            ),
            const PetEntryTile(tint: SettingsHues.appearance),
          ],
        ),
        SettingsSection(
          title: l10n.hubGroupGeneral,
          children: [
            SettingsTile(
              icon: AppIcons.swap,
              tint: SettingsHues.general,
              spot: SettingsIndex.entry(SettingsPageId.interface),
              value: Text(uiMode.label),
              onTap: () => _push(context, const InterfacePage()),
            ),
            const LanguageSettingsTile(tint: SettingsHues.general),
            const NotificationSettingsTile(tint: SettingsHues.general),
            const VoiceSettingsTile(tint: SettingsHues.general),
            const PerformanceSettingsTile(tint: SettingsHues.general),
            SettingsTile(
              icon: AppIcons.keepAlive,
              tint: SettingsHues.general,
              spot: SettingsIndex.entry(SettingsPageId.background),
              value: text(
                exempt == null ? null : (exempt ? l10n.hubValueAllowed : l10n.hubValueNeedsSetup),
                color: exempt == false ? colors.warning : null,
              ),
              onTap: () => _push(context, const BackgroundGuidePage()),
            ),
            SettingsTile(
              icon: AppIcons.systemAccess,
              tint: SettingsHues.general,
              spot: SettingsIndex.entry(SettingsPageId.systemAccess),
              onTap: () => _push(context, const SystemAccessPage()),
            ),
            SettingsTile(
              icon: AppIcons.privacy,
              tint: SettingsHues.general,
              spot: SettingsIndex.entry(SettingsPageId.privacy),
              onTap: () => _push(context, const PrivacyPage()),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.hubGroupHosts,
          children: [
            SettingsTile(
              icon: AppIcons.engine,
              tint: SettingsHues.hosts,
              spot: SettingsIndex.entry(SettingsPageId.engine),
              value: StatusChip(tone: engine.tone, label: engine.label),
              onTap: () => _push(context, const EngineScreen()),
            ),
            SettingsTile(
              icon: AppIcons.remoteHosts,
              tint: SettingsHues.hosts,
              spot: SettingsIndex.entry(SettingsPageId.remote),
              value: ssh == 0 ? null : Text(l10n.hubValueHosts(ssh)),
              onTap: () => _push(context, const RemoteScreen()),
            ),
            SettingsTile(
              icon: AppIcons.configure,
              tint: SettingsHues.hosts,
              spot: SettingsIndex.entry(SettingsPageId.engineParams),
              value: Text(hostName),
              onTap: () => _push(context, const EngineSettingsHubPage()),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.hubGroupHelp,
          children: [
            if (ref.watch(askAiAvailableProvider))
              SettingsTile(
                key: const ValueKey('settings-ask-ai'),
                icon: AppIcons.askAi,
                tint: SettingsHues.help,
                spot: Spots.askAi,
                value: Text(l10n.askAiTooltip),
                onTap: () => unawaited(askAi(context, AskAiTopic.overview)),
              ),
            SettingsTile(
              icon: AppIcons.community,
              tint: SettingsHues.help,
              spot: Spots.community,
              onTap: () => _push(context, communityPage()),
            ),
            SettingsTile(
              icon: AppIcons.diagnostics,
              tint: SettingsHues.help,
              spot: SettingsIndex.entry(SettingsPageId.diagnostics),
              onTap: () => _push(context, const DiagnosticsPage()),
            ),
            SettingsTile(
              icon: AppIcons.info,
              tint: SettingsHues.help,
              spot: SettingsIndex.entry(SettingsPageId.about),
              value: newVersion
                  ? UpdateBadge(l10n.hubAboutNewVersion)
                  : Text(update.current.name, style: AppType.tabular(Theme.of(context).textTheme.bodyMedium!)),
              onTap: () => _push(context, const AboutPage()),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Center(child: BrandMark(size: 18, color: colors.textDisabled)),
        ),
      ],
    );
    // Reads which plugins sit where when the engine hasn't said yet; outside
    // the list, so it is built at once and never part of its layout.
    return Stack(
      fit: StackFit.expand,
      children: [
        page,
        const Positioned(left: 0, top: 0, child: SeatProbe()),
      ],
    );
  }

  /// 权限's value: the default for new conversations, and whether it is one
  /// that stops asking (shown in the warning colour).
  (String, bool)? _permissionValue(WidgetRef ref) {
    final local = ref.watch(activeHostProvider).isLocal;
    final auto = ref.watch(settingsProvider.select((s) => s.autoApproveCommands));
    final safe = ref.watch(localRuntimeProvider.select((s) => s.status.inSafeMode));
    // On the phone, 完全权限 for new conversations is the app's own switch.
    if (local && auto && !safe) return (permissionName('danger-full-access'), true);
    if (ref.watch(activeConnectionProvider).value == null) return null;
    final state = ref.watch(permissionStateProvider(null)).value;
    final value = state?.hostDefault;
    if (state == null || value == null || state.invalidDefault) return null;
    final name = state.options.where((o) => o.value == value).firstOrNull?.name;
    return (permissionName(value, name), value == 'danger-full-access' || value == 'auto');
  }
}

/// The hub's overview card: who is paying (DeepSeek account or API Key) and
/// the balance, with the engine's state underneath. The card opens 账号, the
/// engine line opens 引擎. With no runtime on this phone and a remote host in
/// use there is nothing here to sign in to: the card shows that host and
/// opens 远程主机.
class SettingsOverview extends ConsumerStatefulWidget {
  const SettingsOverview({super.key});

  @override
  ConsumerState<SettingsOverview> createState() => _SettingsOverviewState();
}

class _SettingsOverviewState extends ConsumerState<SettingsOverview> {
  @override
  void initState() {
    super.initState();
    // Opening settings counts as "open": refresh the balance (throttled).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(balanceProvider.notifier).refresh();
    });
  }

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final account = ref.watch(accountProvider);
    final settings = ref.watch(settingsProvider);
    final balance = ref.watch(balanceProvider);
    final wallets = ref.watch(accountWalletBalanceProvider);
    final runtime = ref.watch(localRuntimeProvider);
    final engine = EngineStatusView.of(runtime);
    final colors = DshColors.of(context);
    final active = ref.watch(activeHostProvider);
    final remoteOnly = runtime.status.runtimeMissing && !active.isLocal;

    // The account's wallets when signed in; otherwise the key's balance.
    final money = account.signedIn && wallets != null ? balanceFromAccount(wallets) : balance.balance;
    final low = !account.signedIn && balance.isLow;
    final balanceLine = money == null
        ? null
        : low
        ? l10n.hubSettingsBalanceLow(formatMoney(money))
        : l10n.hubSettingsBalance(formatMoney(money));

    final Widget leading;
    final String title;
    final String subtitle;
    var warn = false;
    var mono = false;
    // Set when the card shows the remote host: its link state.
    String? hostLink;
    switch (account.phase) {
      case AccountPhase.signedIn:
        leading = AccountAvatar(profile: account.profile, size: OverviewCard.avatarSize);
        title = account.profile?.displayName ?? l10n.hubSettingsAccount;
        subtitle = balanceLine ?? account.profile?.contact ?? l10n.commonSignedIn;
      case AccountPhase.signingIn:
        leading = const OverviewGlyph(AppIcons.apiKey);
        title = l10n.hubSettingsAccount;
        subtitle = l10n.hubSettingsSigningIn;
      case _ when remoteOnly:
        final link = HostStatusView.ofLink(ref.watch(hostLinkStatusProvider(active)).value ?? HostLinkStatus.idle);
        leading = OverviewGlyph(hostKindIcon(active.kind), tint: hostKindTint(active.kind));
        title = ref.watch(hostNameProvider(active)) ?? l10n.commonRemoteHost;
        subtitle = [l10n.commonRemoteHost, link.label].join(' · ');
        warn = link.tone == StatusTone.error || link.tone == StatusTone.warn;
        hostLink = link.label;
      case _ when settings.hasApiKey:
        leading = const OverviewGlyph(AppIcons.apiKey);
        title = l10n.hubSettingsApiKey;
        if (balance.status == BalanceStatus.invalidKey) {
          subtitle = l10n.hubSettingsInvalidKey;
          warn = true;
        } else {
          subtitle = balanceLine ?? maskApiKey(settings.apiKey);
          mono = balanceLine == null;
          warn = low;
        }
      case AccountPhase.unsupported:
        leading = const OverviewGlyph(AppIcons.apiKey);
        title = l10n.hubSettingsNoApiKey;
        subtitle = l10n.hubSettingsApiKeyHint;
      case AccountPhase.signedOut || AccountPhase.unknown:
        leading = const OverviewGlyph(AppIcons.apiKey);
        title = l10n.hubSettingsSignInAccount;
        subtitle = l10n.hubSettingsOrApiKey;
    }
    final dsh = runtime.status.dshVersion;
    // The card is 账号's way in (its title is whoever is signed in).
    return SpotAnchor(
      spot: SettingsIndex.entry(SettingsPageId.account),
      child: OverviewCard(
        leading: leading,
        title: Text(title),
        subtitle: Text(
          subtitle,
          style: mono
              ? AppType.monoLabel(color: Theme.of(context).colorScheme.onSurfaceVariant).copyWith(fontSize: 13)
              : warn
              ? TextStyle(color: colors.warning)
              : null,
        ),
        semanticLabel: hostLink != null
            ? l10n.hubSettingsHostSemantics(title, hostLink)
            : l10n.hubSettingsAccountSemantics(title, subtitle),
        onTap: () => _push(hostLink != null ? const RemoteScreen() : const AccountPage()),
        footer: OverviewFooter(
          tone: engine.tone,
          text: [l10n.hubSettingsEngine, engine.label, if (dsh != null) 'DSH $dsh'].join(' · '),
        ),
        onFooterTap: () => _push(const EngineScreen()),
      ),
    );
  }
}
