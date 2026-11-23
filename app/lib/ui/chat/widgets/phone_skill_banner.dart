import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/phone_skills_state.dart';
import '../../../state/phone_state.dart';
import '../../common/brief_notice.dart';
import '../../phone/phone_skills_page.dart';

/// Above the composer of the chat a phone task ran in (docs/design/phone-skills.md
/// §6.4): the skill DSH drafted from it, to accept, edit or discard; and a
/// short note when one of its skills is promoted or turned off. Draws nothing
/// off Android or without a draft from this chat.
class PhoneSkillBanner extends ConsumerStatefulWidget {
  const PhoneSkillBanner({super.key, required this.sessionId, this.padding = EdgeInsets.zero});

  final String sessionId;
  final EdgeInsets padding;

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  ConsumerState<PhoneSkillBanner> createState() => _PhoneSkillBannerState();
}

class _PhoneSkillBannerState extends ConsumerState<PhoneSkillBanner> {
  StreamSubscription<PhoneSkillEvent>? _outcomes;

  /// Once the native side has answered (its event channel exists), outcomes for this chat.
  void _listen() {
    _outcomes ??= ref.read(phoneChannelProvider).skillEvents.listen((event) {
      if (event is PhoneSkillOutcomeEvent && event.from.sessionId == widget.sessionId) _note(event);
    });
  }

  @override
  void dispose() {
    unawaited(_outcomes?.cancel());
    super.dispose();
  }

  void _note(PhoneSkillOutcomeEvent event) {
    if (!mounted) return;
    final l10n = context.l10n;
    final suspended = event.change == PhoneSkillChange.suspended;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        // A screen reader needs the time to reach 「恢复」.
        persist: MediaQuery.of(context).accessibleNavigation,
        showCloseIcon: MediaQuery.of(context).accessibleNavigation,
        content: Text(suspended ? l10n.phoneSkillSuspended(event.display) : l10n.phoneSkillPromoted(event.display)),
        action: suspended
            ? SnackBarAction(label: l10n.phoneSkillTurnOn, onPressed: () => unawaited(_turnOn(event.name)))
            : null,
      ),
    );
  }

  Future<void> _turnOn(String name) async {
    try {
      await ref.read(phoneSkillsProvider.notifier).setEnabled(name, true);
    } on PhoneSkillException catch (e) {
      if (mounted) showBriefNotice(context, skillErrorText(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!PhoneSkillBanner.supported) return const SizedBox.shrink();
    final hidden = ref.watch(hiddenSkillDraftsProvider);
    final listing = ref.watch(phoneSkillsProvider).value;
    if (listing != null) _listen();
    final drafts = listing?.drafts ?? const <PhoneSkillDraft>[];
    final mine = drafts.where((d) => d.from.sessionId == widget.sessionId && !hidden.contains(d.id)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (mine.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: widget.padding,
      child: PhoneSkillDraftCard(
        key: ValueKey('phone-skill-banner-${mine.first.id}'),
        draft: mine.first,
        showSource: false,
        compact: true,
      ),
    );
  }
}
