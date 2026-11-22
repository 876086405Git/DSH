// Both room modes edit the same phone-owned memory store. A dialog keeps its
// card/source revision; a stale save refreshes instead of overwriting a change.
import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_memory.dart';
import '../../companion/companion_memory_id.dart';
import '../../companion/companion_widget.dart';
import '../../l10n/l10n.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/semantic_colors.dart';

const _maxLength = 512;

class CompanionMemoryPage extends ConsumerStatefulWidget {
  const CompanionMemoryPage({super.key, required this.memory, this.characterId});

  final CompanionMemoryOwner memory;
  // A captured character, not a selector for all roles. Null means shared only.
  final String? characterId;

  @override
  ConsumerState<CompanionMemoryPage> createState() => _CompanionMemoryPageState();
}

class _CompanionMemoryPageState extends ConsumerState<CompanionMemoryPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.memory.addListener(_changed);
    unawaited(_clearWidget());
  }

  @override
  void didUpdateWidget(CompanionMemoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.memory, widget.memory)) {
      oldWidget.memory.removeListener(_changed);
      widget.memory.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.memory.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _clearWidget() async {
    final done = await widget.memory.clearWidget(ref.read(companionWidgetProvider));
    if (!done && mounted) showBriefNotice(context, context.l10n.companionMemoryWidgetPending);
  }

  Future<void> _write(void Function(CompanionMemoryStore) change) async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      change(widget.memory.store);
      widget.memory.changed();
      await _clearWidget();
    } on Object catch (error) {
      if (!mounted) return;
      final conflict = error is DshRemoteException && error.code.endsWith('conflict');
      showBriefNotice(
        context,
        conflict ? context.l10n.companionMemoryConflict : context.l10n.companionMemorySaveFailed,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _editor(String title, String initial, {required int maxLength}) async {
    var input = initial;
    String? tooLong;
    return showAppDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, setDialog) => AlertDialog(
          title: Text(title),
          content: TextFormField(
            initialValue: input,
            onChanged: (value) {
              input = value;
              if (tooLong != null) setDialog(() => tooLong = null);
            },
            autofocus: true,
            minLines: 2,
            maxLines: 6,
            maxLength: maxLength,
            decoration: InputDecoration(hintText: context.l10n.companionMemoryHint, errorText: tooLong),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog), child: Text(dialog.l10n.commonCancel)),
            FilledButton(
              onPressed: () {
                if (input.runes.length > maxLength) {
                  setDialog(() => tooLong = dialog.l10n.engineFieldMaxCharacters(maxLength));
                } else if (input.trim().isNotEmpty) {
                  Navigator.pop(dialog, input);
                }
              },
              child: Text(dialog.l10n.companionMemorySave),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit([MemoryRow? row]) async {
    final memory = widget.memory;
    final initial = row?['text'] as String? ?? '';
    final text = await _editor(context.l10n.companionMemoryEdit, initial, maxLength: _maxLength);
    if (!mounted || !identical(memory, widget.memory) || text == null || text == initial) return;
    final changedValue = normalizeMemoryText(text) != normalizeMemoryText(initial);
    await _write(
      (store) => store.saveManual(
        CompanionMemory(
          id: row?['id'] as String? ?? companionMemoryId(),
          text: text,
          kind: row?['kind'] as String? ?? 'fact',
          keywords: (row?['keywords'] as List<String>?) ?? const [],
          pinned: row?['pinned'] == true,
          expiresAt: row?['expires_at_ms'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(row!['expires_at_ms']! as int, isUtc: true),
        ),
        expectedRowRev: row?['row_rev'] as int?,
        currentValueChange: changedValue,
        realityKnown: changedValue || row?['eligible'] == true,
      ),
    );
  }

  Future<void> _delete(MemoryRow row) async {
    final memory = widget.memory;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(dialog.l10n.companionMemoryForgetTitle),
        content: Text(row['text']! as String),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(dialog.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(dialog.l10n.companionMemoryForget),
          ),
        ],
      ),
    );
    if (!mounted || !identical(memory, widget.memory) || ok != true) return;
    await _write((store) => store.deleteCard(id: row['id']! as String, expectedRowRev: row['row_rev']! as int));
  }

  Future<void> _action(String action, MemoryRow row) async {
    if (_busy) return;
    if (action == 'edit') return _edit(row);
    if (action == 'forget') return _delete(row);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cards = widget.memory.store.memoryPageCards(characterId: widget.characterId);
    final Widget body = cards.isEmpty
        ? EmptyView(
            icon: AppIcons.bookmark,
            title: l10n.companionMemoryEmpty,
            message: l10n.companionMemoryEmptyHint,
            onAction: _busy ? null : _edit,
            actionLabel: l10n.companionMemoryAdd,
          )
        : SheetGroup(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            children: [
              for (final row in cards)
                SettingsTile(
                  icon: AppIcons.bookmark,
                  tinted: false,
                  title: row['text']! as String,
                  subtitle: switch (row['layer']) {
                    'diary' => '${l10n.companionMemoryDiary} · ${row['local_day']}',
                    'impression' => l10n.companionMemoryImpression,
                    _ => row['collection'] == 'person' ? l10n.companionMemoryPerson : l10n.companionMemoryCard,
                  },
                  onTap: _busy ? null : () => _edit(row),
                  trailing: PopupMenuButton<String>(
                    enabled: !_busy,
                    tooltip: l10n.companionMemoryActions,
                    onSelected: (action) => unawaited(_action(action, row)),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'edit', child: Text(l10n.companionMemoryEdit)),
                      PopupMenuItem(value: 'forget', child: Text(l10n.companionMemoryForget)),
                    ],
                  ),
                ),
            ],
          );
    return AppPage(
      title: l10n.companionMemoryTitle,
      subtitle: Text(
        l10n.companionMemoryScope(l10n.commonThisPhone),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
      ),
      actions: [
        IconButton(tooltip: l10n.companionMemoryAdd, icon: const Icon(AppIcons.add), onPressed: _busy ? null : _edit),
      ],
      slivers: [SliverToBoxAdapter(child: body)],
    );
  }
}
