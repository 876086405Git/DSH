// 模型渠道 (a list page): official DeepSeek and OpenAI, legacy subscriptions
// through the engine's sign-in bridge, and the active engine's custom routes.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/account_state.dart';
import '../../state/connection_state.dart';
import '../../state/models_state.dart';
import '../../state/providers_state.dart';
import '../../state/read_list_cache.dart';
import '../../state/read_list_identity.dart';
import '../../state/settings_state.dart';
import '../../state/subscriptions_state.dart';
import '../account/account_page.dart';
import '../common/app_dialog.dart';
import '../common/list_page_row.dart';
import '../common/read_list_status.dart';
import '../common/status_chip.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart';
import '../onboarding/api_key_page.dart' show maskApiKey;
import '../settings/index/spots.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'new_chat_defaults_card.dart';
import 'provider_detail_page.dart';
import 'provider_form_page.dart';
import 'provider_widgets.dart';
import 'subscription_page.dart';
import 'subscription_sheet.dart';

class ProvidersPage extends ConsumerWidget {
  const ProvidersPage({super.key});

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final conn = ref.watch(readListLiveConnectionProvider);
    final async = ref.watch(customProvidersProvider);
    final view = ref.watch(providerListViewProvider);
    final snapshot = view.authoritative ? async.value : null;
    final subs = ref.watch(subscriptionsProvider).value;
    final legacy = [
      if (subs != null && subs.available)
        for (final status in subs.statuses)
          if (status.subscription != Subscription.chatgptOfficial) status,
    ];
    final official = ref.watch(officialChatGptStatusProvider);
    final officialReady =
        official?.signedIn == true &&
        official?.signOutPending != true &&
        official?.planEnabled == true &&
        _officialModelsReady(ref.watch(modelCatalogProvider));
    final summary = _summary(ref, conn, snapshot, legacy, hasOfficial: official != null, officialReady: officialReady);
    return AppPage.list(
      title: l10n.engineProvidersTitle,
      subtitle: view.readOnly && (view.value != null || snapshot != null)
          ? Text(readListStatusText(view.status), maxLines: 1, overflow: TextOverflow.ellipsis)
          : summary == null
          ? null
          : Text(summary),
      children: [
        const NewChatDefaultsCard(),
        _OfficialAccounts(openAi: official, openAiReady: officialReady),
        if (legacy.isNotEmpty) _SubscriptionAccounts(statuses: legacy),
        if (view.value?.supported == false)
          FeatureMessage(
            icon: AppIcons.unsupported,
            title: l10n.engineProvidersUnsupported,
            body: l10n.engineSettingsVersionRequired,
          )
        else if (view.value != null)
          _CustomCard(cached: view.value, readOnly: true, onOpen: (_) {}, onAdd: () {})
        else if (conn == null)
          FeatureMessage(
            icon: AppIcons.offline,
            title: l10n.engineProvidersNotConnected,
            body: l10n.engineProvidersStartEngine,
          )
        else if (snapshot == null && async.hasError)
          FeatureMessage(
            icon: AppIcons.error,
            title: l10n.engineProviderReadFailed,
            body: describeProviderError(async.error!),
            action: (l10n.commonRetry, () => ref.invalidate(customProvidersProvider)),
          )
        else if (snapshot == null)
          const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 40))
        else if (!snapshot.supported)
          FeatureMessage(
            icon: AppIcons.unsupported,
            title: l10n.engineProvidersUnsupported,
            body: l10n.engineSettingsVersionRequired,
          )
        else
          _CustomCard(
            snapshot: snapshot,
            readOnly: view.readOnly,
            onOpen: (id) {
              if (!ref.read(providerListViewProvider).readOnly &&
                  identical(ref.read(customProvidersProvider).value, snapshot)) {
                _push(context, ProviderDetailPage(providerId: id));
              }
            },
            onAdd: () {
              if (!ref.read(providerListViewProvider).readOnly &&
                  identical(ref.read(customProvidersProvider).value, snapshot)) {
                _push(context, const ProviderFormPage());
              }
            },
          ),
      ],
    );
  }
}

/// 「4 个渠道 · 2 个可用」(prefixed with the host when it is a remote one):
/// every row but 「添加渠道」, and those ready to serve. Null until the
/// custom providers are read, so the figures never jump.
String? _summary(
  WidgetRef ref,
  HostConnection? conn,
  ProvidersSnapshot? snapshot,
  List<SubscriptionStatus> legacy, {
  required bool hasOfficial,
  required bool officialReady,
}) {
  if (conn == null || snapshot == null) return null;
  final remote = !conn.isLocal;
  final bool deepSeek;
  if (remote) {
    deepSeek = catalogHasDeepSeek(ref.watch(modelCatalogProvider).value);
  } else {
    final account = ref.watch(accountProvider);
    deepSeek = account.signedIn || ref.watch(settingsProvider.select((s) => s.hasApiKey));
  }
  final total = 1 + (hasOfficial ? 1 : 0) + legacy.length + snapshot.providers.length;
  final ready = [
    deepSeek,
    officialReady,
    for (final s in legacy) s.signedIn,
    for (final p in snapshot.providers) snapshot.healthOf(p) == ProviderHealth.ready,
  ].where((ok) => ok).length;
  final counts = appL10n.engineProvidersSummary(total, ready);
  return remote ? '${conn.label} · $counts' : counts;
}

bool _officialModelsReady(AsyncValue<ModelCatalog?> catalog) {
  final models = catalog.value;
  if (catalog.isLoading || catalog.hasError || models == null) return false;
  final wire = Subscription.chatgptOfficial.wire;
  return models.routableProviders.contains(wire) &&
      models.groups.any((group) => group.id == wire && group.models.isNotEmpty);
}

/// DeepSeek uses the app's account / API key locally and the catalog remotely.
/// OpenAI is only added when the local bridge offers official ChatGPT sign-in.
class _OfficialAccounts extends ConsumerWidget {
  const _OfficialAccounts({required this.openAi, required this.openAiReady});

  final SubscriptionStatus? openAi;
  final bool openAiReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final conn = ref.watch(activeConnectionProvider).value;
    final Widget row;
    if (conn != null && !conn.isLocal) {
      final ready = catalogHasDeepSeek(ref.watch(modelCatalogProvider).value);
      row = ListPageRow(
        leading: const Monogram('DeepSeek'),
        title: 'DeepSeek',
        subtitle: ready ? l10n.engineFieldConfigured : l10n.engineProvidersNotConfiguredHere,
        trailing: ProviderDot(ready ? StatusTone.ok : StatusTone.idle),
      );
    } else {
      final account = ref.watch(accountProvider);
      final settings = ref.watch(settingsProvider);
      final (String subtitle, StatusTone tone) = switch (account.phase) {
        AccountPhase.signedIn => (
          l10n.engineProvidersAccount(account.profile?.displayName ?? l10n.commonSignedIn),
          StatusTone.ok,
        ),
        AccountPhase.signingIn => (l10n.engineProvidersSigningIn, StatusTone.busy),
        _ when settings.hasApiKey => ('API Key · ${maskApiKey(settings.apiKey)}', StatusTone.ok),
        _ => (l10n.engineProvidersSignInOrKey, StatusTone.idle),
      };
      row = ListPageRow(
        leading: const Monogram('DeepSeek'),
        title: 'DeepSeek',
        subtitle: subtitle,
        trailing: ProviderDot(tone),
        chevron: true,
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AccountPage())),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: ListPageCard(
        title: l10n.engineProvidersOfficial,
        children: [row, if (openAi case final status?) _SubscriptionRow(status: status, ready: openAiReady)],
      ),
    );
  }
}

/// 「订阅」: ChatGPT and Claude, signed in through the engine's bridge. Left
/// out entirely when the engine has no bridge (older DSH, a remote host
/// without it) or is not connected.
class _SubscriptionAccounts extends StatelessWidget {
  const _SubscriptionAccounts({required this.statuses});

  final List<SubscriptionStatus> statuses;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: ListPageCard(
      title: context.l10n.engineProvidersSubscription,
      children: [for (final status in statuses) _SubscriptionRow(status: status)],
    ),
  );
}

class _SubscriptionRow extends ConsumerWidget {
  const _SubscriptionRow({required this.status, this.ready = true});

  final SubscriptionStatus status;
  final bool ready;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final subscription = status.subscription;
    final label = subscriptionLabel(subscription);
    final official = subscription == Subscription.chatgptOfficial;
    final title = official ? 'OpenAI' : label;
    final subtitle = official ? l10n.engineProvidersChatGptOfficial : null;
    final leading = Monogram(title, letter: subscriptionLetter(subscription));
    final signOutPending = official && status.signOutPending;
    if (status.signedIn || signOutPending) {
      final account = status.account?.trim();
      return ListPageRow(
        leading: leading,
        title: title,
        subtitle: signOutPending
            ? l10n.engineSubscriptionSignOutFailed(l10n.commonRetry)
            : subtitle ??
                  (account == null || account.isEmpty ? l10n.commonSignedIn : l10n.engineProvidersSignedInAccount(account)),
        trailing: ProviderDot(signOutPending ? StatusTone.warn : ready ? StatusTone.ok : StatusTone.idle),
        chevron: true,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => SubscriptionPage(subscription: subscription)),
        ),
      );
    }
    Future<void> signIn() async {
      var newAccount = false;
      if (official && status.reconnectAvailable) {
        final choice = await showAppDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(l10n.engineSubscriptionSignIn(label)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonCancel)),
              TextButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(l10n.engineSubscriptionUseAnotherAccount),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(l10n.engineSubscriptionReconnectAccount),
              ),
            ],
          ),
        );
        if (choice == null || !context.mounted) return;
        final current = ref.read(officialChatGptStatusProvider);
        if (current == null || current.signedIn || current.signOutPending || !current.reconnectAvailable) return;
        newAccount = choice;
      }
      await showSubscriptionLogin(context, subscription, newAccount: newAccount);
    }

    return ListPageRow(
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: LoginCapsule(onPressed: signIn, semanticLabel: l10n.engineSubscriptionSignIn(subtitle ?? label)),
      onTap: signIn,
    );
  }
}

/// The small 「登录」 capsule at the end of a row; its right edge is the row's
/// 16dp edge, like the label on the left.
class LoginCapsule extends StatelessWidget {
  const LoginCapsule({super.key, required this.onPressed, this.semanticLabel});

  final VoidCallback? onPressed;
  final String? semanticLabel;

  static const height = 32.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      label: semanticLabel,
      button: true,
      excludeSemantics: semanticLabel != null,
      child: FilledButton.tonal(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, height),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          shape: const StadiumBorder(),
          textStyle: Theme.of(context).textTheme.labelLarge,
        ),
        child: Text(l10n.commonSignIn),
      ),
    );
  }
}

class _CustomCard extends StatelessWidget {
  const _CustomCard({this.snapshot, this.cached, required this.onOpen, required this.onAdd, required this.readOnly});

  final ProvidersSnapshot? snapshot;
  final CachedProviders? cached;
  final bool readOnly;
  final ValueChanged<String> onOpen;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final live = snapshot;
    final providers =
        cached?.rows ??
        [
          for (final p in live!.providers)
            CachedProvider(
              id: p.id,
              name: p.displayName,
              api: p.api,
              models: p.models.length,
              health: live.healthOf(p),
            ),
        ];
    final writable = !readOnly && (live?.writable ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListPageCard(
          title: l10n.engineProvidersCustom,
          children: [
            for (final (i, p) in providers.indexed)
              FadeSlideIn(
                key: ValueKey(p.id),
                index: i,
                child: _ProviderRow(provider: p, onTap: readOnly ? null : () => onOpen(p.id)),
              ),
            ListPageRow(
              icon: AppIcons.add,
              iconColor: writable ? Theme.of(context).colorScheme.primary : null,
              spot: Spots.addProvider,
              subtitle: providers.isEmpty ? l10n.engineProvidersCompatibleHint : null,
              chevron: false,
              onTap: writable ? onAdd : null,
            ),
          ],
        ),
        if (live != null && !live.writable) FeatureNote(l10n.engineProvidersReadOnly),
      ],
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({required this.provider, required this.onTap});

  final CachedProvider provider;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final health = provider.health;
    final view = ProviderHealthView.of(health);
    final colors = DshColors.of(context);
    return Semantics(
      label: '${provider.name}，${view.label}',
      child: ListPageRow(
        leading: Monogram(provider.name),
        title: provider.name,
        subtitle: health != ProviderHealth.ready
            ? view.label
            : [
                if (provider.api case final api?) protocolLabel(api) else context.l10n.engineProviderConfiguredInWeb,
                if (provider.models > 0) context.l10n.engineProviderModels(provider.models),
              ].join(' · '),
        subtitleColor: switch (health) {
          ProviderHealth.missingKey => colors.warning,
          ProviderHealth.misconfigured => colors.danger,
          _ => null,
        },
        trailing: ProviderDot(view.tone),
        chevron: onTap != null,
        onTap: onTap,
      ),
    );
  }
}

/// For callers outside this page (the model sheet, onboarding).
void openProviders(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ProvidersPage()));

/// A remote engine's catalog lists DeepSeek models (account or API Key).
bool catalogHasDeepSeek(ModelCatalog? catalog) =>
    catalog?.groups.any((g) => g.id.startsWith('deepseek') && g.models.isNotEmpty) ?? false;
