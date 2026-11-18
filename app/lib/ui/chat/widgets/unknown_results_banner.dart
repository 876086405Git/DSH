// Says that a session's tool calls never came back, and lets the user go on. Draws nothing
// otherwise.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../../state/connection_state.dart';
import '../../../state/unknown_results.dart';
import '../../common/brief_notice.dart';
import '../../common/risk_notice.dart';
import 'notice_row.dart';

class UnknownResultsBanner extends ConsumerWidget {
  const UnknownResultsBanner({super.key, required this.sessionId, this.padding = EdgeInsets.zero});

  final String sessionId;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A turn can end with a call unaccounted for, with no reconnection to prompt a read.
    ref.listen(chatProvider(sessionId).select((chat) => (running: chat.running, error: chat.error)), (was, now) {
      // A lifecycle gate may reject a prompt before running ever becomes true.
      // Refresh the recovery entry on that error as well as on turn completion.
      if ((was?.running == true && !now.running) || (now.error != null && was?.error != now.error)) {
        ref.invalidate(unknownResultsProvider(sessionId));
      }
    });
    final state = ref.watch(unknownResultsProvider(sessionId)).value;
    if (state == null || (!state.pending && !state.blocked)) return const SizedBox.shrink();
    final l10n = context.l10n;
    return Padding(
      padding: padding,
      // The engine's own fault comes first: going on can't get past it.
      child: state.blocked
          ? ErrorBanner(message: l10n.harmonyCallsNotRecorded)
          : ErrorBanner(
              message: l10n.harmonyUnknownResults,
              action: (
                label: l10n.harmonyUnknownResultsReview,
                onPressed: () => unawaited(_review(context, ref, state)),
              ),
            ),
    );
  }

  Future<void> _review(BuildContext context, WidgetRef ref, UnknownResults seen) async {
    final l10n = context.l10n;
    final connection = ref.read(activeConnectionProvider).value;
    var current = connection?.client == seen.client && connection?.isLocal == true;
    // Keep an invalidation latched even if the user switches away and back while
    // the sheet or the fresh lifecycle read is waiting.
    final owner = ref.listenManual(activeConnectionProvider, (_, next) {
      if (next.isLoading || next.hasError || !identical(next.value, connection)) current = false;
    });
    bool isCurrent() {
      if (!context.mounted || !current) return false;
      final active = ref.read(activeConnectionProvider);
      return !active.isLoading && !active.hasError && identical(active.value, connection);
    }

    try {
      final goOn = await confirmRisk(
        context,
        RiskNotice(
          id: 'unknown-results',
          level: RiskLevel.high,
          title: l10n.harmonyUnknownResultsTitle,
          body: l10n.harmonyUnknownResultsBody(seen.toolNames.join(' · ')),
          action: l10n.harmonyUnknownResultsContinue,
        ),
      );
      if (!goOn || !context.mounted) return;
      String? notice;
      try {
        if (await abandonUnknownResults(seen, isCurrent: isCurrent) == AbandonOutcome.changed) {
          notice = l10n.harmonyUnknownResultsChanged;
        }
      } on DshException {
        // The answer may be what got lost, so what happened comes from the next read.
        notice = l10n.harmonyUnknownResultsFailed;
      }
      if (!context.mounted) return;
      ref.invalidate(unknownResultsProvider(sessionId));
      if (notice != null) showBriefNotice(context, notice);
    } finally {
      owner.close();
    }
  }
}
