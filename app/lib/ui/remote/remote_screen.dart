import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/relay/relay_backend.dart';
import '../../runtime/local_footprint.dart';
import '../../runtime/runtime_state.dart';
import '../../state/app_info.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/app_dialog.dart';
import '../common/ask_ai.dart';
import '../common/overview_card.dart';
import '../common/status_chip.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/web_view_page.dart';
import 'host_key_dialog.dart';
import 'host_status.dart';
import 'link_progress.dart';
import 'network_details_sheet.dart';
import 'pairing_page.dart';
import 'relay_credit.dart';
import 'relay_login_sheet.dart';
import 'ssh_host_form.dart';
import 'session_backup_page.dart';
import 'remote_web/remote_web_entry.dart';

/// 远程主机 (a list page): the computers and servers this phone can drive.
///
/// Two ways in, side by side: a DSH Remote account (李国宝's ds-harness-remote,
/// end-to-end encrypted relay, no network setup) and SSH hosts (self-contained:
/// dsh-app starts `dsh web` over SSH and tunnels to it). Picking a host makes
/// it the active one; the chat and the session list follow. The old Remote
/// Web console stays as a small fallback at the bottom.
class RemoteScreen extends ConsumerWidget {
  const RemoteScreen({super.key});

  void _openConsole(BuildContext context) {
    final l10n = context.l10n;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WebViewPage(
          url: Uri.parse(AppInfo.remoteConsole),
          title: l10n.remoteConsole,
          subtitle: 'dsh.r2049.cn',
          allowOpenExternal: true,
          // Android suspends the page in the background and its connection drops.
          reloadAfterBackground: const Duration(seconds: 60),
        ),
      ),
    );
  }

  Future<void> _use(BuildContext context, WidgetRef ref, HostRef host) async {
    final navigator = Navigator.of(context);
    if (ref.read(activeHostProvider) == host) {
      // Tapping the active host after a failure: confirm trust if that was
      // the problem, then connect again.
      final failed = ref.read(hostLinkStatusProvider(host)).value?.phase == HostLinkPhase.failed;
      if (!failed) {
        navigator.maybePop();
        return;
      }
      if (await activateHost(context, ref, host)) {
        ref.read(remoteConnectionProvider(host).notifier).retry();
      }
      return;
    }
    final ok = await activateHost(context, ref, host);
    if (ok && navigator.mounted) navigator.maybePop();
  }

  /// A host added while this phone has nothing to run on (no runtime, first
  /// run) is the one to use: take it at once instead of a second tap.
  Future<void> _addSsh(BuildContext context, WidgetRef ref) async {
    final saved = await Navigator.of(context)
        .push<SshHostConfig>(MaterialPageRoute(builder: (_) => const SshHostFormPage()));
    if (saved == null || !context.mounted) return;
    final nothingHere = ref.read(localRuntimeProvider).status.runtimeMissing;
    if (nothingHere && ref.read(activeHostProvider).isLocal) await _use(context, ref, HostRef.ssh(saved.id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final ssh = ref.watch(hostsProvider.select((s) => s.ssh));
    final active = ref.watch(activeHostProvider);
    final signedIn = ref.watch(relayAccountProvider.select((a) => a.value?.signedIn ?? false));
    void push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return AppPage.list(
      title: l10n.commonRemoteHost,
      subtitle: Text(l10n.remoteHostsIntro),
      actions: const [AskAiButton(AskAiTopic.remote)],
      children: [
        _ActiveCard(active: active),
        _RelaySection(onUse: (h) => _use(context, ref, h)),
        SettingsSection(
          title: l10n.remoteTransferSettings,
          children: [
            SettingsSwitchTile(
              key: const ValueKey('remote-compact-history'),
              spot: Spots.remoteCompactHistory,
              subtitle: l10n.remoteCompactHistoryHint,
              value: ref.watch(remoteCompactHistoryProvider),
              onChanged: (value) => unawaited(ref.read(remoteCompactHistoryProvider.notifier).set(value)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.remoteSshHosts,
          footer: Text(l10n.remoteSshRequirements),
          children: [
            for (final h in ssh)
              _SshRow(
                config: h,
                active: active == HostRef.ssh(h.id),
                onTap: () => _use(context, ref, HostRef.ssh(h.id)),
                onEdit: () => push(SshHostFormPage(existing: h)),
              ),
            SettingsTile(
              icon: AppIcons.add,
              tinted: false,
              spot: Spots.addSshHost,
              subtitle: ssh.isEmpty ? l10n.remoteSshDirect : null,
              onTap: () => unawaited(_addSsh(context, ref)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.remoteOtherMethods,
          children: [
            SettingsTile(
              icon: AppIcons.webConsole,
              tinted: false,
              title: l10n.remoteWebConsole,
              subtitle: l10n.remoteWebConsoleProvider,
              onTap: () => _openConsole(context),
            ),
          ],
        ),
        // Only meaningful once there is a host to come back to.
        if (ssh.isNotEmpty || signedIn)
          SettingsSection(
            title: l10n.remoteStartupSection,
            children: [
              SettingsSwitchTile(
                key: const ValueKey('remote-auto-connect'),
                spot: Spots.remoteAutoConnect,
                subtitle: l10n.remoteAutoConnectOnStartupHint,
                value: ref.watch(remoteAutoConnectProvider),
                onChanged: (value) => unawaited(ref.read(remoteAutoConnectProvider.notifier).set(value)),
              ),
            ],
          ),
        SettingsSection(
          children: [
            SettingsTile(
              icon: AppIcons.save,
              spot: Spots.remoteSessionBackup,
              onTap: () => push(const SessionBackupPage()),
            ),
          ],
        ),
        const RemoteWebEntry(),
      ],
    );
  }
}

/// What the chat is talking to right now (only for a remote host), with live
/// state, the way back to 本机, and the failure with its one fix.
class _ActiveCard extends ConsumerWidget {
  const _ActiveCard({required this.active});

  final HostRef active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    if (active.isLocal) return const SizedBox.shrink();
    final status = ref.watch(hostLinkStatusProvider(active)).value ?? HostLinkStatus.idle;
    final view = HostStatusView.ofLink(status);
    final name = ref.watch(hostNameProvider(active)) ?? l10n.commonRemoteHost;
    final ssh = active.kind == HostKind.ssh ? ref.watch(hostsProvider).sshById(active.id) : null;
    final error = status.error;
    // Errors a retry can't fix go to the host's settings (SSH) or the trust
    // check (relay) instead.
    final needsLogin = active.kind == HostKind.relay && error?.kind == HostLinkErrorKind.notLoggedIn;
    final needsSettings = ssh != null && error != null && !error.retryable;
    final needsTrust =
        active.kind == HostKind.relay &&
        (error?.kind == HostLinkErrorKind.hostKeyMismatch || error?.kind == HostLinkErrorKind.hostKeyUnverified);
    void reconnect() => ref.read(remoteConnectionProvider(active).notifier).retry();
    final failed = status.phase == HostLinkPhase.failed && error != null;
    // No runtime on this phone: 本机 is nowhere to go back to.
    final canGoLocal = ref.watch(localRuntimeProvider.select((s) => !s.status.runtimeMissing));
    return OverviewCard(
      leading: OverviewGlyph(hostKindIcon(active.kind), tint: hostKindTint(active.kind)),
      title: Text(l10n.remoteActiveHost(name)),
      subtitle: InkWell(
        onTap: active.kind == HostKind.relay && status.isConnected
            ? () => showRemoteNetworkDetails(context, active)
            : null,
        child: Row(
          children: [
            AnimatedStatusDot(tone: view.tone, size: 7),
            const SizedBox(width: 6),
            Flexible(
              child: Text(_statusLine(status, view, ssh?.address), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (active.kind == HostKind.relay && status.isConnected) ...[
              const SizedBox(width: 6),
              Tooltip(message: l10n.remoteNetworkDetails, child: const Icon(AppIcons.info, size: 16)),
            ],
          ],
        ),
      ),
      trailing: canGoLocal
          ? _EdgeTextButton(
              label: l10n.remoteSwitchToPhone,
              onPressed: () => ref.read(activeHostProvider.notifier).select(HostRef.local),
            )
          : null,
      footer: failed
          ? Padding(
              padding: const EdgeInsets.only(left: OverviewCard.inset, right: OverviewCard.inset - 12),
              child: LinkErrorBox(
                error: error,
                action: needsLogin
                    ? (
                        l10n.remoteSignInAgain,
                        () async {
                          if (ref.read(relayAccountProvider).value?.user?.provider == 'password') {
                            final backend = ref.read(relayBackendProvider);
                            final signedIn = await showSelfHostedLogin(
                              context,
                              initialServer: ref.read(relayServerProvider) ?? defaultRelayServer,
                            );
                            if (signedIn == true &&
                                context.mounted &&
                                ref.read(activeHostProvider) == active &&
                                identical(backend, ref.read(relayBackendProvider))) {
                              reconnect();
                            }
                            return;
                          }
                          await ref.read(relayAccountProvider.notifier).login();
                          if (context.mounted && (ref.read(relayAccountProvider).value?.signedIn ?? false)) reconnect();
                        },
                      )
                    : needsSettings
                    ? (
                        l10n.remoteHostSettings,
                        () =>
                            Navigator.of(context)
                                .push(MaterialPageRoute<void>(builder: (_) => SshHostFormPage(existing: ssh))),
                      )
                    : needsTrust
                    ? (
                        l10n.remoteHostKeyTrustAgain,
                        () async {
                          if (await activateHost(context, ref, active)) {
                            reconnect();
                          }
                        },
                      )
                    : (active.kind == HostKind.relay ? l10n.remoteReconnect : l10n.commonRetry, reconnect),
              ),
            )
          : null,
    );
  }

  static String _statusLine(HostLinkStatus status, HostStatusView view, String? address) {
    if (status.phase == HostLinkPhase.reconnecting) {
      final why = status.error?.message;
      return why == null ? appL10n.remoteReconnectingEllipsis : appL10n.remoteReconnectReason(why);
    }
    if (status.phase == HostLinkPhase.connected) {
      if (address != null) return appL10n.remoteConnectedSsh(address);
      final path = status.network?.path ?? status.path;
      return path == null ? appL10n.remoteConnectedEncrypted : appL10n.remoteConnectedVia(path.label);
    }
    return view.label;
  }
}

/// Dot + word on the right of a host row.
class _HostState extends StatelessWidget {
  const _HostState(this.view);

  final HostStatusView view;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedStatusDot(tone: view.tone, size: 7),
        const SizedBox(width: 6),
        Text(view.label),
      ],
    );
  }
}

/// A trailing text button whose label ends exactly at the row's 16dp edge.
class _EdgeTextButton extends StatelessWidget {
  const _EdgeTextButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  /// Horizontal padding inside the button.
  static const _pad = 8.0;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      // Row padding (12) + button padding (8) − nudge (4) = 16 to the label.
      offset: const Offset(SettingsMetrics.trailingPad + _pad - SettingsMetrics.inset, 0),
      child: TextButton(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: _pad),
          minimumSize: const Size(0, 40),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

/// A trailing 20dp icon button whose glyph ends at the row's 16dp edge.
class _EdgeIconButton extends StatelessWidget {
  const _EdgeIconButton({required this.icon, required this.tooltip, required this.onPressed, this.nudge = true});

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// False when another trailing button follows it.
  final bool nudge;

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      color: DshColors.of(context).textTertiary,
      icon: icon,
      onPressed: onPressed,
    );
    if (!nudge) return button;
    // Compact box 40, glyph 20: 10 of air; row padding 12 → nudge 6.
    return Transform.translate(
      offset: const Offset(SettingsMetrics.trailingPad + 10 - SettingsMetrics.inset, 0),
      child: button,
    );
  }
}

class _SshRow extends ConsumerWidget {
  const _SshRow({required this.config, required this.active, required this.onTap, required this.onEdit});

  final SshHostConfig config;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final view = active ? watchHostStatus(ref, HostRef.ssh(config.id)) : null;
    return Semantics(
      selected: active,
      inMutuallyExclusiveGroup: true,
      child: SettingsTile(
        icon: hostKindIcon(HostKind.ssh),
        tinted: false,
        title: config.name,
        subtitle: config.address,
        onTap: onTap,
        value: view == null ? null : _HostState(view),
        trailing: _EdgeIconButton(
          icon: const Icon(AppIcons.configure, size: 20),
          tooltip: l10n.commonEdit,
          onPressed: onEdit,
        ),
      ),
    );
  }
}

// ── DSH Remote account ───────────────────────────────────────────────────────

class _RelaySection extends ConsumerWidget {
  const _RelaySection({required this.onUse});

  final ValueChanged<HostRef> onUse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final async = ref.watch(relayAccountProvider);
    final account = async.value ?? const RelayAccountState();
    final active = ref.watch(activeHostProvider);
    final notifier = ref.read(relayAccountProvider.notifier);

    if (!account.signedIn) {
      // Known before the stored sign-in has been read.
      final available = ref.watch(relayBackendProvider).available;
      final server = account.server;
      return SettingsSection(
        title: 'DSH Remote',
        // The credit's link takes taps in the margin below it, so it carries it.
        margin: available ? RelayCredit.sectionMargin : kSettingsGroupMargin,
        footer: available
            ? RelayCredit(server: server.isEmpty || server == 'dsh.r2049.cn' ? null : server)
            : Text(l10n.remoteUnavailable),
        children: [_LoginCard(account: account, available: available, loading: async.isLoading && !async.hasValue)],
      );
    }
    return SettingsSection(
      title: 'DSH Remote',
      footer: account.hostsFailed && account.hosts.isNotEmpty
          ? Text(l10n.remoteErrRefreshHosts, style: TextStyle(color: DshColors.of(context).danger))
          : account.hosts.length > 1
          ? Text(l10n.remoteSwitchWarning)
          : null,
      children: [
        SettingsTile(
          icon: AppIcons.account,
          tinted: false,
          title: account.user!.displayName,
          subtitle: [if (account.user!.provider case final p?) _providerName(p), account.server].join(' · '),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _EdgeIconButton(
                tooltip: l10n.remoteRefreshHosts,
                nudge: false,
                onPressed: account.refreshing ? null : () => unawaited(notifier.refresh()),
                icon: account.refreshing
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(AppIcons.refresh, size: 20),
              ),
              _EdgeTextButton(label: l10n.remoteSignOut, onPressed: () => _confirmLogout(context, notifier)),
            ],
          ),
        ),
        if (account.hosts.isEmpty && account.hostsFailed)
          SettingsTile(
            icon: AppIcons.refresh,
            tinted: false,
            title: l10n.remoteErrHostsRetry,
            onTap: () => unawaited(notifier.refresh()),
          )
        else if (account.hosts.isEmpty)
          SettingsTile(
            icon: AppIcons.computer,
            tinted: false,
            title: l10n.remoteNoHosts,
            subtitle: l10n.remoteRelaySetupHelp,
          )
        else
          for (final h in account.hosts)
            _RelayRow(
              host: h,
              active: active == HostRef.relay(h.id),
              onTap: h.online || active == HostRef.relay(h.id) ? () => onUse(HostRef.relay(h.id, name: h.name)) : null,
            ),
        if (ref.watch(relayPairingSupportProvider).value ?? false)
          SettingsTile(
            icon: AppIcons.qrCode,
            tinted: false,
            title: l10n.remotePairAddComputer,
            onTap: () => Navigator.of(context).push(RemotePairingPage.route()),
          ),
      ],
    );
  }

  static String _providerName(String p) => switch (p) {
    'github' => 'GitHub',
    'zhihu' => appL10n.brandZhihu,
    'google' => 'Google',
    'password' => appL10n.remoteEmail,
    _ => p,
  };

  Future<void> _confirmLogout(BuildContext context, RelayAccountController notifier) async {
    final l10n = context.l10n;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.remoteRelaySignOutTitle),
        content: Text(l10n.remoteRelaySignOutBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.remoteSignOut)),
        ],
      ),
    );
    if (ok == true) await notifier.logout();
  }
}

/// GitHub first (the usual way in), then the Server's own order.
List<RelayAuthProvider> _orderedProviders(List<RelayAuthProvider> providers) => [
  for (final p in providers)
    if (p.id == 'github') p,
  for (final p in providers)
    if (p.id != 'github') p,
];

class _LoginCard extends ConsumerWidget {
  const _LoginCard({required this.account, required this.available, required this.loading});

  final RelayAccountState account;
  final bool available;
  final bool loading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final notifier = ref.read(relayAccountProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 12, SettingsMetrics.inset, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SettingsIcon(AppIcons.lock, tint: 1),
              const SizedBox(width: SettingsMetrics.iconGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.remoteRelaySignInTitle, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 1),
                    Text(
                      l10n.remoteRelaySignInHelp,
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (!account.loggingIn && available && (ref.watch(relayPairingSupportProvider).value ?? false)) ...[
            FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(RemotePairingPage.route()),
              icon: const Icon(AppIcons.qrCode, size: 18),
              label: Text(l10n.remotePairEntry),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 12),
              child: Text(
                l10n.remotePairEntryHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
              ),
            ),
          ],
          if (account.loggingIn)
            _Waiting(url: account.loginUrl, onCancel: notifier.cancelLogin)
          else if (account.providers.isEmpty)
            // No provider list (a Server too old to list them, or unreachable):
            // one generic browser sign-in.
            FilledButton.icon(
              onPressed: available && !loading ? () => unawaited(notifier.login()) : null,
              icon: const Icon(AppIcons.openExternal, size: 18),
              label: Text(available ? l10n.remoteBrowserSignIn : l10n.remoteComingSoon),
            )
          else
            ..._signInButtons(context, account, notifier, enabled: available && !loading),
          if (account.error case final e?) ...[
            const SizedBox(height: 10),
            Text(e, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
          ],
          if (available)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Center(
                child: TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: colors.textTertiary,
                    minimumSize: const Size(0, 36),
                    textStyle: theme.textTheme.labelMedium,
                  ),
                  onPressed: account.loggingIn ? null : () => showSelfHostedLogin(context),
                  child: Text(l10n.remoteSelfHostedEmailSignIn),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One button per sign-in provider: the first (GitHub, see
/// [_orderedProviders]) is the page's filled action, the rest stay tonal.
List<Widget> _signInButtons(
  BuildContext context,
  RelayAccountState account,
  RelayAccountController notifier, {
  required bool enabled,
}) {
  final l10n = context.l10n;
  final providers = _orderedProviders(account.providers);
  VoidCallback? tap(RelayAuthProvider provider) =>
      enabled ? () => unawaited(notifier.login(providerId: provider.id)) : null;
  const icon = Icon(AppIcons.openExternal, size: 18);
  return [
    for (final (i, provider) in providers.indexed) ...[
      if (i > 0) const SizedBox(height: 8),
      if (i == 0)
        FilledButton.icon(
          onPressed: tap(provider),
          icon: icon,
          label: Text(l10n.remoteSignInWithProvider(provider.displayName)),
        )
      else
        FilledButton.tonalIcon(
          onPressed: tap(provider),
          icon: icon,
          label: Text(l10n.remoteSignInWithProvider(provider.displayName)),
        ),
    ],
  ];
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.url, required this.onCancel});

  final Uri? url;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.2)),
            const SizedBox(width: 12),
            Expanded(child: Text(l10n.remoteBrowserSignInPending, style: theme.textTheme.bodyMedium)),
            TextButton(onPressed: onCancel, child: Text(l10n.commonCancel)),
          ],
        ),
        if (url case final u?)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: colors.textTertiary, padding: EdgeInsets.zero),
              onPressed: () => Clipboard.setData(ClipboardData(text: u.toString())),
              icon: const Icon(AppIcons.copy, size: 15),
              label: Text(l10n.remoteCopySignInLink),
            ),
          ),
      ],
    );
  }
}

class _RelayRow extends ConsumerWidget {
  const _RelayRow({required this.host, required this.active, required this.onTap});

  final RelayHost host;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hostRef = HostRef.relay(host.id, name: host.name);
    final status = active ? ref.watch(hostLinkStatusProvider(hostRef)).value : null;
    final view = status == null ? HostStatusView.ofRelayHost(host) : HostStatusView.ofLink(status);
    return Semantics(
      key: ValueKey('remote-row-${host.id}'),
      selected: active,
      inMutuallyExclusiveGroup: true,
      child: SettingsTile(
        icon: hostKindIcon(HostKind.relay),
        tinted: false,
        title: host.name,
        subtitle: host.subtitle,
        onTap: onTap,
        value: KeyedSubtree(
          key: ValueKey('remote-status-${host.id}'),
          child: status?.isConnected == true
              ? Tooltip(
                  message: context.l10n.remoteNetworkDetails,
                  child: TextButton.icon(
                    key: ValueKey('remote-network-${host.id}'),
                    onPressed: () => showRemoteNetworkDetails(context, hostRef),
                    icon: const Icon(AppIcons.info, size: 16),
                    label: Text((status!.network?.path ?? status.path)?.label ?? context.l10n.remoteNetworkDetails),
                  ),
                )
              : _HostState(view),
        ),
        trailing: active ? Icon(AppIcons.selected, size: 20, color: scheme.primary) : const SizedBox(width: 20),
        chevron: false,
      ),
    );
  }
}
