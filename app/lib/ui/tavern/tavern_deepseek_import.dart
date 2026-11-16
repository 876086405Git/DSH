// 从 DeepSeek 接回来: a conversation that can't go on in DeepSeek's own app,
// carried over to be continued here. The person brings the ZIP DeepSeek's
// 「导出所有历史对话」gives them (picked, or shared to the app); one sheet
// lists what is in it, the longest first with that one already ticked, and
// one button takes the ticked ones in and opens the first. Nothing is named,
// configured or sent to a model on the way.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import 'tavern_backup.dart' show tavernBackupPickerProvider;
import 'tavern_chat_page.dart';

/// Takes conversations in from the DeepSeek export at [path] (asked for when
/// null) and opens the first of them.
Future<void> takeInDeepSeekExport(BuildContext context, WidgetRef ref, {String? path}) async {
  final l10n = context.l10n;
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final zip = path ?? await ref.read(tavernBackupPickerProvider)();
  if (zip == null || !context.mounted) return;
  final taken = await showAppSheet<List<TavernDeepSeekImported>>(
    context,
    heightFactor: 0.85,
    builder: (_) => _DeepSeekSheet(path: zip),
  );
  if (taken == null || !navigator.mounted) return;
  // What was ticked could not be read after all.
  if (taken.isEmpty) return messenger?.showBriefNotice(l10n.tavernDeepSeekFailed);
  if (taken.length > 1) messenger?.showBriefNotice(l10n.tavernDeepSeekTaken(taken.length));
  unawaited(navigator.push(TavernChatPage.route(taken.first.chatId)));
}

class _DeepSeekSheet extends ConsumerStatefulWidget {
  const _DeepSeekSheet({required this.path});

  final String path;

  @override
  ConsumerState<_DeepSeekSheet> createState() => _DeepSeekSheetState();
}

class _DeepSeekSheetState extends ConsumerState<_DeepSeekSheet> {
  /// Rows shown before 「显示更多」: the long conversations are the ones looked for.
  static const _page = 30;

  List<TavernDeepSeekSession>? _sessions;
  final _picked = <String>{};
  var _shown = _page;
  var _unreadable = false;
  var _taking = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final sessions = await ref.read(tavernProvider).inspectDeepSeekExport(widget.path);
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        // The longest one not here yet is almost always the one they came for.
        if (sessions.where((s) => s.imported == null).firstOrNull case final first?) _picked.add(first.id);
      });
    } on Object {
      if (mounted) setState(() => _unreadable = true);
    }
  }

  Future<void> _take() async {
    setState(() {
      _taking = true;
      _failed = false;
    });
    try {
      // In the list's order, so the longest is the one that opens.
      final ids = [
        for (final session in _sessions!)
          if (_picked.contains(session.id)) session.id,
      ];
      final taken = await ref.read(tavernProvider).importDeepSeekSessions(widget.path, ids);
      if (mounted) Navigator.of(context).pop(taken);
    } on Object {
      if (!mounted) return;
      setState(() {
        _taking = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final sessions = _sessions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitleBar(l10n.tavernDeepSeekTitle),
        if (_unreadable)
          Expanded(
            child: EmptyView(
              key: const ValueKey('tavern-deepseek-unreadable'),
              icon: AppIcons.error,
              title: l10n.tavernDeepSeekNotExport,
              message: l10n.tavernDeepSeekNotExportMessage,
            ),
          )
        else if (sessions == null)
          const Expanded(child: Center(child: QuietSpinner()))
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 8),
            child: Text(
              l10n.tavernDeepSeekFound(sessions.length),
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                SheetGroup(
                  children: [
                    for (final session in sessions.take(_shown)) _row(session),
                    if (sessions.length > _shown)
                      SettingsTile(
                        key: const ValueKey('tavern-deepseek-more'),
                        tinted: false,
                        chevron: false,
                        title: l10n.tavernDeepSeekMore(sessions.length - _shown),
                        onTap: () => setState(() => _shown += _page),
                      ),
                  ],
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 8, SheetTitleBar.inset, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_failed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        l10n.tavernDeepSeekFailed,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                  FilledButton(
                    key: const ValueKey('tavern-deepseek-take'),
                    onPressed: _taking || _picked.isEmpty ? null : () => unawaited(_take()),
                    child: Text(_taking ? l10n.tavernDeepSeekTaking : l10n.tavernDeepSeekTake(_picked.length)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _row(TavernDeepSeekSession session) {
    final l10n = context.l10n;
    final imported = session.imported;
    final picked = _picked.contains(session.id);
    return SettingsTile(
      key: ValueKey('tavern-deepseek-${session.id}'),
      tinted: false,
      chevron: imported != null,
      title: session.title.isEmpty ? l10n.tavernDeepSeekUntitled : session.title,
      subtitle: imported != null
          ? l10n.tavernDeepSeekAlready
          : [
              l10n.tavernDeepSeekMessages(session.messageCount),
              if (session.updatedAt case final at?) MaterialLocalizations.of(context).formatShortDate(at.toLocal()),
            ].join(' · '),
      trailing: picked ? Icon(AppIcons.selected, size: 18, color: Theme.of(context).colorScheme.primary) : null,
      onTap: _taking
          ? null
          // One that is here already just opens.
          : imported != null
          ? () => Navigator.of(context).pop([imported])
          : () => setState(() => picked ? _picked.remove(session.id) : _picked.add(session.id)),
    );
  }
}
