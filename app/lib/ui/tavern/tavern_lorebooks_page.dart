// 资源库 › 世界书 (docs/design/roleplay-roadmap.md P0, engine T21): standalone
// lorebooks, exported from SillyTavern, imported as they are; each can be
// used in every chat (the global binding), exported or deleted. A card's own
// lorebook goes with the card (its page shows it), not here.

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
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_chat_files.dart';
import 'tavern_library_book_page.dart';
import 'tavern_presets_page.dart' show tavernTextOf;
import 'tavern_report_page.dart';
import 'tavern_widgets.dart';

/// The standalone lorebooks, and which of them every chat uses.
final tavernLorebooksProvider = FutureProvider.autoDispose<({List<TavernLorebookSummary> books, List<String> global})>((
  ref,
) async {
  final tavern = ref.watch(tavernProvider);
  final books = await tavern.listLorebooks();
  final settings = await tavern.readSettings();
  final bound = switch (settings['lorebooks']) {
    {'global': final List<Object?> ids} => [for (final id in ids) '$id'],
    _ => const <String>[],
  };
  return (books: books, global: bound);
});

class TavernLorebooksPage extends ConsumerWidget {
  const TavernLorebooksPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const TavernLorebooksPage());

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final tavern = ref.read(tavernProvider);
    for (final file in await ref.read(tavernChatPickerProvider)()) {
      try {
        final result = await tavern.importLorebook(tavernTextOf(file.bytes), fileName: file.fileName);
        messenger?.showBriefNotice(l10n.tavernLorebookImported(result.book.name, result.book.entryCount));
      } on Object catch (e) {
        messenger?.showBriefNotice(
          l10n.tavernPresetImportFailed(e is FormatException ? l10n.tavernPresetNotText : '$e'),
        );
      }
    }
    ref.invalidate(tavernLorebooksProvider);
  }

  /// [id] in or out of the global binding: every chat's lorebooks.
  Future<void> _setGlobal(WidgetRef ref, List<String> global, String id, bool on) async {
    final ids = [
      for (final b in global)
        if (b != id) b,
      if (on) id,
    ];
    await ref.read(tavernProvider).bindLorebooks(ids);
    ref.invalidate(tavernLorebooksProvider);
  }

  Future<void> _export(WidgetRef ref, TavernLorebookSummary book) async {
    final text = await ref.read(tavernProvider).exportLorebook(book.id);
    final bytes = Uint8List.fromList(utf8.encode(text));
    await ref.read(tavernChatSinkProvider)([TavernChatFile(fileName: '${book.name}.json', bytes: bytes)]);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, List<String> global, TavernLorebookSummary book) async {
    final l10n = context.l10n;
    final ok = await confirmTavernDelete(
      context,
      title: l10n.tavernLorebookDeleteTitle(book.name),
      message: l10n.tavernLorebookDeleteMessage,
    );
    if (!ok) return;
    final tavern = ref.read(tavernProvider);
    // Out of every chat first, then gone.
    if (global.contains(book.id)) {
      await tavern.bindLorebooks([
        for (final b in global)
          if (b != book.id) b,
      ]);
    }
    await tavern.deleteLorebook(book.id);
    ref.invalidate(tavernLorebooksProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final library = ref.watch(tavernLorebooksProvider).value;
    return AppPage.list(
      title: l10n.tavernLorebooks,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-lorebook-import'),
          icon: AppIcons.add,
          tooltip: l10n.tavernLorebookImport,
          onPressed: () => unawaited(_import(context, ref)),
        ),
      ],
      children: [
        if (library == null)
          const QuietSpinner()
        else if (library.books.isEmpty)
          EmptyView(
            key: const ValueKey('tavern-lorebooks-empty'),
            icon: AppIcons.lorebook,
            title: l10n.tavernLorebooksEmpty,
            message: l10n.tavernLorebooksEmptyMessage,
            compact: true,
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
          )
        else
          SettingsSection(
            children: [
              for (final book in library.books)
                () {
                  final global = library.global.contains(book.id);
                  return SettingsTile(
                    key: ValueKey('tavern-lorebook-${book.id}'),
                    title: book.name,
                    subtitle: l10n.tavernLorebookEntries(book.entryCount),
                    value: Text(global ? l10n.tavernLorebookGlobal : ''),
                    onTap: () => unawaited(
                      showTavernActions(context, [
                        // Its entries, to read and to change.
                        (
                          AppIcons.edit,
                          l10n.tavernLibraryBookOpen,
                          () => unawaited(Navigator.of(context).push(TavernLibraryBookPage.route(book.id))),
                        ),
                        (
                          global ? AppIcons.remove : AppIcons.selected,
                          global ? l10n.tavernLorebookUnbindGlobal : l10n.tavernLorebookBindGlobal,
                          () => unawaited(_setGlobal(ref, library.global, book.id, !global)),
                        ),
                        (
                          AppIcons.info,
                          l10n.tavernReport,
                          () => unawaited(
                            Navigator.of(context).push(
                              TavernImportReportPage.route(
                                kind: TavernImportKind.lorebook,
                                assetId: book.id,
                                name: book.name,
                              ),
                            ),
                          ),
                        ),
                        (AppIcons.share, l10n.tavernLorebookExport, () => unawaited(_export(ref, book))),
                        (
                          AppIcons.delete,
                          l10n.tavernLorebookDelete,
                          () => unawaited(_delete(context, ref, library.global, book)),
                        ),
                      ]),
                    ),
                  );
                }(),
            ],
          ),
      ],
    );
  }
}

/// Who a binding belongs to: a chat, a character or a persona, by id. The
/// global binding is the library page's own.
typedef TavernLorebookScope = ({WorldInfoSource source, String id});

/// The lorebooks bound to [TavernLorebookScope], beside the global ones: a
/// chat's in its own settings, a character's and a persona's in the global
/// settings by id.
final tavernLorebookBindingProvider = FutureProvider.autoDispose.family<List<String>, TavernLorebookScope>((
  ref,
  scope,
) async {
  final tavern = ref.watch(tavernProvider);
  final chat = scope.source == WorldInfoSource.chat;
  final settings = await tavern.readSettings(chatId: chat ? scope.id : null);
  final ids = switch (scope.source) {
    WorldInfoSource.chat => switch (settings['lorebooks']) {
      {'chat': final Object? ids} => ids,
      _ => null,
    },
    WorldInfoSource.character => switch (settings['characterLorebooks']) {
      final Map<String, Object?> byId => byId[scope.id],
      _ => null,
    },
    WorldInfoSource.persona => switch (settings['personaLorebooks']) {
      final Map<String, Object?> byId => byId[scope.id],
      _ => null,
    },
    _ => null,
  };
  return [
    if (ids is List<Object?>)
      for (final id in ids) '$id',
  ];
});

Future<void> _bind(Tavern tavern, TavernLorebookScope scope, List<String> ids) => switch (scope.source) {
  WorldInfoSource.chat => tavern.bindLorebooks(ids, source: WorldInfoSource.chat, chatId: scope.id),
  WorldInfoSource.character => tavern.bindLorebooks(ids, source: WorldInfoSource.character, characterId: scope.id),
  WorldInfoSource.persona => tavern.bindLorebooks(ids, source: WorldInfoSource.persona, personaId: scope.id),
  _ => tavern.bindLorebooks(ids),
};

/// A row saying how many lorebooks [scope] has bound; it opens the picker.
class TavernLorebookBindingTile extends ConsumerWidget {
  const TavernLorebookBindingTile({
    super.key,
    required this.scope,
    required this.title,
    required this.sheetTitle,
    required this.note,
    this.subtitle,
    this.icon = AppIcons.lorebook,
    this.enabled = true,
  });

  final TavernLorebookScope scope;
  final String title;
  final String? subtitle;

  /// Null in a card whose rows have none.
  final IconData? icon;

  /// The picker's title, and what the binding does, under it.
  final String sheetTitle;
  final String note;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final bound = ref.watch(tavernLorebookBindingProvider(scope)).value;
    return SettingsTile(
      icon: icon,
      tinted: false,
      title: title,
      subtitle: subtitle,
      value: Text(switch (bound) {
        null => '',
        [] => l10n.tavernLorebookNone,
        final ids => l10n.tavernLorebookCount(ids.length),
      }),
      onTap: enabled
          ? () => unawaited(showTavernLorebookPicker(context, scope: scope, title: sheetTitle, note: note))
          : null,
    );
  }
}

/// The library's lorebooks, each on or off for [scope]; a change is saved at
/// once. A book still bound after it was deleted shows too, to be let go.
Future<void> showTavernLorebookPicker(
  BuildContext context, {
  required TavernLorebookScope scope,
  required String title,
  required String note,
}) => showAppSheet<void>(
  context,
  builder: (sheet) => _LorebookPicker(scope: scope, title: title, note: note),
);

class _LorebookPicker extends ConsumerStatefulWidget {
  const _LorebookPicker({required this.scope, required this.title, required this.note});

  final TavernLorebookScope scope;
  final String title;
  final String note;

  @override
  ConsumerState<_LorebookPicker> createState() => _LorebookPickerState();
}

class _LorebookPickerState extends ConsumerState<_LorebookPicker> {
  /// What this sheet has set, ahead of the engine; null until changed.
  List<String>? _ids;

  /// Saves run one after another, each with the whole list as it then was.
  Future<void> _saving = Future.value();

  void _set(List<String> current, String id, bool on) {
    final ids = [
      for (final b in current)
        if (b != id) b,
      if (on) id,
    ];
    setState(() => _ids = ids);
    final l10n = context.l10n;
    final tavern = ref.read(tavernProvider);
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    _saving = _saving.then((_) async {
      try {
        await _bind(tavern, widget.scope, ids);
      } on Object {
        // Back to what the engine has.
        if (mounted) setState(() => _ids = null);
        messenger?.showBriefNotice(l10n.commonSaveFailed);
      }
      container.invalidate(tavernLorebookBindingProvider(widget.scope));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final library = ref.watch(tavernLorebooksProvider).value;
    final bound = _ids ?? ref.watch(tavernLorebookBindingProvider(widget.scope)).value;
    final known = {for (final book in library?.books ?? const <TavernLorebookSummary>[]) book.id};
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(widget.title),
          Padding(
            padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 12),
            child: Text(
              widget.note,
              style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5),
            ),
          ),
          if (library == null || bound == null)
            const QuietSpinner()
          else if (library.books.isEmpty && bound.isEmpty)
            SheetGroup(
              margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
              children: [
                SettingsTile(
                  key: const ValueKey('tavern-bind-lorebook-library'),
                  icon: AppIcons.add,
                  tinted: false,
                  title: l10n.tavernLorebookOpenLibrary,
                  subtitle: l10n.tavernLorebookPickEmpty,
                  onTap: () {
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    unawaited(navigator.push(TavernLorebooksPage.route()));
                  },
                ),
              ],
            )
          else
            Flexible(
              child: SingleChildScrollView(
                child: SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    for (final book in library.books)
                      SettingsSwitchTile(
                        key: ValueKey('tavern-bind-lorebook-${book.id}'),
                        icon: AppIcons.lorebook,
                        tinted: false,
                        title: book.name,
                        subtitle: [
                          l10n.tavernLorebookEntries(book.entryCount),
                          if (library.global.contains(book.id)) l10n.tavernLorebookGlobal,
                        ].join(' · '),
                        value: bound.contains(book.id),
                        onChanged: (on) => _set(bound, book.id, on),
                      ),
                    for (final id in bound)
                      if (!known.contains(id))
                        SettingsSwitchTile(
                          key: ValueKey('tavern-bind-lorebook-$id'),
                          icon: AppIcons.lorebook,
                          tinted: false,
                          title: l10n.tavernLorebookMissing,
                          subtitle: l10n.tavernLorebookMissingSubtitle,
                          value: true,
                          onChanged: (on) => _set(bound, id, on),
                        ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
