// The dock above the composer (DSH's `conversation.input.dock`): the todo
// bar, then the goal bar, stacked over the activity strip in the composer
// column (on the chat page, cards of one deck: dock_stack.dart).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/chat_state.dart';
import '../../../state/goal_dock_state.dart';
import 'dock_pill.dart';
import 'goal_bar.dart';
import 'goal_sheet.dart';
import 'todo_bar.dart';

/// 输入条上方的停靠区:待办在上、目标在下(官方的顺序:Todo、Goal),再往下
/// 是思考胶囊和输入条。两根条各自长出 / 收回;都没有时零高。
///
/// 放在输入条那一列里(和横幅、思考胶囊同一列),列表的下沿、底色遮罩
/// 跟着整列的高度走,不需要另外的插槽。聊天页把两根条分开交给
/// `DockStack`(dock_stack.dart,可以叠成一摞),这里是不叠的那一列。
class ChatDock extends StatelessWidget {
  const ChatDock({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    // Both bars blur the same backdrop and never overlap: one sample.
    return BackdropGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TodoDockSlot(sessionId: sessionId),
          GoalDockSlot(sessionId: sessionId),
        ],
      ),
    );
  }
}

/// The todo bar's slot: 0 high without a list.
class TodoDockSlot extends ConsumerWidget {
  const TodoDockSlot({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (items, running) = ref.watch(chatProvider(sessionId).select((s) => (s.todos, s.running)));
    final todos = TodoDockSummary.of(items, running: running);
    return DockSlot(
      key: const ValueKey('todo'),
      child: todos == null ? null : TodoBar(key: ValueKey(sessionId), summary: todos),
    );
  }
}

/// The goal bar's slot: 0 high without a goal.
class GoalDockSlot extends ConsumerWidget {
  const GoalDockSlot({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(goalDockProvider(sessionId));
    return DockSlot(
      key: const ValueKey('goal'),
      child: goal == null ? null : GoalBar(goal: goal, onTap: () => runGoalActions(context, ref, sessionId)),
    );
  }
}
