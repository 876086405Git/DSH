// 伙伴小屋's fixed place in the conversations drawer: under the search bar, above
// every list and filter, so she is one tap away whichever workspace or host is
// showing, and even with no host at all.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_residency.dart';
import '../../companion/companion_state.dart';
import '../../l10n/l10n.dart';
import '../common/status_dot.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

class CompanionDrawerRow extends ConsumerWidget {
  const CompanionDrawerRow({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final name = ref.watch(companionNameProvider);
    final status = ref.watch(companionResidencyProvider);
    final here = status.available && status.enabled && status.running;
    final title = name ?? l10n.companionTitle;
    final subtitle = here ? l10n.companionDrawerHere : (name == null ? null : l10n.companionDrawerRoom);
    final shape = Squircle.border(AppShape.md);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: Semantics(
        button: true,
        label: [title, ?subtitle].join(l10n.shellSemanticsSeparator),
        onTap: onTap,
        excludeSemantics: true,
        child: Material(
          color: scheme.onSurface.withValues(alpha: 0.04),
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: shape,
            child: SizedBox(
              height: 54,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    // Her little window onto the water.
                    Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFF2A6497), Color(0xFF0D2F55)],
                        ),
                      ),
                      child: const Icon(AppIcons.pet, size: 18, color: Color(0xFFCDEBFA)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontSize: 15,
                              height: 1.3,
                              color: scheme.onSurface,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(color: colors.textTertiary, height: 1.3),
                            ),
                        ],
                      ),
                    ),
                    if (here) ...[const SizedBox(width: 10), const StatusDot(tone: StatusTone.ok, size: 7)],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
