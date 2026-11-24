// 伙伴小屋's fixed place in the conversations drawer: under the search bar, above
// every list and filter, so she is one tap away whichever workspace or host is
// showing, and even with no host at all. It goes by her name, on the list's
// text line, and keeps its right side for what she has in hand: the next thing
// she'll remind you of, else that she's always here.

import 'dart:async';

import 'package:dsh_client/companion.dart' show CompanionTaskStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../companion/companion_float.dart';
import '../../companion/companion_memory.dart';
import '../../companion/companion_residency.dart';
import '../../companion/companion_state.dart';
import '../../l10n/l10n.dart';
import '../common/status_dot.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// When her next reminder is due (epoch ms), or null. Only read once she has a
/// pack: the drawer never creates her memory for someone who never met her.
final companionNextReminderProvider = FutureProvider.autoDispose<int?>((ref) async {
  if (await ref.watch(companionPackNameProvider.future) == null) return null;
  final root = '${(await getApplicationSupportDirectory()).path}/companion';
  final memory = await ref.watch(companionMemoryOwnerProvider(root).future);
  // Her memory says when a reminder is added, changed or done.
  memory.addListener(ref.invalidateSelf);
  ref.onDispose(() => memory.removeListener(ref.invalidateSelf));
  final now = DateTime.now().millisecondsSinceEpoch;
  int? next;
  for (final task in memory.store.tasks(limit: 100)) {
    final due = task['epoch_ms'];
    if (task['kind'] != 'phone.reminder' || due is! int || due <= now) continue;
    // Set on the phone ('done') counts as much as still on its way there.
    if (!const {'queued', 'waiting', 'done'}.contains(task['state']) || task['cancel_requested'] == 1) continue;
    if (next == null || due < next) next = due;
  }
  // Due passes by itself: look again then.
  if (next != null) {
    final timer = Timer(Duration(milliseconds: next - now + 1000), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }
  return next;
});

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
    final reminder = ref.watch(companionNextReminderProvider).value;
    final title = name ?? l10n.companionTitle;
    final note = switch (reminder) {
      final due? => _reminderText(context, DateTime.fromMillisecondsSinceEpoch(due)),
      _ when here => l10n.companionDrawerHere,
      _ => null,
    };
    final shape = Squircle.border(AppShape.md);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      child: Semantics(
        button: true,
        label: [title, ?note].join(l10n.shellSemanticsSeparator),
        onTap: onTap,
        excludeSemantics: true,
        // A row on the list's own grid, not a card: the search bar above stays
        // the drawer's one box, and her name sits on the 20 line.
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            customBorder: shape,
            // Grows with enlarged text instead of clipping it.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontSize: 15,
                          height: 1.4,
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (note != null) ...[
                      const SizedBox(width: 10),
                      if (reminder != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 5),
                          child: Icon(AppIcons.reminder, size: 14, color: colors.textTertiary),
                        )
                      else
                        const Padding(
                          padding: EdgeInsets.only(right: 7),
                          child: StatusDot(tone: StatusTone.ok, size: 6),
                        ),
                      Text(
                        note,
                        maxLines: 1,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.textTertiary,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 「19:00 提醒你」 today, 「明天 9:00」, then the date.
  static String _reminderText(BuildContext context, DateTime due) {
    final l10n = context.l10n;
    final now = DateTime.now();
    final time = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(due), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
    final days = DateTime(due.year, due.month, due.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    return switch (days) {
      0 => l10n.companionDrawerReminderToday(time),
      1 => l10n.companionDrawerReminderTomorrow(time),
      _ => l10n.companionDrawerReminderLater(l10n.monthDay(due)),
    };
  }
}
