// The overview card at the top of hub pages (settings, phone control): the one
// thing on the page that matters most, at a glance.

import 'package:flutter/material.dart';

import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'pressable.dart';
import 'status_chip.dart';

/// 枢纽页的概览卡外壳。
///
/// ```
/// ┌──────────────────────────────────────────────┐
/// │ ( 52 )  标题                              ›  │  ← onTap(整块)
/// │         副标题                               │
/// │ ──────────────────────────────────────────── │  ← 细分隔(仅有 footer 时)
/// │   ●     引擎 · 运行中 · DSH 0.2.1          ›  │  ← footer,onFooterTap
/// └──────────────────────────────────────────────┘
/// ```
///
/// 几何(量过,改动时同步 `test/settings/settings_geometry_test.dart`):
/// - 头像位 [avatarSize] 距卡片左、上、下都是 [inset];
/// - 尾部(箭头字形 / 开关轨道)右缘距卡片右缘 [inset];
/// - footer 的前导(色点)以头像位的中线为中心,footer 文字与标题左对齐;
/// - 按下整卡缩到 0.97(共用的 `Pressable`,关闭动画时不缩)。
///
/// 用法:
/// ```dart
/// OverviewCard(
///   leading: OverviewGlyph(AppIcons.phoneControl, tint: 6),
///   title: const Text('手机操控'),
///   subtitle: const Text('可以操作手机'),
///   trailing: Switch.adaptive(value: on, onChanged: ...),   // 不传且有 onTap 时画箭头
///   onTap: ...,
///   footer: OverviewFooter(tone: StatusTone.ok, text: '无障碍已开启'),
///   onFooterTap: ...,
/// )
/// ```
class OverviewCard extends StatefulWidget {
  const OverviewCard({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.footer,
    this.onFooterTap,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 24),
    this.semanticLabel,
  });

  /// The avatar slot, laid out in an [avatarSize] square: [OverviewGlyph], an
  /// account avatar, a brand mark.
  final Widget leading;

  /// First line (titleMedium).
  final Widget title;

  /// Second line (bodyMedium, secondary colour): a balance, one short state.
  final Widget? subtitle;

  /// Replaces the chevron, e.g. a master switch.
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Bottom status strip under a hairline, e.g. [OverviewFooter].
  final Widget? footer;
  final VoidCallback? onFooterTap;
  final EdgeInsetsGeometry margin;

  /// Read for the top part instead of its texts (e.g. "DeepSeek 账号：雾蓝").
  final String? semanticLabel;

  static const avatarSize = 52.0;
  static const inset = 16.0;

  /// Avatar → text.
  static const gap = 14.0;

  /// Footer strip height (single line at 1.0 text scale).
  static const footerHeight = 44.0;

  /// Where title and footer text start, from the card's left edge.
  static const textStart = inset + avatarSize + gap;

  @override
  State<OverviewCard> createState() => _OverviewCardState();
}

class _OverviewCardState extends State<OverviewCard> {
  /// The card without its margin: where a page opened from it grows from.
  final _cardKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    const inset = OverviewCard.inset;
    const avatarSize = OverviewCard.avatarSize;
    const gap = OverviewCard.gap;
    final widget = this.widget;
    final onTap = switch (widget.onTap) {
      final open? => () {
        CardOrigin.remember(_cardKey.currentContext ?? context);
        open();
      },
      null => null,
    };
    final onFooterTap = widget.onFooterTap;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final highlight = scheme.onSurface.withValues(alpha: 0.05);

    Widget tappable(Widget child, VoidCallback? onTap) => onTap == null
        ? child
        : InkWell(onTap: onTap, splashFactory: rowSplash(context), highlightColor: highlight, child: child);

    Widget chevron() => const OverviewChevron();

    final head = Padding(
      padding: const EdgeInsets.fromLTRB(inset, inset, 12, inset),
      child: Row(
        children: [
          SizedBox.square(
            dimension: avatarSize,
            child: Center(child: widget.leading),
          ),
          const SizedBox(width: gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                DefaultTextStyle.merge(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(color: scheme.onSurface),
                  child: widget.title,
                ),
                if (widget.subtitle case final subtitle?) ...[
                  const SizedBox(height: 2),
                  DefaultTextStyle.merge(
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.tabular(theme.textTheme.bodyMedium!.copyWith(color: scheme.onSurfaceVariant)),
                    child: subtitle,
                  ),
                ],
              ],
            ),
          ),
          if (widget.trailing case final trailing?) ...[
            const SizedBox(width: 8),
            SwitchTheme(
              data: SwitchTheme.of(context).copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: trailing,
            ),
          ] else if (onTap != null) ...[
            const SizedBox(width: 4),
            chevron(),
          ],
        ],
      ),
    );
    Widget top = tappable(head, onTap);
    if (widget.semanticLabel case final label?) {
      top = Semantics(button: onTap != null, label: label, excludeSemantics: widget.trailing == null, child: top);
    }

    final footer = widget.footer;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        top,
        if (footer != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: inset),
            child: SizedBox(
              height: 0.5,
              child: ColoredBox(
                // A hairline as quiet as the card's own edge, a touch firmer.
                color: theme.brightness == Brightness.dark
                    ? Colors.white.withValues(alpha: 0.08)
                    : scheme.onSurface.withValues(alpha: 0.08),
              ),
            ),
          ),
          tappable(
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: OverviewCard.footerHeight),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
                child: DefaultTextStyle.merge(
                  style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: scheme.onSurfaceVariant)),
                  child: Row(
                    children: [
                      Expanded(child: footer),
                      if (onFooterTap != null) ...[const SizedBox(width: 4), chevron()],
                    ],
                  ),
                ),
              ),
            ),
            onFooterTap,
          ),
        ],
      ],
    );

    return Padding(
      padding: widget.margin,
      child: Pressable(
        key: _cardKey,
        // Feedback only: the two parts below own their taps.
        enabled: onTap != null || onFooterTap != null,
        child: GlassSurface(
          tier: GlassTier.card,
          borderRadius: AppShape.radiusLg,
          child: Material(
            type: MaterialType.transparency,
            clipBehavior: Clip.antiAlias,
            shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// The footer line of an [OverviewCard]: a status dot centred under the avatar
/// slot, then one line of text lined up with the title.
///
/// ```dart
/// OverviewFooter(tone: StatusTone.ok, text: '引擎 · 运行中 · DSH 0.2.1')
/// ```
class OverviewFooter extends StatelessWidget {
  const OverviewFooter({super.key, required this.tone, required this.text, this.leading});

  final StatusTone tone;
  final String text;

  /// Replaces the dot (e.g. a small icon); centred in the avatar column.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    return Row(
      children: [
        SizedBox(
          width: OverviewCard.inset + OverviewCard.avatarSize,
          child: Padding(
            padding: const EdgeInsets.only(left: OverviewCard.inset),
            child: Center(child: leading ?? AnimatedStatusDot(tone: tone, size: 8)),
          ),
        ),
        const SizedBox(width: OverviewCard.gap),
        Expanded(
          child: AnimatedSwitcher(
            duration: duration,
            switchInCurve: AppMotion.std,
            switchOutCurve: AppMotion.std,
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
            child: Text(text, key: ValueKey(text), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
    );
  }
}

/// The round tinted glyph for an [OverviewCard]'s avatar slot (one of the 8
/// identity pairs, like the settings row icons, at hub size).
class OverviewGlyph extends StatelessWidget {
  const OverviewGlyph(this.icon, {super.key, this.tint = 0, this.size = OverviewCard.avatarSize});

  final IconData icon;
  final int tint;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final i = tint % colors.identity.length;
    return DecoratedBox(
      decoration: ShapeDecoration(color: colors.identity[i], shape: const CircleBorder()),
      child: SizedBox.square(
        dimension: size,
        child: Icon(icon, size: size * 0.46, color: colors.onIdentity[i]),
      ),
    );
  }
}

/// Row chevron with its optical correction: the glyph's ink sits 7dp inside its
/// 20dp box on the right, so it is nudged 3dp outward to end where a switch
/// track ends (16dp from the card edge with 12dp row padding).
class OverviewChevron extends StatelessWidget {
  const OverviewChevron({super.key});

  /// How far the drawn chevron is moved right.
  static const nudge = 3.0;

  /// Rightmost ink of the 20dp Material chevron inside its box.
  static const inkRight = 15.58 / 24 * 20;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(nudge, 0),
      child: ExcludeSemantics(child: Icon(AppIcons.disclosure, size: 20, color: DshColors.of(context).textTertiary)),
    );
  }
}
