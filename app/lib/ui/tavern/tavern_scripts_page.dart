// 资源库 › 脚本库: the global 酒馆助手 scripts, as the engine keeps their tree
// (scripts and folders). Each on or off, moved among its siblings, exported
// or deleted; taken in through the tavern's one import door. The ones on run
// on the whole-page canvas of every chat, before the preset's and the card's.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_chat_files.dart';
import 'tavern_import_files.dart';
import 'tavern_widgets.dart';

/// The global script library's tree, as it changes.
final tavernGlobalScriptsProvider = StreamProvider.autoDispose<List<TavernScriptLibraryEntry>>(
  (ref) => ref.watch(tavernProvider).watchGlobalScripts(),
);

/// How many scripts [entries] hold, in folders or not.
int tavernScriptCount(List<TavernScriptLibraryEntry> entries) =>
    entries.fold(0, (n, e) => n + (e.isFolder ? tavernScriptCount(e.children) : 1));

TavernScriptLibraryEntry? _find(List<TavernScriptLibraryEntry> entries, String id) {
  for (final e in entries) {
    if (e.id == id) return e;
    if (_find(e.children, id) case final found?) return found;
  }
  return null;
}

class TavernScriptsPage extends ConsumerWidget {
  const TavernScriptsPage({super.key, this.folder});

  /// The folder shown; the library's top when null.
  final TavernScriptLibraryEntry? folder;

  static Route<void> route({TavernScriptLibraryEntry? folder}) =>
      MaterialPageRoute<void>(builder: (_) => TavernScriptsPage(folder: folder));

  /// A change to the library, said when the engine refuses it.
  Future<void> _change(BuildContext context, Future<void> Function() change) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    try {
      await change();
    } on Object catch (e) {
      messenger?.showBriefNotice(l10n.tavernStateEditRefused('$e'));
    }
  }

  Future<void> _export(WidgetRef ref, String name, {String? id}) async {
    final text = await ref.read(tavernProvider).exportGlobalScripts(id: id);
    final bytes = Uint8List.fromList(utf8.encode(text));
    await ref.read(tavernChatSinkProvider)([TavernChatFile(fileName: '$name.json', bytes: bytes)]);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, TavernScriptLibraryEntry entry, String name) async {
    final l10n = context.l10n;
    final ok = await confirmTavernDelete(
      context,
      title: l10n.tavernScriptDeleteTitle(name),
      message: l10n.tavernScriptDeleteMessage,
    );
    if (!ok || !context.mounted) return;
    await _change(context, () => ref.read(tavernProvider).deleteGlobalScript(entry.id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final library = ref.watch(tavernGlobalScriptsProvider);
    final tree = library.value ?? (library.hasError ? const <TavernScriptLibraryEntry>[] : null);
    final folder = this.folder;
    final items = folder == null ? tree : (tree == null ? null : _find(tree, folder.id)?.children ?? const []);
    String nameOf(TavernScriptLibraryEntry e) => e.name.isEmpty ? l10n.tavernScriptUnnamed : e.name;
    return AppPage.list(
      title: folder == null ? l10n.tavernScripts : nameOf(folder),
      actions: [
        if (folder == null && (tree?.isNotEmpty ?? false))
          GlassIconButton(
            key: const ValueKey('tavern-scripts-export'),
            icon: AppIcons.share,
            tooltip: l10n.tavernScriptsExportAll,
            onPressed: () => unawaited(_change(context, () => _export(ref, l10n.tavernScripts))),
          ),
        if (folder == null)
          GlassIconButton(
            key: const ValueKey('tavern-scripts-import'),
            icon: AppIcons.add,
            tooltip: l10n.tavernScriptsImport,
            onPressed: () => unawaited(importTavernFiles(context, ref)),
          ),
      ],
      children: [
        if (items == null)
          const QuietSpinner()
        else if (items.isEmpty)
          Padding(
            key: const ValueKey('tavern-scripts-empty'),
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 16),
            child: Text(
              // Not read: why, as the engine said it, where the list would be.
              library.hasError ? '${library.error}' : l10n.tavernScriptsEmpty,
              style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.5),
            ),
          )
        else
          SheetGroup(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              for (final entry in items)
                SettingsTile(
                  key: ValueKey('tavern-script-${entry.id}'),
                  icon: entry.isFolder ? AppIcons.folder : AppIcons.code,
                  tinted: false,
                  title: nameOf(entry),
                  subtitle: entry.isFolder ? l10n.tavernScriptCount(tavernScriptCount(entry.children)) : null,
                  value: Text(entry.enabled ? l10n.tavernRegexOn : l10n.tavernRegexOff),
                  onTap: () => unawaited(
                    showTavernActions(context, [
                      if (entry.isFolder)
                        (
                          AppIcons.folderOpen,
                          l10n.tavernScriptOpenFolder,
                          () => unawaited(Navigator.of(context).push(TavernScriptsPage.route(folder: entry))),
                        ),
                      (
                        entry.enabled ? AppIcons.remove : AppIcons.selected,
                        entry.enabled ? l10n.tavernRegexDisable : l10n.tavernRegexEnable,
                        () => unawaited(
                          _change(
                            context,
                            () => ref.read(tavernProvider).setGlobalScriptEnabled(entry.id, !entry.enabled),
                          ),
                        ),
                      ),
                      if (items.length > 1)
                        (
                          AppIcons.dragHandle,
                          l10n.tavernScriptsOrder,
                          () => unawaited(
                            showAppSheet<void>(
                              context,
                              isScrollControlled: true,
                              builder: (_) => _OrderSheet(folderId: folder?.id, items: items, nameOf: nameOf),
                            ),
                          ),
                        ),
                      (
                        AppIcons.share,
                        l10n.tavernScriptExport,
                        () => unawaited(_change(context, () => _export(ref, nameOf(entry), id: entry.id))),
                      ),
                      (
                        AppIcons.delete,
                        l10n.tavernScriptDelete,
                        () => unawaited(_delete(context, ref, entry, nameOf(entry))),
                      ),
                    ]),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// One folder's items (or the top's) in order, each with a handle to drag
/// it; every drop is saved as the whole order at once.
class _OrderSheet extends ConsumerStatefulWidget {
  const _OrderSheet({required this.folderId, required this.items, required this.nameOf});

  final String? folderId;
  final List<TavernScriptLibraryEntry> items;
  final String Function(TavernScriptLibraryEntry) nameOf;

  @override
  ConsumerState<_OrderSheet> createState() => _OrderSheetState();
}

class _OrderSheetState extends ConsumerState<_OrderSheet> {
  late final List<TavernScriptLibraryEntry> _rows = [...widget.items];

  /// Saves run one after another, each with the whole order as it then was.
  Future<void> _saving = Future.value();

  void _move(int from, int to) {
    setState(() {
      final moved = _rows.removeAt(from);
      _rows.insert(to.clamp(0, _rows.length), moved);
    });
    final ids = [for (final e in _rows) e.id];
    final tavern = ref.read(tavernProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = context.l10n.commonSaveFailed;
    _saving = _saving.then((_) async {
      try {
        await tavern.setGlobalScriptOrder(ids, folderId: widget.folderId);
      } on Object {
        messenger?.showBriefNotice(failed);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.tavernScriptsOrder),
            Padding(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 6),
              child: Text(
                l10n.tavernScriptsOrderNote,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
              ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 6, kSheetGutter, 6),
                child: GlassSurface(
                  tier: GlassTier.card,
                  borderRadius: AppShape.radiusLg,
                  child: Material(
                    type: MaterialType.transparency,
                    clipBehavior: Clip.antiAlias,
                    shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
                    child: ReorderableListView.builder(
                      key: const ValueKey('tavern-scripts-order-list'),
                      shrinkWrap: true,
                      buildDefaultDragHandles: false,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _rows.length,
                      onReorderItem: _move,
                      itemBuilder: (context, i) => ListPageRow(
                        key: ValueKey('tavern-scripts-order-${_rows[i].id}'),
                        title: widget.nameOf(_rows[i]),
                        trailing: ReorderableDragStartListener(
                          index: i,
                          child: Semantics(
                            label: l10n.shellDragToReorder,
                            child: SizedBox.square(
                              dimension: 32,
                              child: Icon(AppIcons.dragHandle, size: 20, color: colors.textTertiary),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
