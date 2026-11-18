// 设置 › 手机操控 › 解除限制: the hard rules a person may lift, one by one, at
// their own risk (docs/guide 手机操控 › 解除限制). All off by default.
// Turning one on goes through a full confirmation page — what AI may then do,
// what can go wrong, the disclaimer — and a 1.5 s hold; turning it off is one
// tap. Nothing can be turned on while a task runs: the agent driving the
// phone must not be able to widen its own reach.
//
// ```
//   解除限制
//   让 AI 去做默认由你来做的事
//   ╭──────────────────────────────────╮
//   │ ⚙ 系统设置                   ( ●) │
//   │   含权限页、安装器、安全中心、通知栏 │
//   │ ⚿ 密码和验证码               ( ●) │
//   │ ▭ DSH Go 自身                ( ●) │
//   ╰──────────────────────────────────╯
//   ╭──────────────────────────────────╮
//   │ ☰ 银行、支付类 App               › │
//   ╰──────────────────────────────────╯
//   开启后的后果由你承担。…
// ```

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_state.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../features/feature_kit.dart';
import '../providers/provider_widgets.dart' show FormBottomBar;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'app_rules_page.dart';
import 'hold_to_confirm.dart';
import 'phone_widgets.dart';

extension PhoneUnlockText on PhoneUnlock {
  String label(L10n l10n) => switch (this) {
    PhoneUnlock.systemPages => l10n.phoneUnlockSystem,
    PhoneUnlock.secretFields => l10n.phoneUnlockSecrets,
    PhoneUnlock.ownApp => l10n.phoneUnlockOwnApp,
  };

  String hint(L10n l10n) => switch (this) {
    PhoneUnlock.systemPages => l10n.phoneUnlockSystemHint,
    PhoneUnlock.secretFields => l10n.phoneUnlockSecretsHint,
    PhoneUnlock.ownApp => l10n.phoneUnlockOwnAppHint,
  };

  IconData get icon => switch (this) {
    PhoneUnlock.systemPages => AppIcons.unlockSystem,
    PhoneUnlock.secretFields => AppIcons.unlockSecrets,
    PhoneUnlock.ownApp => AppIcons.unlockOwnApp,
  };

  /// What stays with the person while this rule holds (确认方式's list).
  String yours(L10n l10n) => switch (this) {
    PhoneUnlock.systemPages => l10n.phoneYoursSystem,
    PhoneUnlock.secretFields => l10n.phoneYoursSecrets,
    PhoneUnlock.ownApp => l10n.phoneYoursOwnApp,
  };

  String confirmTitle(L10n l10n) => switch (this) {
    PhoneUnlock.systemPages => l10n.phoneUnlockConfirmSystemTitle,
    PhoneUnlock.secretFields => l10n.phoneUnlockConfirmSecretsTitle,
    PhoneUnlock.ownApp => l10n.phoneUnlockConfirmOwnAppTitle,
  };

  /// 开启后，AI 可以.
  List<String> can(L10n l10n) => switch (this) {
    PhoneUnlock.systemPages => [l10n.phoneUnlockSystemCan1, l10n.phoneUnlockSystemCan2, l10n.phoneUnlockSystemCan3],
    PhoneUnlock.secretFields => [l10n.phoneUnlockSecretsCan1, l10n.phoneUnlockSecretsCan2, l10n.phoneUnlockSecretsCan3],
    PhoneUnlock.ownApp => [l10n.phoneUnlockOwnAppCan1, l10n.phoneUnlockOwnAppCan2],
  };

  /// 可能出什么事.
  List<String> risks(L10n l10n) => switch (this) {
    PhoneUnlock.systemPages => [l10n.phoneUnlockSystemRisk1, l10n.phoneUnlockSystemRisk2],
    PhoneUnlock.secretFields => [l10n.phoneUnlockSecretsRisk1, l10n.phoneUnlockSecretsRisk2],
    PhoneUnlock.ownApp => [l10n.phoneUnlockOwnAppRisk1, l10n.phoneUnlockOwnAppRisk2],
  };
}

/// The disclaimer, the same for each rule (and in the guide).
List<String> phoneUnlockDisclaimer(L10n l10n) => [
  l10n.phoneUnlockDisclaimer1,
  l10n.phoneUnlockDisclaimer2,
  l10n.phoneUnlockDisclaimer3,
  l10n.phoneUnlockDisclaimer4,
  l10n.phoneUnlockDisclaimer5,
];

/// The row value for 解除限制: 未开启 / 已开启 2 项; null while unread.
String? phoneUnlockSummary(L10n l10n, PhonePolicies? policies) {
  if (policies == null) return null;
  final n = policies.unlocks.length;
  return n == 0 ? l10n.phoneUnlockNone : l10n.phoneUnlockCount(n);
}

class PhoneUnlockPage extends ConsumerStatefulWidget {
  const PhoneUnlockPage({super.key});

  @override
  ConsumerState<PhoneUnlockPage> createState() => _PhoneUnlockPageState();
}

class _PhoneUnlockPageState extends ConsumerState<PhoneUnlockPage> {
  /// The rule being switched (its switch waits).
  PhoneUnlock? _busy;

  PhoneController get _phone => ref.read(phoneProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Fresh: a task may have started, or the rules changed, since the provider's last read.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_phone.refresh());
    });
  }

  Future<void> _set(PhoneUnlock unlock, bool on) async {
    if (_busy != null) return;
    final l10n = context.l10n;
    if (on) {
      if (ref.read(phoneProvider).status.anyTaskBusy) {
        showBriefNotice(context, l10n.phoneUnlockBusy);
        return;
      }
      final done = await Navigator.of(context)
          .push<bool>(MaterialPageRoute(builder: (_) => PhoneUnlockConfirmPage(unlock: unlock)));
      if (done == true && mounted) showBriefNotice(context, l10n.phoneUnlockOnNotice(unlock.label(l10n)));
      return;
    }
    setState(() => _busy = unlock);
    final ok = await _phone.setUnlock(unlock, false);
    if (!mounted) return;
    setState(() => _busy = null);
    showBriefNotice(context, ok ? l10n.phoneUnlockOffNotice(unlock.label(l10n)) : l10n.phoneConfirmSaveFailed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = ref.watch(phoneProvider);
    final policies = state.policies;
    final busyTask = state.status.anyTaskBusy;
    return AppPage.list(
      title: l10n.phoneUnlockTitle,
      subtitle: Text(l10n.phoneUnlockSubtitle),
      children: [
        if (busyTask) ...[
          PhoneNote(
            key: const ValueKey('unlock-busy'),
            tone: NoteTone.warn,
            text: l10n.phoneUnlockBusy,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          ),
          const SizedBox(height: 16),
        ],
        if (!state.loaded)
          const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 32))
        else ...[
          ListPageCard(
            children: [
              for (final unlock in PhoneUnlock.values)
                _UnlockRow(
                  unlock: unlock,
                  on: policies?.unlocks.contains(unlock) ?? false,
                  // Unread rules can't be switched; a running task only blocks turning on.
                  onChanged: policies == null || _busy != null ? null : (on) => unawaited(_set(unlock, on)),
                  busy: _busy == unlock,
                ),
            ],
          ),
          const SizedBox(height: 24),
          ListPageCard(
            children: [
              ListPageRow(
                icon: AppIcons.appRules,
                title: l10n.phoneUnlockBanks,
                subtitle: l10n.phoneUnlockBanksHint,
                onTap: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PhoneAppRulesPage())),
              ),
            ],
          ),
          PageFootnote(l10n.phoneUnlockFootnote),
        ],
      ],
    );
  }
}

class _UnlockRow extends StatelessWidget {
  const _UnlockRow({required this.unlock, required this.on, required this.onChanged, required this.busy});

  final PhoneUnlock unlock;
  final bool on;
  final ValueChanged<bool>? onChanged;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final change = onChanged;
    return MergeSemantics(
      child: ListPageRow(
        key: ValueKey('unlock-${unlock.name}'),
        icon: unlock.icon,
        // Lifted: the glyph takes the warning colour, like the page's tag.
        iconColor: on ? DshColors.of(context).warning : null,
        title: unlock.label(l10n),
        subtitle: unlock.hint(l10n),
        subtitleMaxLines: 2,
        chevron: false,
        onTap: change == null ? null : () => change(!on),
        trailing: busy
            ? const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round),
              )
            : Switch.adaptive(value: on, onChanged: change),
      ),
    );
  }
}

/// The confirmation before one rule is lifted: what AI may then do, what can
/// go wrong, the disclaimer, and 「我了解风险，开启」 held for 1.5 s. Pops true
/// once the rule is lifted.
class PhoneUnlockConfirmPage extends ConsumerStatefulWidget {
  const PhoneUnlockConfirmPage({super.key, required this.unlock});

  final PhoneUnlock unlock;

  @override
  ConsumerState<PhoneUnlockConfirmPage> createState() => _PhoneUnlockConfirmPageState();
}

class _PhoneUnlockConfirmPageState extends ConsumerState<PhoneUnlockConfirmPage> {
  bool _saving = false;

  Future<void> _confirm() async {
    if (_saving) return;
    setState(() => _saving = true);
    final ok = await ref.read(phoneProvider.notifier).setUnlock(widget.unlock, true);
    if (!mounted) return;
    if (ok) {
      unawaited(Navigator.of(context).maybePop(true));
      return;
    }
    setState(() => _saving = false);
    final l10n = context.l10n;
    final busy = ref.read(phoneProvider).status.anyTaskBusy;
    showBriefNotice(context, busy ? l10n.phoneUnlockBusy : l10n.phoneConfirmSaveFailed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final unlock = widget.unlock;
    final busyTask = ref.watch(phoneProvider.select((s) => s.status.anyTaskBusy));
    const gap = SizedBox(height: 24);
    final page = AppPage.list(
      title: unlock.confirmTitle(l10n),
      children: [
        ListPageCard(
          key: const ValueKey('unlock-can'),
          title: l10n.phoneUnlockCanTitle,
          children: [BulletLines(unlock.can(l10n))],
        ),
        gap,
        ListPageCard(
          key: const ValueKey('unlock-risks'),
          title: l10n.phoneUnlockRiskTitle,
          children: [BulletLines(unlock.risks(l10n))],
        ),
        gap,
        _Disclaimer(lines: phoneUnlockDisclaimer(l10n)),
        // Room for the bar, its hint and the gesture area under it.
        const SizedBox(height: FormBottomBar.height + 40),
      ],
    );
    return Stack(
      children: [
        page,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: FormBottomBar(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                HoldToConfirmButton(
                  label: l10n.phoneUnlockHold,
                  hint: l10n.phoneUnlockHoldHint,
                  enabled: !_saving && !busyTask,
                  onConfirmed: () => unawaited(_confirm()),
                ),
                const SizedBox(height: 8),
                ExcludeSemantics(
                  child: Text(
                    busyTask ? l10n.phoneUnlockBusy : l10n.phoneUnlockHoldHint,
                    key: const ValueKey('unlock-hold-hint'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 免责声明: a card in the danger tone, the same five lines for every rule.
class _Disclaimer extends StatelessWidget {
  const _Disclaimer({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final ink = colors.onDangerContainer;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Semantics(
        container: true,
        child: DecoratedBox(
          key: const ValueKey('unlock-disclaimer'),
          decoration: ShapeDecoration(
            color: colors.dangerContainer,
            shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(AppIcons.riskWarning, size: 20, color: ink),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          context.l10n.phoneUnlockDisclaimerTitle,
                          style: theme.textTheme.titleSmall?.copyWith(color: ink),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final (i, line) in lines.indexed)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The bullet sits on the line's first-line centre, under the icon's.
                        SizedBox(
                          width: 20,
                          height: (theme.textTheme.bodyMedium?.fontSize ?? 14) * 1.5,
                          child: Center(
                            child: DecoratedBox(
                              decoration: ShapeDecoration(color: ink, shape: const CircleBorder()),
                              child: const SizedBox.square(dimension: 4),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(line, style: theme.textTheme.bodyMedium?.copyWith(color: ink, height: 1.5)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「已解除限制」 under 手机操控's overview: a small tag while any rule is
/// lifted, opening 解除限制.
class UnlockedTag extends StatelessWidget {
  const UnlockedTag({super.key, required this.onTap});

  final VoidCallback onTap;

  static const height = 32.0;
  static const pad = 12.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final ink = colors.onWarningContainer;
    return Pressable(
      onTap: onTap,
      semanticLabel: context.l10n.phoneUnlockedBadge,
      child: DecoratedBox(
        key: const ValueKey('unlocked-tag'),
        decoration: ShapeDecoration(color: colors.warningContainer, shape: const StadiumBorder()),
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: pad),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppIcons.unlocks, key: const ValueKey('unlocked-tag-icon'), size: 16, color: ink),
                const SizedBox(width: 6),
                Text(
                  context.l10n.phoneUnlockedBadge,
                  style: theme.textTheme.labelMedium?.copyWith(color: ink, height: 1.2),
                ),
                const SizedBox(width: 2),
                Icon(AppIcons.disclosure, key: const ValueKey('unlocked-tag-chevron'), size: 14, color: ink),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
