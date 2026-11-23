// 伙伴小屋's fixed place in the conversations drawer: under the search bar, above
// every list and filter, so she is one tap away whichever workspace or host is
// showing, and even with no host at all. It goes by her name.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_float.dart';
import '../../companion/companion_residency.dart';
import '../../companion/companion_state.dart';
import '../../l10n/l10n.dart';
import '../common/status_dot.dart';
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
    // What she's called: the name you gave her, else her pack's own.
    final name = ref.watch(companionNameProvider) ?? ref.watch(companionPackNameProvider).value;
    final status = ref.watch(companionResidencyProvider);
    final here = status.available && status.enabled && status.running;
    final title = name ?? l10n.companionTitle;
    final shape = Squircle.border(AppShape.md);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      child: Semantics(
        button: true,
        label: [title, if (here) l10n.companionDrawerHere].join(l10n.shellSemanticsSeparator),
        onTap: onTap,
        excludeSemantics: true,
        // A row on the list's own grid, not a card: the search bar above stays
        // the drawer's one box, and her seal starts on the 20 line.
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            customBorder: shape,
            child: SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    CompanionSeal(name: name, size: 30),
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
                          if (here)
                            Text(
                              l10n.companionDrawerHere,
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

/// Her seal: the first character of her name on a disc of deep water, lit
/// from above with a thin rim, the way a name is carved rather than drawn.
/// With no name yet, a small crescent of light stands in for it.
class CompanionSeal extends StatelessWidget {
  const CompanionSeal({super.key, this.name, this.size = 34});

  final String? name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final mark = name?.trim().characters.firstOrNull;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2E6C9E), Color(0xFF0B2643)],
        ),
        border: Border.all(color: const Color(0x33CDEBFA), width: 0.8),
        boxShadow: const [BoxShadow(color: Color(0x260B2643), blurRadius: 6, offset: Offset(0, 2))],
      ),
      alignment: Alignment.center,
      child: mark == null
          ? CustomPaint(size: Size.square(size * 0.42), painter: const _Crescent())
          : Text(
              mark,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontSize: size * 0.46,
                height: 1,
                fontWeight: FontWeight.w500,
                color: const Color(0xFFE4F3FB),
              ),
            ),
    );
  }
}

class _Crescent extends CustomPainter {
  const _Crescent();

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final moon = Path()..addOval(Rect.fromCircle(center: Offset(r, r), radius: r));
    final bite = Path()..addOval(Rect.fromCircle(center: Offset(r * 1.45, r * 0.75), radius: r * 0.85));
    canvas.drawPath(Path.combine(PathOperation.difference, moon, bite), Paint()..color = const Color(0xFFE4F3FB));
  }

  @override
  bool shouldRepaint(_Crescent oldDelegate) => false;
}
