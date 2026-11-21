// Both room modes edit the same phone-owned memory store. A dialog keeps its
// card/source revision; a stale save refreshes instead of overwriting a change.
import 'dart:async';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_memory.dart';
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

/// A v4 UUID: memories are named by the client so a retried save can't add two.
String companionMemoryId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

class CompanionMemoryPage extends ConsumerStatefulWidget {
  const CompanionMemoryPage({super.key, required this.memory});

  final CompanionMemoryOwner memory;

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
    } on DshRemoteException catch (error) {
      if (mounted)
        showBriefNotice(
          context,
          error.code.endsWith('conflict')
              ? context.l10n.companionMemoryConflict
              : context.l10n.companionMemorySaveFailed,
        );
    } on Object {
      if (mounted) showBriefNotice(context, context.l10n.companionMemorySaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _editor(String title, String initial, {int? maxLength}) async {
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
                if (maxLength != null && input.runes.length > maxLength) {
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

  Future<void> _edit([MemoryRow? row, bool currentValue = true]) async {
    final memory = widget.memory;
    final initial = row?['text'] as String? ?? '';
    final text = await _editor(
      currentValue ? context.l10n.companionMemoryEdit : context.l10n.companionMemoryWording,
      initial,
      maxLength: _maxLength,
    );
    if (!mounted || !identical(memory, widget.memory) || text == null || text == initial) return;
    final changedValue = currentValue && normalizeMemoryText(text) != normalizeMemoryText(initial);
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
    if (action == 'edit' || action == 'wording') return _edit(row, action == 'edit');
    if (action == 'forget') return _delete(row);
    if (action == 'source') return _sources(card: row);
    await _write((store) {
      if (action == 'confirm') {
        store.confirmReality(id: row['id']! as String, expectedRowRev: row['row_rev']! as int);
      } else if (action == 'pin') {
        store.setPinned(
          id: row['id']! as String,
          expectedRowRev: row['row_rev']! as int,
          pinned: row['pinned'] != true,
        );
      } else {
        // Use the current card identity/revision before applying a topic action.
        final current = store.cards().where((card) => card['id'] == row['id']).firstOrNull;
        if (current == null || current['row_rev'] != row['row_rev']) {
          throw const DshRemoteException('companion/conflict', 'Memory changed', {'status': 409});
        }
        store.applyControl(
          topicIds: [row['topic_id']! as String],
          kind: action,
          targetCardIds: action == 'cancel' ? [row['id']! as String] : null,
        );
      }
    });
  }

  Future<void> _editSource(MemoryRow row) async {
    final memory = widget.memory;
    final text = await _editor(context.l10n.companionMemoryEditSource, row['text']! as String);
    if (!mounted || !identical(memory, widget.memory) || text == null || text == row['text']) return;
    await _write(
      (store) => store.editMessage(id: row['id']! as String, expectedSourceRev: row['source_rev']! as int, text: text),
    );
  }

  Future<void> _deleteSource(MemoryRow row) async {
    final memory = widget.memory;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(dialog.l10n.companionMemoryDeleteSource),
        content: Text(dialog.l10n.companionMemoryDeleteSourceHint),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(dialog.l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(dialog.l10n.commonDelete)),
        ],
      ),
    );
    if (!mounted || !identical(memory, widget.memory) || ok != true) return;
    await _write(
      (store) => store.deleteMessage(id: row['id']! as String, expectedSourceRev: row['source_rev']! as int),
    );
  }

  Future<void> _sources({MemoryRow? card}) async {
    final ids = card == null
        ? null
        : {for (final evidence in card['evidence']! as List) (evidence as Map)['message_id'] as String};
    await showAppSheet<void>(
      context,
      builder: (sheet) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * .7,
          child: AnimatedBuilder(
            animation: widget.memory,
            builder: (_, _) {
              final sources = widget.memory.store
                  .messages()
                  .where((row) => row['role'] == 'user' && (ids == null || ids.contains(row['id'])))
                  .toList()
                  .reversed;
              return ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(sheet.l10n.companionMemorySources, style: Theme.of(sheet).textTheme.titleMedium),
                  ),
                  for (final row in sources)
                    ListTile(
                      title: Text(row['text']! as String),
                      subtitle: Text('${_originalTime(row)} · ${_sourceStatus(row)}'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) {
                          Navigator.pop(sheet);
                          unawaited(action == 'edit' ? _editSource(row) : _deleteSource(row));
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'edit', child: Text(sheet.l10n.companionMemoryEditSource)),
                          PopupMenuItem(value: 'delete', child: Text(sheet.l10n.companionMemoryDeleteSource)),
                        ],
                      ),
                    ),
                  if (sources.isEmpty)
                    Padding(padding: const EdgeInsets.all(16), child: Text(sheet.l10n.companionMemoryNoSource)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _usage() => showAppSheet<void>(
    context,
    builder: (sheet) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheet).height * .7,
        child: AnimatedBuilder(
          animation: widget.memory,
          builder: (_, _) {
            final l10n = sheet.l10n;
            final receipts = widget.memory.store.requests().reversed.take(100);
            final incomplete = widget.memory.store
                .hostChatDeliveries()
                .where((row) => row['state'] != 'settled' || (row['snapshot_metadata'] as Map?)?['complete'] != true)
                .toList()
                .reversed
                .take(100);
            String count(Object? value) => value == null ? l10n.companionMemoryUsageUnknown : '$value';
            String kind(MemoryRow row) => switch (row['category']) {
              'extract' => l10n.companionMemoryUsageExtract,
              'organize' => l10n.companionMemoryUsageOrganize,
              _ => l10n.companionMemoryUsageChat,
            };
            return ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(l10n.companionMemoryUsage, style: Theme.of(sheet).textTheme.titleMedium),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(l10n.companionMemoryUsageHint),
                ),
                for (final row in incomplete)
                  ListTile(
                    title: Text(
                      row['state'] == 'pending' || row['state'] == 'running'
                          ? l10n.companionMemoryUsageWaiting
                          : l10n.companionMemoryUsageIncomplete,
                    ),
                    subtitle: Text(
                      DateTime.fromMillisecondsSinceEpoch(row['observed_at_ms']! as int).toLocal().toString(),
                    ),
                  ),
                for (final row in receipts)
                  ListTile(
                    title: Text('${kind(row)} · ${row['provider']} / ${row['model']}'),
                    subtitle: Text(
                      [
                        '${l10n.companionMemoryUsageInput}: ${count(row['input_uncached'])}',
                        '${l10n.companionMemoryUsageCacheRead}: ${count(row['input_cache_read'])}',
                        '${l10n.companionMemoryUsageCacheWrite}: ${count(row['input_cache_write'])}',
                        '${l10n.companionMemoryUsageOutput}: ${count(row['output_tokens'])}',
                        '${l10n.companionMemoryUsageCost}: ${row['estimated_cny'] == null ? l10n.companionMemoryUsageUnknown : 'CNY ${(row['estimated_cny']! as num).toStringAsFixed(6)}'}',
                        if (row['state'] == 'not_sent' || row['state'] == 'released')
                          l10n.companionMemoryUsageNotSent
                        else if (row['state'] == 'active' || row['state'] == 'reserved' || row['state'] == 'sent')
                          l10n.companionMemoryUsageWaiting,
                      ].join('\n'),
                    ),
                  ),
                if (receipts.isEmpty && incomplete.isEmpty)
                  Padding(padding: const EdgeInsets.all(16), child: Text(l10n.companionMemoryUsageEmpty)),
              ],
            );
          },
        ),
      ),
    ),
  );

  String _originalTime(MemoryRow row) {
    final offset = row['offset_minutes']! as int;
    final at = DateTime.fromMillisecondsSinceEpoch((row['said_at_utc']! as int) + offset * 60000, isUtc: true);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)} '
        'UTC${offset < 0 ? '-' : '+'}${two(offset.abs() ~/ 60)}:${two(offset.abs() % 60)}';
  }

  String _sourceStatus(MemoryRow row) {
    final l10n = context.l10n;
    if (row['extraction_reason'] == 'input_too_long') return l10n.companionMemoryTooLong;
    if (row['extraction_reason'] == 'invalid_proposal') return l10n.companionMemoryNotExtracted;
    if (row['extraction_state'] == 'pending') return l10n.companionMemoryPending;
    return l10n.companionMemorySourceKept;
  }

  String _status(MemoryRow row) => [
    if (row['eligible'] != true) context.l10n.companionMemoryDisplayOnly,
    if (row['plan_state'] == 'cancelled') context.l10n.companionMemoryCancelled,
    if (row['topic_mode'] == 'less') context.l10n.companionMemoryLess,
    if (row['topic_mode'] == 'never') context.l10n.companionMemoryNever,
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cards = widget.memory.store.cards();
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
                  icon: row['pinned'] == true ? AppIcons.pinActive : AppIcons.bookmark,
                  tinted: false,
                  title: row['text']! as String,
                  subtitle: _status(row).isEmpty ? null : _status(row),
                  onTap: _busy ? null : () => _edit(row),
                  trailing: PopupMenuButton<String>(
                    enabled: !_busy,
                    tooltip: l10n.companionMemoryActions,
                    onSelected: (action) => unawaited(_action(action, row)),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'edit', child: Text(l10n.companionMemoryEdit)),
                      PopupMenuItem(value: 'wording', child: Text(l10n.companionMemoryWording)),
                      PopupMenuItem(
                        value: 'pin',
                        child: Text(row['pinned'] == true ? l10n.companionMemoryUnpin : l10n.companionMemoryPin),
                      ),
                      if (row['reality_unconfirmed'] == true)
                        PopupMenuItem(value: 'confirm', child: Text(l10n.companionMemoryConfirmReality)),
                      PopupMenuItem(value: 'source', child: Text(l10n.companionMemorySources)),
                      PopupMenuItem(value: 'less', child: Text(l10n.companionMemoryLess)),
                      PopupMenuItem(value: 'never', child: Text(l10n.companionMemoryNever)),
                      if (row['topic_mode'] != 'normal')
                        PopupMenuItem(value: 'normal', child: Text(l10n.companionMemoryNormal)),
                      if (row['kind'] == 'episode' && row['plan_state'] != 'cancelled')
                        PopupMenuItem(value: 'cancel', child: Text(l10n.companionMemoryCancelPlan)),
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
        IconButton(tooltip: l10n.companionMemoryUsage, icon: const Icon(AppIcons.chart), onPressed: _usage),
        IconButton(
          tooltip: l10n.companionMemorySources,
          icon: const Icon(AppIcons.history),
          onPressed: _busy ? null : _sources,
        ),
        IconButton(tooltip: l10n.companionMemoryAdd, icon: const Icon(AppIcons.add), onPressed: _busy ? null : _edit),
      ],
      slivers: [SliverToBoxAdapter(child: body)],
    );
  }
}
