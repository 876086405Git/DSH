// The composer's context ring (22dp; accent below 60%, warning to 85%, danger
// above) and the usage sheet.

import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/usage_state.dart';
import '../../state/subscriptions_state.dart';
import '../../state/providers_state.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/theme.dart';
import 'balance_widgets.dart';

/// `999` / `1K` / `43K` / `500K` / `1.05M` / `100M`: K is a thousand and M a
/// million in every UI language (no 万/亿), the same units model context
/// windows are quoted in.
String formatTokens(int n) {
  String trimZeros(String text) {
    if (!text.contains('.')) return text;
    var end = text.length;
    while (text[end - 1] == '0') {
      end--;
    }
    if (text[end - 1] == '.') end--;
    return text.substring(0, end);
  }

  final sign = n < 0 ? '-' : '';
  final value = n.abs();
  if (value < 1000) {
    final digits = value.toString();
    final buf = StringBuffer(sign);
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return buf.toString();
  }
  if (value < 1000000) {
    final k = value / 1000;
    // 43K and 500K stay whole; below 100 one decimal reads better (8.4K).
    final text = trimZeros(k >= 100 ? k.toStringAsFixed(0) : k.toStringAsFixed(1));
    // 999,900…999,999 would round up to 1000K: show the carry as M instead.
    if (text != '1000') return '$sign${text}K';
  }
  return '$sign${trimZeros((value / 1000000).toStringAsFixed(2))}M';
}

/// `12%`;大于 0 但不到 1% 时写 `<1%`。
String formatPercent(double fraction) {
  if (fraction > 0 && fraction < 0.01) return '<1%';
  return '${(fraction * 100).round()}%';
}

/// 上下文占用的颜色:<60% 主色、60–85% warning、>85% danger。
Color contextTone(BuildContext context, double fraction) {
  final dsh = DshColors.of(context);
  if (fraction > 0.85) return dsh.danger;
  if (fraction >= 0.6) return dsh.warning;
  return Theme.of(context).colorScheme.primary;
}

/// 输入条里的上下文占用:小环 + 百分比(只画环在静止帧里像加载圈),
/// 点开用量弹层。60% 起环和字一起变色。
class ContextRing extends StatelessWidget {
  const ContextRing({super.key, required this.fraction, this.onTap});

  final double fraction;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final tone = contextTone(context, fraction);
    return Semantics(
      button: onTap != null,
      label: l10n.activityUsageContextSemantics(formatPercent(fraction)),
      excludeSemantics: true,
      onTap: onTap,
      child: InkResponse(
        onTap: onTap,
        radius: 26,
        child: SizedBox(
          height: 36,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CustomPaint(
                  size: const Size.square(15),
                  painter: _RingPainter(
                    fraction: fraction,
                    track: colors.onSurface.withValues(alpha: 0.12),
                    fill: tone,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  formatPercent(fraction),
                  style: AppType.monoLabel(
                    color: fraction >= 0.6 ? tone : DshColors.of(context).textTertiary,
                    weight: FontWeight.w500,
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

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.fraction, required this.track, required this.fill});

  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.2;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = track);
    // A visible sliver even at <1%: the ring should say "in use", not "empty".
    final sweep = math.max(fraction.clamp(0.0, 1.0), 0.02) * math.pi * 2;
    canvas.drawArc(rect, -math.pi / 2, sweep, false, paint..color = fill);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.track != track || old.fill != fill;
}

/// 用量弹层:上下文窗口、本对话的 token、DeepSeek 余额。
Future<void> showUsageSheet(BuildContext context, {required String sessionId, ModelSelection? model}) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (context) => UsageSheet(sessionId: sessionId, model: model),
  );
}

/// ```
///                    ───
///   用量                                   (×)
///     上下文
///   ╭──────────────────────────────────────╮
///   │ 6%                      61.8K / 1M │
///   │ ▰▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱ │
///   │ 系统 1.5K · 工具 5.2K · 消息 54.9K    │
///   ╰──────────────────────────────────────╯
///     本对话 …          DeepSeek 余额 …
/// ```
class UsageSheet extends ConsumerWidget {
  const UsageSheet({super.key, required this.sessionId, this.model});

  final String sessionId;
  final ModelSelection? model;

  static const _margin = EdgeInsets.symmetric(horizontal: SheetTitleBar.inset);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final usage = ref.watch(sessionUsageProvider(sessionId));
    final pricing = model == null ? null : knownPricing['${model!.provider}/${model!.model}'];
    final subscription = Subscription.fromWire(model?.provider);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetTitleBar(l10n.activityUsage),
            SessionUsageSections(usage: usage, pricing: pricing, sheet: true, margin: _margin),
            const SizedBox(height: 16),
            if (subscription == null)
              BalanceCard(title: l10n.activityUsageBalance, margin: _margin)
            else if (subscription != Subscription.chatgptOfficial)
              _SubscriptionQuota(subscription: subscription, margin: _margin),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionQuota extends ConsumerWidget {
  const _SubscriptionQuota({required this.subscription, required this.margin});
  final Subscription subscription;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final profile = ref.watch(subscriptionProfileProvider(subscription));
    final currentProfile = profile.isLoading || profile.hasError ? null : profile.value;
    if (currentProfile != null && !isSubscriptionRoute(currentProfile)) {
      return BalanceCard(title: l10n.activityUsageBalance, margin: margin);
    }
    Widget message(String text) => SheetGroup(
      margin: margin,
      children: [Padding(padding: const EdgeInsets.all(16), child: Text(text))],
    );
    final body = profile.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      loading: () => message(l10n.activityQuotaLoading),
      error: (_, _) => message(l10n.activityQuotaUnavailable),
      data: (profile) {
        // A route with an API key is not a subscription, even if named anthropic.
        if (profile == null) return message(l10n.activityQuotaUnavailable);
        if (!isSubscriptionRoute(profile)) return const SizedBox.shrink();
        return ref
            .watch(subscriptionUsageProvider(subscription))
            .when(
              skipLoadingOnRefresh: false,
              skipLoadingOnReload: false,
              loading: () => message(l10n.activityQuotaLoading),
              error: (error, _) => message(
                error is DshRemoteException &&
                        (error.code == 'gateway/method-not-found' ||
                            error.code == 'gateway/not-found' ||
                            error.code == 'gateway/invocation-unavailable')
                    ? l10n.activityQuotaUnsupported
                    : l10n.activityQuotaUnavailable,
              ),
              data: (usage) {
                if (usage == null) return message(l10n.activityQuotaUnavailable);
                if (usage.status == SubscriptionUsageStatus.unavailable) {
                  return message(switch (usage.reason) {
                    'expired' || 'auth_required' => l10n.activityQuotaAuthError,
                    'permission_denied' => l10n.activityQuotaPermissionDenied,
                    'network' => l10n.activityQuotaNetworkError,
                    'rate_limited' => l10n.activityQuotaRateLimited,
                    _ => l10n.activityQuotaUnavailable,
                  });
                }
                if (usage.status == SubscriptionUsageStatus.unsupported) return message(l10n.activityQuotaUnsupported);
                if (usage.status == SubscriptionUsageStatus.notSignedIn) return message(l10n.activityQuotaSignedOut);
                return SheetGroup(
                  margin: margin,
                  children: [
                    for (final window in usage.windows)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_windowLabel(context, window)),
                            Text(l10n.activityQuotaUsed(formatPercent(window.usedPercent / 100))),
                            if (window.resetAt case final reset?) Text(_resetLabel(context, reset)),
                          ],
                        ),
                      ),
                  ],
                );
              },
            );
      },
    );
    final quota = currentProfile == null ? null : ref.watch(subscriptionUsageProvider(subscription));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetSectionLabel(
          '${subscription == Subscription.chatgpt ? 'Codex' : subscriptionLabel(subscription)} · ${l10n.activityQuotaTitle}',
          inset: margin.left,
        ),
        body,
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: margin,
            child: TextButton(
              onPressed: profile.isLoading || (quota?.isLoading ?? false)
                  ? null
                  : () {
                      if (currentProfile == null) {
                        ref.invalidate(subscriptionProfileProvider(subscription));
                      } else {
                        ref.invalidate(subscriptionUsageProvider(subscription));
                      }
                    },
              child: Text(l10n.activityQuotaRefresh),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  String _resetLabel(BuildContext context, DateTime reset) {
    final local = reset.toLocal();
    final material = MaterialLocalizations.of(context);
    return context.l10n.activityQuotaReset(
      '${material.formatFullDate(local)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}',
    );
  }

  String _windowLabel(BuildContext context, SubscriptionUsageWindow window) {
    final l10n = context.l10n;
    if (window.id == 'primary' || window.id == 'secondary') {
      if (window.windowSeconds == 18000) return l10n.activityQuotaFiveHour;
      if (window.windowSeconds == 604800) return l10n.activityQuotaSevenDay;
    }
    return switch (window.id) {
      'primary' => l10n.activityQuotaPrimary,
      'secondary' => l10n.activityQuotaSecondary,
      'five_hour' => l10n.activityQuotaFiveHour,
      'seven_day' => l10n.activityQuotaSevenDay,
      'seven_day_sonnet' => l10n.activityQuotaSevenDaySonnet,
      'seven_day_opus' => l10n.activityQuotaSevenDayOpus,
      _ => window.id,
    };
  }
}

/// 上下文窗口 + 本对话 token 两块(用量弹层与对话详情共用)。
///
/// 页面里(默认)沿用 [SheetGroup] 自带的组标题,与页面上其他分组一致;
/// 弹层里传 [margin](20)和 `sheet: true`,组标题换成弹层的小而淡的
/// [SheetSectionLabel],块与块之间 16。
class SessionUsageSections extends StatelessWidget {
  const SessionUsageSections({
    super.key,
    required this.usage,
    this.pricing,
    this.sheet = false,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
  });

  final SessionUsage usage;
  final TokenPricing? pricing;
  final bool sheet;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sections = [
      (l10n.activityUsageContext, _ContextSection(usage: usage)),
      (l10n.activityUsageChat, _TokenSection(usage: usage, pricing: pricing)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, (title, body)) in sections.indexed)
          if (sheet) ...[
            if (i > 0) const SizedBox(height: 16),
            SheetSectionLabel(title, inset: margin.left),
            SheetGroup(margin: margin, children: [body]),
          ] else
            SheetGroup(title: title, margin: margin, children: [body]),
      ],
    );
  }
}

/// 一个数:数字是等宽数字,后面的单位(`K`、`M`、`%`)小一号、次要色。
/// `71K` → **71** K;`¥110.00` → ¥ **110.00**。纯文本仍是原字符串。
class UsageFigure extends StatelessWidget {
  const UsageFigure(this.text, {super.key, required this.style, this.color});

  final String text;
  final TextStyle style;
  final Color? color;

  static final _parts = RegExp(r'^([^\d<]*)([<\d][\d.,]*)(.*)$');

  @override
  Widget build(BuildContext context) {
    final unitStyle = TextStyle(
      fontSize: (style.fontSize ?? 20) * 0.6,
      fontWeight: FontWeight.w400,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final match = _parts.firstMatch(text);
    final strong = AppType.tabular(style.copyWith(color: color));
    if (match == null) return Text(text, style: strong, maxLines: 1);
    final (lead, number, tail) = (match[1]!, match[2]!, match[3]!);
    return Text.rich(
      TextSpan(
        children: [
          if (lead.isNotEmpty) TextSpan(text: lead, style: unitStyle),
          TextSpan(text: number),
          if (tail.isNotEmpty) TextSpan(text: tail, style: unitStyle),
        ],
      ),
      style: strong,
      maxLines: 1,
      softWrap: false,
    );
  }
}

class _ContextSection extends StatelessWidget {
  const _ContextSection({required this.usage});

  final SessionUsage usage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final window = usage.contextWindow;
    final tokens = usage.contextTokens;
    final fraction = usage.contextFraction;

    final breakdown = [
      if (usage.systemTokens case final n? when n > 0) l10n.activityUsageSystemTokens(formatTokens(n)),
      if (usage.toolsTokens case final n? when n > 0) l10n.activityUsageToolTokens(formatTokens(n)),
      if (usage.messageTokens case final n? when n > 0) l10n.activityUsageMessageTokens(formatTokens(n)),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: fraction == null || window == null
          ? Text(l10n.activityUsageWaiting, style: theme.textTheme.bodyMedium?.copyWith(color: dsh.textTertiary))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  usage.projectedTokens != null ? l10n.activityUsageProjected : l10n.activityUsageLastRequest,
                  style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    UsageFigure(
                      formatPercent(fraction),
                      style: theme.textTheme.headlineMedium!.copyWith(fontWeight: FontWeight.w500, height: 1.2),
                      color: fraction >= 0.6 ? contextTone(context, fraction) : colors.onSurface,
                    ),
                    const Spacer(),
                    Text(
                      '${formatTokens(tokens ?? 0)} / '
                      '${formatTokens(window)}',
                      style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.onSurfaceVariant)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _Bar(fraction: fraction, color: contextTone(context, fraction)),
                if (breakdown.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    breakdown.join(' · '),
                    style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: dsh.textTertiary)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.activityUsageBreakdownEstimate,
                    style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                  ),
                ],
                if (fraction > 0.85) ...[
                  const SizedBox(height: 6),
                  Text(l10n.activityUsageContextFull, style: theme.textTheme.bodySmall?.copyWith(color: dsh.warning)),
                ],
              ],
            ),
    );
  }
}

/// 6 高的细条;占用变化时平滑走到新位置。
class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final fill = fraction <= 0 ? 0.0 : math.max(width * fraction, 6.0);
        return Container(
          height: 6,
          decoration: ShapeDecoration(color: track, shape: const StadiumBorder()),
          alignment: Alignment.centerLeft,
          child: AnimatedContainer(
            duration: AppMotion.of(context, AppMotion.standard),
            curve: AppMotion.std,
            width: math.min(fill, width),
            decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
          ),
        );
      },
    );
  }
}

class _TokenSection extends StatelessWidget {
  const _TokenSection({required this.usage, this.pricing});

  final SessionUsage usage;
  final TokenPricing? pricing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final hit = usage.cacheHitRate;
    final pricing = this.pricing;
    final notes = [
      if (usage.turns case final turns? when turns > 0) l10n.activityUsageTurns(turns),
      if (usage.cacheWrite > 0) l10n.activityUsageCacheWriteTokens(formatTokens(usage.cacheWrite)),
      if (pricing != null)
        l10n.activityUsageEstimatedCost(
          pricing.currency == 'USD' ? r'$' : '¥',
          estimateCost(usage, pricing).toStringAsFixed(4),
        ),
      l10n.activityUsageInputIncludesCache,
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _Stat(label: l10n.activityUsageCumulativeInput, value: formatTokens(usage.input)),
              ),
              Expanded(
                child: _Stat(label: l10n.activityOutput, value: formatTokens(usage.output)),
              ),
              Expanded(
                child: _Stat(label: l10n.activityCacheHit, value: hit == null ? '—' : formatPercent(hit)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(notes.join(' · '), style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UsageFigure(
          value,
          style: theme.textTheme.titleLarge!.copyWith(fontSize: 20, height: 1.3, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 2),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary)),
      ],
    );
  }
}
