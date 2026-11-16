import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/system_actions_state.dart';
import '../common/app_sheet.dart';
import '../theme/theme.dart';

/// Put it once inside the home route (the home shell does, on HarmonyOS). It
/// keeps 系统操作's session going and raises a handoff's prompt over whatever
/// page is open. Draws nothing here.
class SystemActionsHost extends ConsumerStatefulWidget {
  const SystemActionsHost({super.key});

  @override
  ConsumerState<SystemActionsHost> createState() => _SystemActionsHostState();
}

class _SystemActionsHostState extends ConsumerState<SystemActionsHost> {
  @override
  void initState() {
    super.initState();
    // At once: the shell can be rebuilt while a handoff already waits.
    ref.listenManual(systemActionsProvider.select((s) => s.handoff), (previous, next) {
      if (next == null || next.requestId == previous?.requestId) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(systemActionsProvider).handoff?.requestId == next.requestId) _show(next);
      });
    }, fireImmediately: true);
  }

  void _show(DshPhoneRequest request) => unawaited(
    showAppSheet<void>(
      context,
      isScrollControlled: true,
      dismissal: SheetDismissal.button,
      builder: (_) => HandoffSheet(request: request),
    ),
  );

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// A handoff: what the AI wants the person to do, and the two answers. It stays
/// up until one of them counts or the call ends (expired, stopped, the engine
/// gone); only continue tells the AI to go on.
class HandoffSheet extends ConsumerStatefulWidget {
  const HandoffSheet({super.key, required this.request});

  final DshPhoneRequest request;

  @override
  ConsumerState<HandoffSheet> createState() => _HandoffSheetState();
}

class _HandoffSheetState extends ConsumerState<HandoffSheet> {
  bool _busy = false;

  Future<void> _answer(Future<bool> Function() answer) async {
    if (_busy) return;
    setState(() => _busy = true);
    final counted = await answer();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!counted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(context.l10n.systemActionsHandoffFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final actions = ref.read(systemActionsProvider.notifier);
    final reason = widget.request.args['reason'];
    ref.listen(systemActionsProvider.select((s) => s.handoff?.requestId), (_, current) {
      if (current != widget.request.requestId && mounted) Navigator.of(context).pop();
    });
    return PopScope(
      canPop: false,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 24, kSheetGutter, 0),
              child: Text(l10n.systemActionsHandoffTitle, style: theme.textTheme.titleMedium),
            ),
            if (reason is String)
              Padding(
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 10, kSheetGutter, 0),
                child: Text(reason, style: theme.textTheme.bodyLarge),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 10, kSheetGutter, 0),
              child: Text(
                l10n.systemActionsHandoffNote,
                style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 20, kSheetGutter, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('handoff-stop'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      onPressed: _busy ? null : () => unawaited(_answer(actions.stopHandoff)),
                      child: Text(l10n.commonStop),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('handoff-continue'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      onPressed: _busy ? null : () => unawaited(_answer(actions.continueHandoff)),
                      child: Text(l10n.commonContinue),
                    ),
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
