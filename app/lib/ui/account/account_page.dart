import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/account_state.dart';
import '../../state/settings_state.dart';
import '../chat/balance_widgets.dart' show BalanceSettingsLine;
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/overview_card.dart';
import '../onboarding/api_key_page.dart';
import '../settings/credential_recovery_dialog.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'account_widgets.dart';
import '../common/brief_notice.dart';

/// 账号: the DeepSeek account of the on-device engine (profile, wallets, top-up,
/// sign-out; the browser sign-in otherwise) and the API Key, the other way in.
class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key});

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage> {
  late final AppLifecycleListener _lifecycle;

  /// A Platform page (top-up, usage) was opened: re-read wallets on return.
  bool _awaitingReturn = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final account = ref.read(accountProvider);
      if (account.signedIn && (account.profile == null || account.profileFailed)) {
        unawaited(ref.read(accountProvider.notifier).refreshProfile());
      }
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _onResume() {
    ref.read(accountProvider.notifier).noteAppResumed();
    if (_awaitingReturn) {
      _awaitingReturn = false;
      _refresh();
    }
  }

  void _refresh() {
    ref.invalidate(accountBalanceProvider);
    unawaited(ref.read(accountProvider.notifier).refreshProfile());
  }

  Future<void> _openPlatform(String? url) async {
    if (url == null) return;
    _awaitingReturn = true;
    await openAccountLink(context, ref, url);
  }

  Future<void> _signIn() async {
    final result = await ref.read(accountProvider.notifier).signIn(brightness: Theme.of(context).brightness);
    if (!mounted || result != SignInResult.success) return;
    showBriefNotice(context, context.l10n.engineAccountSignedIn);
  }

  Future<void> _confirmSignOut() async {
    final account = ref.read(accountProvider.notifier);
    final running = await account.hasRunningAccountTasks();
    if (!mounted) return;
    final colors = DshColors.of(context);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.engineAccountSignOutTitle),
        content: Text(switch (running) {
          true => context.l10n.engineAccountSignOutBusy,
          false => context.l10n.engineAccountSignOutBody,
          null => context.l10n.engineAccountSignOutUnknown,
        }),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: colors.danger, foregroundColor: colors.onDanger),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonSignOut),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await account.signOut();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(context.l10n.engineAccountSignOutFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(accountProvider);
    return AppPage.list(
      title: l10n.engineAccountTitle,
      actions: [
        if (state.signedIn)
          GlassIconButton(icon: AppIcons.refresh, tooltip: l10n.engineAccountRefresh, onPressed: _refresh),
      ],
      children: [
        AnimatedSwitcher(
          duration: AppMotion.of(context, AppMotion.standard),
          switchInCurve: AppMotion.enter,
          switchOutCurve: AppMotion.exit,
          child: KeyedSubtree(
            key: ValueKey(state.phase),
            child: switch (state.phase) {
              AccountPhase.signedIn => _SignedInView(
                state: state,
                onTopUp: () => _openPlatform(state.links?.topUpUrl),
                onUsage: () => _openPlatform(state.links?.usageUrl),
                onSignOut: _confirmSignOut,
              ),
              AccountPhase.signingIn => _SigningInView(state: state),
              _ => _SignedOutView(state: state, onSignIn: _signIn),
            },
          ),
        ),
      ],
    );
  }
}

// ── Signed in ────────────────────────────────────────────────────────────────

class _SignedInView extends ConsumerWidget {
  const _SignedInView({required this.state, required this.onTopUp, required this.onUsage, required this.onSignOut});

  final AccountState state;
  final VoidCallback onTopUp;
  final VoidCallback onUsage;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final profile = state.profile;
    final balance = ref.watch(accountBalanceProvider);

    final name = profile?.displayName ?? (state.profileFailed ? l10n.engineAccountDeepSeek : ' ');
    final contact = profile?.contact;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OverviewCard(
          leading: AccountAvatar(profile: profile, size: OverviewCard.avatarSize),
          title: Text(name),
          subtitle: Text(
            state.profileFailed && profile == null
                ? l10n.engineAccountProfileUnavailable
                : (contact != null && contact != name ? contact : l10n.commonSignedIn),
          ),
        ),
        SettingsSection(
          title: l10n.engineAccountBalance,
          footer: Text(state.connected ? l10n.engineAccountBalanceHint : l10n.engineAccountBalanceEngineOff),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 14, SettingsMetrics.inset, 4),
              child: balance.when(
                data: (b) => _Wallets(balance: b),
                loading: () => const _Wallets(balance: null),
                error: (_, _) => _WalletsUnavailable(onRetry: () => ref.invalidate(accountBalanceProvider)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 12, SettingsMetrics.inset, 14),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: state.links == null ? null : onTopUp,
                      child: Text(l10n.engineAccountTopUp),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: state.links == null ? null : onUsage,
                      child: Text(l10n.engineAccountUsageDetails),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const ApiKeySection(),
        Center(
          child: TextButton.icon(
            onPressed: onSignOut,
            style: TextButton.styleFrom(foregroundColor: colors.danger),
            icon: const Icon(AppIcons.logout, size: 19),
            label: Text(l10n.commonSignOut),
          ),
        ),
      ],
    );
  }
}

/// Recharge and bonus balances side by side; [balance] null while unknown.
class _Wallets extends StatelessWidget {
  const _Wallets({required this.balance});

  final AccountBalance? balance;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final b = balance;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _WalletStat(label: l10n.engineAccountToppedUpBalance, lines: b == null ? null : _lines(b.recharge)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _WalletStat(label: l10n.engineAccountGrantedBalance, lines: b == null ? null : _lines(b.bonus)),
        ),
      ],
    );
  }

  /// One line per currency; an empty list reads as zero in CNY.
  static List<String> _lines(List<AccountWallet> wallets) {
    final currencies = {for (final w in wallets) w.currency}.toList();
    if (currencies.isEmpty) return const ['¥0.00'];
    return [for (final c in currencies) '${currencySymbol(c)}${formatWalletAmount(sumWallets(wallets, c) ?? '0')}'];
  }
}

class _WalletStat extends StatelessWidget {
  const _WalletStat({required this.label, required this.lines});

  final String label;
  final List<String>? lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final amountStyle = AppType.tabular(AppType.display(size: 26, color: scheme.onSurface)).copyWith(height: 1.25);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
        const SizedBox(height: 4),
        if (lines case final lines?)
          for (final line in lines) Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: amountStyle)
        else
          Text('—', style: amountStyle.copyWith(color: colors.textTertiary)),
      ],
    );
  }
}

class _WalletsUnavailable extends StatelessWidget {
  const _WalletsUnavailable({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            l10n.engineAccountBalanceUnavailable,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        TextButton(onPressed: onRetry, child: Text(l10n.commonRetry)),
      ],
    );
  }
}

// ── Signing in ───────────────────────────────────────────────────────────────

class _SigningInView extends StatelessWidget {
  const _SigningInView({required this.state});

  final AccountState state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SignInStatus(state: state),
          const SizedBox(height: 40),
          SignInActions(state: state),
        ],
      ),
    );
  }
}

// ── Signed out ───────────────────────────────────────────────────────────────

class _SignedOutView extends StatelessWidget {
  const _SignedOutView({required this.state, required this.onSignIn});

  final AccountState state;
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final unsupported = state.phase == AccountPhase.unsupported;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: GlassSurface(
            tier: GlassTier.card,
            borderRadius: AppShape.radiusLg,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const OverviewGlyph(AppIcons.apiKey),
                    const SizedBox(width: OverviewCard.gap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l10n.engineAccountDeepSeek, style: theme.textTheme.titleMedium),
                          const SizedBox(height: 2),
                          Text(
                            l10n.engineAccountNoKeyNeeded,
                            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const AccountFacts(),
                const SizedBox(height: 16),
                if (unsupported)
                  Text(
                    l10n.engineAccountUnsupported,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: colors.warning),
                  )
                else ...[
                  FilledButton(onPressed: onSignIn, child: Text(l10n.engineAccountSignInDeepSeek)),
                  if (!state.connected) ...[
                    const SizedBox(height: 10),
                    Text(
                      l10n.engineAccountAutoStart,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
        if (state.failure case final failure?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SignInFailureCard(failure: failure),
          ),
        const SizedBox(height: 24),
        const ApiKeySection(),
      ],
    );
  }
}

/// 「API Key」: the key saved in the app (replace / clear) and, when set, its
/// balance. The other way to use DeepSeek models besides the account.
class ApiKeySection extends ConsumerWidget {
  const ApiKeySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasKey = ref.watch(settingsProvider.select((s) => s.hasApiKey));
    return SettingsSection(title: 'API Key', children: [const ApiKeyTile(), if (hasKey) const BalanceSettingsLine()]);
  }
}

/// The saved DeepSeek API Key, masked; opens "replace / clear", or the key page
/// when there is none.
class ApiKeyTile extends ConsumerWidget {
  const ApiKeyTile({super.key, this.tinted = false, this.tint = 0});

  final bool tinted;
  final int tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider);
    final scheme = Theme.of(context).colorScheme;
    final colors = DshColors.of(context);
    return SettingsTile(
      icon: AppIcons.apiKey,
      tint: tint,
      tinted: tinted,
      title: 'DeepSeek API Key',
      value: settings.hasApiKey
          ? Text(maskApiKey(settings.apiKey), style: AppType.monoLabel(color: scheme.onSurfaceVariant))
          : Text(l10n.commonNotSet, style: TextStyle(color: colors.textTertiary)),
      onTap: () => manageApiKey(context, ref),
    );
  }
}

/// No key: the key page. A key: a sheet to replace or clear it.
Future<void> manageApiKey(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  void push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  if (!ref.read(settingsProvider).hasApiKey) {
    push(const ApiKeyPage(onboarding: false));
    return;
  }
  final action = await showAppSheet<String>(
    context,
    builder: (sheet) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHeader('API Key'),
          SheetGroup(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              SettingsTile(
                icon: AppIcons.edit,
                tinted: false,
                title: l10n.engineAccountReplaceKey,
                chevron: false,
                onTap: () => Navigator.pop(sheet, 'replace'),
              ),
              SettingsTile(
                icon: AppIcons.delete,
                tinted: false,
                danger: true,
                title: l10n.commonClear,
                chevron: false,
                onTap: () => Navigator.pop(sheet, 'clear'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  switch (action) {
    case 'replace':
      push(const ApiKeyPage(onboarding: false));
    case 'clear':
      final ok = await showAppDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.engineAccountClearKeyTitle),
          content: Text(l10n.engineAccountClearKeyBody),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: DshColors.of(dialog).danger,
                foregroundColor: DshColors.of(dialog).onDanger,
              ),
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(l10n.commonClear),
            ),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await ref.read(settingsProvider.notifier).setApiKey('');
      } catch (e) {
        if (!context.mounted || !await offerCredentialRecovery(context, ref, e)) rethrow;
      }
  }
}
