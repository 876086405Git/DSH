import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/ask_ai.dart' show askAiAvailableProvider;
import '../common/app_sheet.dart';
import '../common/ask_ai.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// How the disclosure was left (null: dragged away).
enum PhoneDisclosureAnswer { agree, notNow, ask }

/// The 显著披露 before 「手机操控」 is first turned on: what is read, when, who
/// gets it, and what DSH never does. Resolves true on 「同意并开启」;
/// 「不确定？问 AI」 resolves false and opens the question in a new chat.
/// [harmony]: the same sheet for 系统操作, which reads nothing off the screen.
Future<bool> showPhoneDisclosure(BuildContext context, {bool harmony = false}) async {
  final answer = await showAppSheet<PhoneDisclosureAnswer>(
    context,
    isScrollControlled: true,
    builder: (sheet) => PhoneDisclosureSheet(harmony: harmony),
  );
  if (answer == PhoneDisclosureAnswer.ask && context.mounted) {
    unawaited(askAi(context, AskAiTopic.phoneControl));
  }
  return answer == PhoneDisclosureAnswer.agree;
}

class PhoneDisclosureSheet extends ConsumerWidget {
  const PhoneDisclosureSheet({super.key, this.harmony = false});

  final bool harmony;

  static List<(IconData, int, String, String)> get items => [
    (AppIcons.readText, 0, appL10n.phoneDisclosureWhatTitle, appL10n.phoneDisclosureWhatBody),
    (AppIcons.time, 2, appL10n.phoneDisclosureWhenTitle, appL10n.phoneDisclosureWhenBody),
    (AppIcons.cloud, 6, appL10n.phoneDisclosureWhoTitle, appL10n.phoneDisclosureWhoBody),
    (AppIcons.blocked, 3, appL10n.phoneDisclosureNeverTitle, appL10n.phoneDisclosureNeverBody),
    (AppIcons.operate, 5, appL10n.phoneDisclosureStopTitle, appL10n.phoneDisclosureStopBody),
  ];

  static List<(IconData, int, String, String)> get harmonyItems => [
    (AppIcons.operate, 0, appL10n.systemActionsDisclosureWhatTitle, appL10n.systemActionsDisclosureWhatBody),
    (AppIcons.time, 2, appL10n.systemActionsDisclosureWhenTitle, appL10n.systemActionsDisclosureWhenBody),
    (AppIcons.cloud, 6, appL10n.systemActionsDisclosureWhoTitle, appL10n.systemActionsDisclosureWhoBody),
    (AppIcons.blocked, 3, appL10n.systemActionsDisclosureNeverTitle, appL10n.systemActionsDisclosureNeverBody),
    (AppIcons.lock, 5, appL10n.systemActionsDisclosureStopTitle, appL10n.systemActionsDisclosureStopBody),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    // The question it would ask is about reading the screen.
    final canAsk = !harmony && ref.watch(askAiAvailableProvider);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(harmony ? l10n.systemActionsDisclosureTitle : l10n.phoneDisclosureTitle),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
                    child: Text(
                      harmony ? l10n.systemActionsDisclosureIntro : l10n.phoneDisclosureIntro,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  SheetGroup(
                    children: [
                      for (final (icon, tint, title, text) in harmony ? harmonyItems : items)
                        _Item(icon: icon, tint: tint, title: title, text: text),
                    ],
                  ),
                  if (!harmony)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(kSheetGutter, 10, kSheetGutter, 0),
                      child: Text(
                        l10n.phoneDisclosureRestartNote,
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(kSheetGutter, 16, kSheetGutter, canAsk ? 0 : 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => Navigator.pop(context, PhoneDisclosureAnswer.notNow),
                    child: Text(l10n.phoneDisclosureNotNow),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: () => Navigator.pop(context, PhoneDisclosureAnswer.agree),
                    child: Text(l10n.phoneDisclosureAgreeEnable),
                  ),
                ),
              ],
            ),
          ),
          if (canAsk)
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 6, kSheetGutter, 6),
              child: Center(child: AskAiLink(onPressed: () => Navigator.pop(context, PhoneDisclosureAnswer.ask))),
            ),
        ],
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.icon, required this.tint, required this.title, required this.text});

  final IconData icon;
  final int tint;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 32, height: 22, child: Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall?.copyWith(fontSize: 15, height: 1.45)),
                  const SizedBox(height: 2),
                  Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
