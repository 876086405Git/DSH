// 订阅详情 (a detail page): who is signed in, the models the subscription brings
// (its catalog group), 「退出登录」. 「暂无模型」 only when the catalog was read and
// lists none for it; a failed read is an error with 「重试」, no connection is
// the offline message.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/models_state.dart';
import '../../state/providers_state.dart' show formatTokens;
import '../../state/read_list_cache.dart' show ReadListStatus;
import '../../state/subscriptions_state.dart';
import '../common/app_dialog.dart';
import '../common/list_page_row.dart';
import '../common/page_hero.dart';
import '../common/read_list_status.dart';
import '../common/status_chip.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'model_context_page.dart';
import 'provider_widgets.dart';
import 'subscription_sheet.dart';

class SubscriptionPage extends ConsumerStatefulWidget {
  const SubscriptionPage({super.key, required this.subscription});

  final Subscription subscription;

  @override
  ConsumerState<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends ConsumerState<SubscriptionPage> {
  bool _busy = false;

  bool get _official => widget.subscription == Subscription.chatgptOfficial;
  String get _label => _official ? 'OpenAI' : subscriptionLabel(widget.subscription);

  Future<void> _signOut() async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.engineSubscriptionSignOutTitle(_label)),
        content: Text(context.l10n.engineSubscriptionSignOutBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonSignOut),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (_official) {
      final current = ref.read(officialChatGptStatusProvider);
      if (current == null || (!current.signedIn && !current.signOutPending)) return;
    }
    final backend = ref.read(subscriptionBackendProvider);
    if (backend == null) return;
    setState(() => _busy = true);
    try {
      await backend.signOut(widget.subscription);
      refreshAfterSubscriptionChange(ref);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      if (_official && error is DshRemoteException && error.code == 'app-auth/revocation-unconfirmed') {
        refreshAfterSubscriptionChange(ref);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.l10n.engineSubscriptionRevocationUnconfirmed)),
        );
        Navigator.of(context).pop();
        return;
      }
      final cleanupFailed = _official && error is DshRemoteException && error.code == 'app-auth/sign-out-failed';
      if (cleanupFailed) refreshAfterSubscriptionChange(ref);
      setState(() => _busy = false);
      final l10n = context.l10n;
      final reason = cleanupFailed ? l10n.commonFailedTryAgain : describeLoginError(error);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(l10n.engineSubscriptionSignOutFailed(reason))),
      );
    }
  }

  /// The catalog couldn't say which models the subscription brings: [error]
  /// when the read failed, null when the catalog reported this provider failing
  /// (its message is the engine's own text, not shown).
  Widget _modelsFailed(Object? error) {
    final title = context.l10n.engineSubscriptionModelsFailed;
    void retry() => ref.invalidate(modelCatalogProvider);
    return error == null
        ? FeatureMessage(icon: AppIcons.error, title: title, action: (context.l10n.commonRetry, retry))
        : FeatureMessage.error(title: title, error: error, onRetry: retry);
  }

  /// 「上下文长度」: one model's override of the catalog's figure.
  void _openContext(ModelInfo model, ModelOverride? current) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelContextPage(
          subscription: widget.subscription,
          route: widget.subscription.wire,
          modelId: model.id,
          modelName: model.name,
          current: current,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final status = _official
        ? ref.watch(officialChatGptStatusProvider)
        : ref.watch(subscriptionsProvider).value?.of(widget.subscription);
    final signOutPending = _official && (status?.signOutPending ?? false);
    final signedIn = !signOutPending && (status?.signedIn ?? false);
    final catalog = ref.watch(modelCatalogProvider);
    final wire = widget.subscription.wire;
    // The pi-ai route this subscription declared: the model overrides hang off
    // it (`providers.<route>.modelOverrides`). Null before sign-in or while the
    // bridge is declaring it.
    final profile = _official ? null : ref.watch(subscriptionProfileProvider(widget.subscription)).value;
    final models = [
      for (final group in catalog.value?.groups ?? const [])
        if (group.id == wire) ...group.models,
    ];
    // The read failed, or the catalog says this subscription's provider did:
    // that doesn't show it has no models. (Other providers' failures don't
    // count against this one.)
    final failed = catalog.hasError || (catalog.value?.failures.any((f) => f.provider == wire) ?? false);
    final account = status?.account?.trim();
    const gap = SizedBox(height: 24);
    final modelsTitle = models.isEmpty ? l10n.engineModelTitle : l10n.engineProviderModelCount(models.length);

    return AppPage(
      title: _label,
      hero: PageHero(
        leading: Monogram(_label, size: 56, letter: subscriptionLetter(widget.subscription)),
        title: _label,
        subtitle: Row(
          children: [
            ProviderDot(signedIn ? StatusTone.ok : StatusTone.idle),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                signedIn ? l10n.commonSignedIn : l10n.engineAccountSignedOut,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      slivers: [
        SliverList.list(
          children: [
            ListPageCard(
              children: [
                ListPageRow(
                  icon: AppIcons.account,
                  title: l10n.engineAccountTitle,
                  value: account == null || account.isEmpty
                      ? (signedIn ? l10n.commonSignedIn : l10n.engineAccountSignedOut)
                      : account,
                ),
              ],
            ),
            gap,
            if (signOutPending)
              FeatureNote(l10n.engineSubscriptionSignOutFailed(l10n.commonRetry))
            else if (_official && signedIn && status?.planEnabled == false)
              FeatureMessage(
                icon: AppIcons.account,
                title: l10n.engineSubscriptionPlanNotEnabled,
                action: _busy
                    ? null
                    : (l10n.chatSignInAgain, () => showSubscriptionLogin(context, widget.subscription)),
              )
            else if (models.isEmpty && !catalog.isLoading && failed)
              _modelsFailed(catalog.error)
            else if (models.isEmpty && !catalog.isLoading && catalog.value == null)
              const FeatureOffline()
            else
              ListPageCard(
                // Models kept from before a failed refresh: shown, marked as such.
                title: failed ? readListHeading(modelsTitle, ReadListStatus.failed) : modelsTitle,
                children: [
                  if (catalog.isLoading && models.isEmpty)
                    const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 16))
                  else if (models.isEmpty)
                    ListPageRow(
                      icon: AppIcons.modelItem,
                      iconColor: colors.textTertiary,
                      title: l10n.engineSubscriptionNoModels,
                    )
                  else
                    for (final model in models)
                      _ModelRow(
                        model: model,
                        modelOverride: profile?.modelOverrides[model.id],
                        showContext: profile != null,
                        onTap: profile == null ? null : () => _openContext(model, profile.modelOverrides[model.id]),
                      ),
                ],
              ),
            gap,
            Center(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: colors.danger),
                onPressed: _busy || (!signedIn && !signOutPending) ? null : _signOut,
                icon: const Icon(AppIcons.logout, size: 19),
                label: Text(l10n.commonSignOut),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 订阅模型的一行：名字 + 渠道模型 id，右侧是它生效的上下文长度（有覆盖时
/// 是覆盖值，没有时写「默认」= 跟随目录）。点开可改。
class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model, required this.modelOverride, required this.showContext, required this.onTap});

  final ModelInfo model;

  /// The model's override, when it has one.
  final ModelOverride? modelOverride;

  /// Whether the route profile is known: only then can the row say which
  /// context length is in effect (「默认」 or the override).
  final bool showContext;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final value = modelOverride?.contextWindow;
    return ListPageRow(
      icon: AppIcons.modelItem,
      title: model.name,
      subtitle: model.name == model.id ? null : model.id,
      value: !showContext ? null : (value == null ? l10n.commonDefault : formatTokens(value)),
      onTap: onTap,
    );
  }
}
