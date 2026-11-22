// What her full-mode conversation is waiting on the person for, answered right
// here in 伙伴小屋: an approval for something she wants to do, or a question she
// asked with the ask tool. The cards are the main chat's own (the same buttons,
// the same risk confirmation, the same answers sent back), drawn on her deep
// glass so they belong to the room instead of sending the person elsewhere.

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_state.dart';
import '../chat/tool_view.dart';
import '../chat/widgets/approval_card.dart';
import '../chat/widgets/question_card.dart';
import '../theme/motion.dart';
import '../theme/surfaces.dart';
import 'companion_chrome.dart';

/// The room captures the original pending approval, never its successor card.
typedef CompanionApprovalTarget = ({String eventId, String? callId, bool Function() isCurrent});

/// The approval or question her session [sessionId] is waiting on, or nothing.
/// An approval comes first: the turn can't go on without it. An approval
/// about a tool call waits for that call's details (its command or path)
/// before it can be allowed, up to [detailWait]; after that it shows what
/// the request itself says, as the main chat does.
class CompanionAsk extends ConsumerStatefulWidget {
  const CompanionAsk({super.key, required this.sessionId, this.approvalTarget, this.onApprovalRiskRouteChanged});

  final String sessionId;
  final CompanionApprovalTarget? approvalTarget;
  final void Function(ApprovalRequest request, ModalRoute<Object?> route)? onApprovalRiskRouteChanged;

  /// How long an approval waits for its tool call to show up.
  static const detailWait = Duration(seconds: 3);

  @override
  ConsumerState<CompanionAsk> createState() => _CompanionAskState();
}

class _CompanionAskState extends ConsumerState<CompanionAsk> {
  /// The approval whose details didn't come in time: shown without them.
  String? _waitedFor;
  Timer? _wait;

  /// The approval [_wait] is counting for.
  String? _waitingFor;

  ApprovalRequest? _approval(ChatState state) {
    final target = widget.approvalTarget;
    if (target == null) {
      return state.openApproval;
    }
    if (!target.isCurrent()) {
      return null;
    }
    return state.approvals
        .where(
          (request) =>
              request.sessionId == widget.sessionId &&
              request.eventId == target.eventId &&
              (target.callId == null || request.callId == target.callId) &&
              !state.autoAnswered.contains(request.eventId),
        )
        .firstOrNull;
  }

  bool _pending(ApprovalRequest request) {
    if (!mounted) {
      return false;
    }
    final current = _approval(ref.read(chatProvider(widget.sessionId)));
    return current != null && current.eventId == request.eventId && current.callId == request.callId;
  }

  Future<void> _respond(ApprovalRequest request, ApprovalDecision decision) async {
    // A desktop decision or room change may arrive after the card was drawn.
    if (_pending(request)) {
      await ref.read(chatProvider(widget.sessionId).notifier).respond(request, decision);
    }
  }

  Future<void> _allowAll(ApprovalRequest request) async {
    if (_pending(request)) {
      await ref.read(chatProvider(widget.sessionId).notifier).allowAll(request);
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asking = ref.watch(
      chatProvider(widget.sessionId).select((s) {
        final approval = _approval(s);
        return (
          approval: approval,
          tool: approval == null ? null : _toolFor(s.items, approval),
          question: widget.approvalTarget == null ? s.questions.firstOrNull : null,
          autoApprove: s.autoApprove,
        );
      }),
    );
    final chat = ref.read(chatProvider(widget.sessionId).notifier);
    final approval = asking.approval;
    final question = asking.question;
    final tool = asking.tool;
    // Details still on their way: nothing to allow yet.
    final waiting =
        approval != null &&
        approval.callId != null &&
        (tool == null || tool.status == ToolStatus.streaming) &&
        _waitedFor != approval.eventId;
    if (waiting && _waitingFor != approval.eventId) {
      _wait?.cancel();
      final id = _waitingFor = approval.eventId;
      _wait = Timer(CompanionAsk.detailWait, () {
        if (mounted) setState(() => _waitedFor = id);
      });
    } else if (!waiting) {
      _wait?.cancel();
      _wait = null;
      _waitingFor = null;
    }
    Widget? card;
    if (approval != null && !waiting) {
      card = ApprovalCard(
        key: ValueKey('approval-${approval.eventId}'),
        request: approval,
        view: tool == null ? null : ToolView.of(tool),
        onRespond: _respond,
        // Already trusting the whole conversation: nothing wider to offer.
        onAllowAll: asking.autoApprove ? null : _allowAll,
        onRiskRouteChanged: widget.onApprovalRiskRouteChanged == null
            ? null
            : (route) => widget.onApprovalRiskRouteChanged!(approval, route),
      );
    } else if (approval == null && question != null) {
      card = QuestionCard(
        key: ValueKey('question-${question.eventId}'),
        request: question,
        onAnswer: (request, answers) => chat.answer(request, answers),
        onReject: chat.rejectQuestion,
      );
    }
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.standard),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(sizeFactor: animation, alignment: Alignment.bottomCenter, child: child),
      ),
      child: card == null
          ? const SizedBox(key: ValueKey('nothing'), width: double.infinity)
          : Padding(
              key: card.key,
              padding: const EdgeInsets.only(bottom: 8),
              child: ConstrainedBox(
                // A long command or a plan to review scrolls inside; she stays in view.
                constraints: BoxConstraints(maxHeight: _roomFor(context)),
                child: SingleChildScrollView(child: CompanionDeepCards(child: card)),
              ),
            ),
    );
  }

  /// At most half the screen, and never more than the keyboard, the top bar,
  /// the input and a line of her words leave.
  static double _roomFor(BuildContext context) {
    final media = MediaQuery.of(context);
    final left = media.size.height - media.viewInsets.bottom - media.padding.top - 260;
    return left.clamp(140.0, math.max(140.0, media.size.height * 0.5));
  }

  /// The tool call the approval is about: its command or path is the card's body.
  static ToolChatItem? _toolFor(List<ChatItem> items, ApprovalRequest request) {
    for (final item in items.reversed) {
      if (item is! ToolChatItem) continue;
      if (item.pendingApproval?.eventId == request.eventId ||
          (request.callId != null && item.callId == request.callId)) {
        return item;
      }
    }
    return null;
  }
}

/// The app's cards (approval, question) on the room's deep glass instead of
/// the chat's: the same widgets, in water.
class CompanionDeepCards extends StatelessWidget {
  const CompanionDeepCards({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = DshSurfaces.of(context);
    final deep = companionDeepGlass(context);
    return Theme(
      data: theme.copyWith(
        extensions: [
          ...theme.extensions.values.where((e) => e is! DshSurfaces),
          surfaces.copyWith(
            card: surfaces.card.copyWith(fill: deep.fill, fallbackFill: deep.fallbackFill),
          ),
        ],
      ),
      child: child,
    );
  }
}
