// The call's captions in full: every exchange so far, what the person said on
// the right as in the chat, her words on the left, the newest at the bottom and
// growing while the call goes on.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../../../l10n/l10n.dart';
import '../../../speech/call/voice_call.dart';
import '../../../speech/speech_out.dart' show speakable;
import '../../common/app_sheet.dart';
import '../../theme/theme.dart';

Future<void> showCallTranscript(BuildContext context, VoiceCallController call) =>
    showAppSheet<void>(context, heightFactor: 0.72, builder: (sheet) => CallTranscript(call: call));

class CallTranscript extends StatefulWidget {
  const CallTranscript({super.key, required this.call});

  final VoiceCallController call;

  @override
  State<CallTranscript> createState() => _CallTranscriptState();
}

class _CallTranscriptState extends State<CallTranscript> {
  final _scroll = ScrollController();
  final _spoken = Expando<String>();
  late List<CallTurn> _turns;

  /// The reader is at the bottom, following the words: only their own
  /// scrolling changes it, not the words growing under an animation.
  bool _following = true;

  bool _onScroll(UserScrollNotification n) {
    _following = n.direction == ScrollDirection.idle && n.metrics.extentAfter < 48;
    return false;
  }

  @override
  void initState() {
    super.initState();
    _turns = widget.call.turns;
    widget.call.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _changed() {
    if (!mounted) return;
    // The audio levels notify too. The list changes only with its last turn:
    // turns are appended, or the last one replaced (each one never changes).
    final turns = widget.call.turns;
    if (!identical(turns.lastOrNull, _turns.lastOrNull)) setState(() => _turns = turns);
    if (!_following) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The reader may have scrolled away since.
      if (!mounted || !_following || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      final duration = AppMotion.of(context, AppMotion.standard);
      if (duration == Duration.zero) {
        _scroll.jumpTo(end);
      } else {
        unawaited(_scroll.animateTo(end, duration: duration, curve: AppMotion.std));
      }
    });
  }

  @override
  void dispose() {
    widget.call.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final turns = _turns;
    return Column(
      children: [
        SheetHeader(l10n.speechCallTranscript),
        Expanded(
          child: turns.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      l10n.speechCallTranscriptEmpty,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : NotificationListener<UserScrollNotification>(
                  onNotification: _onScroll,
                  child: ListView.builder(
                    key: const ValueKey('call-transcript-list'),
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 28),
                    itemCount: turns.length,
                    itemBuilder: (context, i) {
                      final turn = turns[i];
                      final her = _spoken[turn] ??= speakable(turn.her).trim();
                      return _Turn(turn, her);
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _Turn extends StatelessWidget {
  const _Turn(this.turn, this.her);

  final CallTurn turn;
  final String her;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = DshSurfaces.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
              child: DecoratedBox(
                decoration: ShapeDecoration(color: surfaces.userBubble, shape: AppShape.bubble),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Text(turn.you, style: AppType.chatBody(context, color: surfaces.onUserBubble)),
                ),
              ),
            ),
          ),
          if (her.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(turn.cut ? '$her…' : her, style: AppType.chatBody(context, height: 1.6)),
          ],
          if (turn.cut) ...[
            const SizedBox(height: 6),
            Text(
              context.l10n.speechCallTranscriptCut,
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
