// The first-run question 「DSH 在哪里运行？」 — on this phone (install the runtime) or
// on a remote host — with what each costs.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../performance/performance_state.dart';
import '../../runtime/local_footprint.dart';
import '../../runtime/runtime_state.dart';
import '../common/pressable.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'onboarding_scaffold.dart';

/// Where DSH runs.
enum RuntimeOption { local, remote }

/// Two option cards and one 「继续」:
///
/// ```
///   ▣  DSH 在哪里运行？
///      之后可以在设置里更改
///
///   ╭──────────────────────────────────╮
///   │ [▯]  本机                     ◉  │   ring + filled radio when chosen
///   │      约 750 MB 存储 · …          │
///   ╰──────────────────────────────────╯
///   ╭──────────────────────────────────╮
///   │ [▭]  远程主机  推荐           ○  │   「推荐」 only on a phone short of
///   │      连接电脑或服务器上的 DSH    │    memory or storage
///   ╰──────────────────────────────────╯
///
///   (            继续            )
/// ```
///
/// The figures come from the device and the bundled manifest
/// ([localFootprintProvider]). The suggested card starts chosen until the
/// person picks one. A build without the native runtime
/// ([LocalRuntimeState.available]) greys 本机 out and goes on with 远程主机.
class RuntimeChoiceView extends ConsumerStatefulWidget {
  const RuntimeChoiceView({super.key, required this.onLocal, required this.onRemote, this.leading});

  final VoidCallback onLocal;
  final VoidCallback onRemote;

  /// Top-left key, as [OnboardingScaffold.leading].
  final Widget? leading;

  @override
  ConsumerState<RuntimeChoiceView> createState() => _RuntimeChoiceViewState();
}

class _RuntimeChoiceViewState extends ConsumerState<RuntimeChoiceView> {
  RuntimeOption? _picked;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final footprint = ref.watch(localFootprintProvider).value;
    final light = ref.watch(performanceDefaultsProvider).recommendRemote;
    final available = ref.watch(localRuntimeProvider.select((s) => s.available));
    final suggested = !available || light || footprint?.suggestRemote == true
        ? RuntimeOption.remote
        : RuntimeOption.local;
    final selected = available ? _picked ?? suggested : RuntimeOption.remote;
    final colors = DshColors.of(context);

    final String localDetail;
    var localWarn = false;
    if (!available) {
      localDetail = l10n.localEnvUnavailable;
    } else if (footprint != null && footprint.lowStorage) {
      localDetail = l10n.localEnvLowStorage(footprint.requiredRoundedMb!);
      localWarn = true;
    } else if (footprint?.unpackedMb case final unpacked?) {
      localDetail = l10n.localEnvThisPhoneDetail(LocalFootprint.round(unpacked), LocalFootprint.engineMemoryMb);
    } else {
      localDetail = l10n.localEnvThisPhoneDetailShort(LocalFootprint.engineMemoryMb);
    }

    return OnboardingScaffold(
      leading: widget.leading,
      children: [
        const Spacer(),
        OnboardingHeader(
          icon: AppIcons.remoteHost,
          title: l10n.localEnvChooseTitle,
          message: l10n.localEnvChooseMessage,
        ),
        const SizedBox(height: 28),
        RuntimeOptionCard(
          key: const ValueKey('runtime-option-local'),
          icon: AppIcons.thisPhone,
          title: l10n.commonThisPhone,
          detail: localDetail,
          detailColor: localWarn ? colors.warning : null,
          selected: selected == RuntimeOption.local,
          onTap: available ? () => setState(() => _picked = RuntimeOption.local) : null,
        ),
        const SizedBox(height: RuntimeOptionCard.gap),
        RuntimeOptionCard(
          key: const ValueKey('runtime-option-remote'),
          icon: AppIcons.computer,
          title: l10n.commonRemoteHost,
          detail: light ? l10n.performanceRemoteHint : l10n.localEnvRemoteDetail,
          recommended: available && suggested == RuntimeOption.remote,
          selected: selected == RuntimeOption.remote,
          onTap: () => setState(() => _picked = RuntimeOption.remote),
        ),
        const Spacer(flex: 2),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: selected == RuntimeOption.local ? widget.onLocal : widget.onRemote,
          child: Text(l10n.commonContinue),
        ),
      ],
    );
  }
}

/// One choice: a 40 glyph tile, title (with an optional 「推荐」 tag) over
/// one line of detail, and a radio mark. [pad] on every side, so the glyph
/// and the mark sit the same distance from their edges; the ring is drawn
/// inside the edge and moves nothing.
class RuntimeOptionCard extends StatelessWidget {
  const RuntimeOptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    required this.selected,
    this.onTap,
    this.recommended = false,
    this.detailColor,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool selected;
  final bool recommended;

  /// Null: shown but not choosable, dimmed.
  final VoidCallback? onTap;
  final Color? detailColor;

  static const pad = 16.0;
  static const glyph = 40.0;
  static const mark = 22.0;
  static const gap = 12.0;

  /// The ring round the chosen card.
  static const ring = 2.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final duration = AppMotion.of(context, AppMotion.quick);
    final fill = dark ? Colors.white.withValues(alpha: 0.05) : scheme.onSurface.withValues(alpha: 0.04);
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: [title, if (recommended) l10n.localEnvRecommended, detail].join(', '),
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        enabled: onTap != null,
        child: AnimatedContainer(
          duration: duration,
          curve: AppMotion.std,
          padding: const EdgeInsets.all(pad),
          decoration: ShapeDecoration(
            color: fill,
            shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
          ),
          foregroundDecoration: ShapeDecoration(
            shape: RoundedSuperellipseBorder(
              borderRadius: AppShape.radiusLg,
              side: BorderSide(
                color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: dark ? 0.5 : 0.7),
                width: selected ? ring : 1,
                strokeAlign: BorderSide.strokeAlignInside,
              ),
            ),
          ),
          child: Opacity(
            opacity: onTap == null ? 0.45 : 1,
            child: Row(
              children: [
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: dark ? Colors.white.withValues(alpha: 0.07) : scheme.onSurface.withValues(alpha: 0.06),
                    shape: Squircle.border(AppShape.sm),
                  ),
                  child: SizedBox.square(
                    dimension: glyph,
                    child: Icon(icon, size: 22, color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          if (recommended) ...[const SizedBox(width: 8), _Tag(l10n.localEnvRecommended)],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: theme.textTheme.bodySmall?.copyWith(color: detailColor ?? colors.textTertiary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                AnimatedSwitcher(
                  duration: duration,
                  child: Icon(
                    selected ? AppIcons.radioOn : AppIcons.radioOff,
                    key: ValueKey(selected),
                    size: mark,
                    color: selected ? scheme.primary : colors.textTertiary,
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

/// A small soft tag beside a title (小标签, radius 8).
class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(color: scheme.primaryContainer, shape: Squircle.border(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onPrimaryContainer,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
        ),
      ),
    );
  }
}
