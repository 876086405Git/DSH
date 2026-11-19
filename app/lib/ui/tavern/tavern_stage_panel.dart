// 舞台: the chat's side panel (docs/design/roleplay-ui.md §2 layer 4, §8;
// roleplay-agent.md §2–3; roleplay-roadmap.md §2). Four pages: 本局 (what
// this chat runs on and looks like, and where else to go from it), 状态 (the
// card's state: relations, numbers, things, the time and place), 导演 (the
// director's notes and next beat) and 本回合 (what went into this turn:
// lorebook entries, tokens, the cache).

import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_backgrounds.dart';
import '../../tavern/tavern_bookmarks.dart';
import '../../tavern/tavern_card_scripts.dart' show tavernChatScriptsProvider;
import '../../tavern/tavern_card_theme.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_session_usage.dart';
import '../../tavern/tavern_settings.dart';
import '../../tavern/tavern_state_hints.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/search_capsule.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_arrive.dart';
import 'tavern_audio_section.dart';
import 'tavern_chat_tool_section.dart';
import 'tavern_bookmarks_page.dart';
import 'tavern_branches_page.dart';
import 'tavern_character_page.dart';
import 'tavern_chat_files.dart';
import 'tavern_inspector_page.dart';
import 'tavern_lorebooks_page.dart';
import 'tavern_message_edit_page.dart';
import 'tavern_pack_bindings_page.dart';
import 'tavern_model_rows.dart';
import 'tavern_personas.dart';
import 'tavern_presets_page.dart';
import 'tavern_runs_page.dart';
import 'tavern_search_page.dart';
import 'tavern_storybook_page.dart';
import 'tavern_widgets.dart';

enum TavernStageTab { session, state, director, turn }

class TavernStagePanel extends ConsumerStatefulWidget {
  const TavernStagePanel({
    super.key,
    required this.chatId,
    this.turn,
    this.topInset = 0,
    this.characterId,
    this.scriptsCharacterId,
    this.name = '',
    this.busy = false,
    this.onSuggest,
    this.onStateChanged,
  });

  final String chatId;

  /// The newest message's node: a new one means a new turn to read.
  final String? turn;

  /// Clear of the chat's header when the panel stands beside the chat.
  final double topInset;

  /// The chat's character, and the name the export and storybook go by.
  final String? characterId;

  /// Whose card's scripts run on the canvas: none in a group.
  final String? scriptsCharacterId;
  final String name;

  /// A reply is being written: the persona waits until it is done.
  final bool busy;

  /// One of the director's suggestions, picked: into the chat's box.
  final ValueChanged<String>? onSuggest;

  /// The state was changed by hand here: what reads it (the header's pinned
  /// line) reads it again.
  final VoidCallback? onStateChanged;

  @override
  ConsumerState<TavernStagePanel> createState() => _TavernStagePanelState();
}

class _TavernStagePanelState extends ConsumerState<TavernStagePanel> {
  /// 本局 first: what is used most.
  TavernStageTab _tab = TavernStageTab.session;

  /// Read when 本回合 is first shown: a whole turn's prompt is large, and
  /// opening the panel should not wait on it.
  Future<TavernTurnInspection?>? _record;

  Future<TavernTurnInspection?> _read() => ref.read(tavernProvider).inspectTurn(widget.chatId);

  /// The current line's replies added up (本局用量), read again each turn.
  late Future<TavernSessionUsage> _usage = tavernSessionUsage(ref.read(tavernProvider), widget.chatId);

  @override
  void didUpdateWidget(TavernStagePanel old) {
    super.didUpdateWidget(old);
    if (old.turn != widget.turn || old.chatId != widget.chatId) {
      _record = null;
      _usage = tavernSessionUsage(ref.read(tavernProvider), widget.chatId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return ListView(
      key: const ValueKey('tavern-stage'),
      padding: EdgeInsets.fromLTRB(16, widget.topInset + 16, 16, 24),
      children: [
        Text(l10n.tavernStage, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        SegmentedPill<TavernStageTab>(
          key: const ValueKey('tavern-stage-tabs'),
          expand: true,
          segments: [
            PillSegment(TavernStageTab.session, l10n.tavernStageSession),
            PillSegment(TavernStageTab.state, l10n.tavernStageState),
            PillSegment(TavernStageTab.director, l10n.tavernStageDirector),
            PillSegment(TavernStageTab.turn, l10n.tavernStageTurn),
          ],
          selected: _tab,
          onChanged: (tab) => setState(() => _tab = tab),
        ),
        const SizedBox(height: 16),
        switch (_tab) {
          TavernStageTab.session => _Session(
            key: const ValueKey('tavern-stage-session'),
            usage: _usage,
            chatId: widget.chatId,
            characterId: widget.characterId,
            scriptsCharacterId: widget.scriptsCharacterId,
            name: widget.name,
            busy: widget.busy,
          ),
          // The card's state (engine T17), or what an older card's macros saved.
          TavernStageTab.state => _StateView(
            key: const ValueKey('tavern-stage-state-view'),
            chatId: widget.chatId,
            turn: widget.turn,
            onChanged: widget.onStateChanged,
          ),
          TavernStageTab.director => _DirectorView(
            key: const ValueKey('tavern-stage-director-view'),
            chatId: widget.chatId,
            onSuggest: widget.onSuggest,
          ),
          TavernStageTab.turn => FutureBuilder<TavernTurnInspection?>(
            future: _record ??= _read(),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: QuietSpinner()),
                );
              }
              final record = snapshot.data;
              if (snapshot.hasError || record == null) {
                return _Waiting(
                  key: const ValueKey('tavern-stage-turn-none'),
                  icon: AppIcons.code,
                  title: l10n.tavernStageTurnNone,
                  message: l10n.tavernInspectNoneMessage,
                );
              }
              return _ThisTurn(chatId: widget.chatId, record: record);
            },
          ),
        },
      ],
    );
  }
}

/// 本局: what this chat runs on, how it looks, and where else to go from it.
class _Session extends ConsumerWidget {
  const _Session({
    super.key,
    required this.usage,
    required this.chatId,
    required this.characterId,
    required this.scriptsCharacterId,
    required this.name,
    required this.busy,
  });

  final Future<TavernSessionUsage> usage;
  final String chatId;
  final String? characterId;
  final String? scriptsCharacterId;
  final String name;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(tavernSettingsProvider);
    final own = ref.watch(tavernChatLayoutProvider(chatId));
    final layout = ref.read(tavernChatLayoutProvider(chatId).notifier);
    final scene = ref.watch(tavernChatBackgroundProvider(chatId));
    final persona = ref.watch(tavernPersonaSelectionProvider(chatId)).value?.persona;
    final preset = ref.watch(tavernPresetSelectionProvider(chatId)).value;
    final presets = ref.watch(tavernPresetsProvider).value ?? const <TavernPresetSummary>[];
    final characterId = this.characterId;

    /// On a phone the panel is a drawer: close it on the way to a page.
    void open(Route<void> route) {
      Scaffold.maybeOf(context)?.closeEndDrawer();
      unawaited(Navigator.of(context).push(route));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FutureBuilder<TavernSessionUsage>(
          future: usage,
          builder: (context, snapshot) => switch (snapshot.data) {
            final usage? => _SessionUsageView(usage: usage),
            null => const SizedBox.shrink(),
          },
        ),
        SettingsSection(
          title: l10n.tavernSessionUsing,
          margin: const EdgeInsets.only(bottom: 12),
          children: [
            ...tavernModelRows(
              context,
              ref,
              keyPrefix: 'tavern-session',
              tinted: false,
              thinkingSubtitle: false,
              open: open,
            ),
            SettingsTile(
              key: const ValueKey('tavern-chat-persona'),
              icon: AppIcons.profile,
              tinted: false,
              title: l10n.tavernPersona,
              value: Text(persona?.name ?? l10n.tavernPersonaNone),
              onTap: busy ? null : () => unawaited(showTavernPersonaPicker(context, chatId)),
            ),
            SettingsTile(
              key: const ValueKey('tavern-chat-preset'),
              icon: AppIcons.article,
              tinted: false,
              title: l10n.tavernPresets,
              // A long name stops short of the title; the picker says which the default is.
              value: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  switch (preset) {
                    null => '',
                    TavernPresetSelection(:final boundPresetId?) => tavernPresetName(context, presets, boundPresetId),
                    _ => l10n.tavernPresetFollow,
                  },
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              onTap: busy ? null : () => unawaited(showTavernPresetPicker(context, chatId)),
            ),
            TavernLorebookBindingTile(
              key: const ValueKey('tavern-chat-lorebooks'),
              scope: (source: WorldInfoSource.chat, id: chatId),
              title: l10n.tavernLorebooks,
              sheetTitle: l10n.tavernLorebookForChat,
              note: l10n.tavernLorebookChatNote,
              enabled: !busy,
            ),
            SettingsTile(
              key: const ValueKey('tavern-chat-packs'),
              icon: AppIcons.zip,
              tinted: false,
              title: l10n.tavernPacks,
              onTap: () => open(
                TavernPackBindingsPage.route(
                  (kind: TavernGameplayScope.chat, targetId: chatId),
                  characterId: characterId,
                  chatId: chatId,
                ),
              ),
            ),
            if (ref.watch(tavernChatScriptsProvider((chatId, scriptsCharacterId))).value case final chosen?
                when chosen.scripts.isNotEmpty || chosen.issues.isNotEmpty)
              SettingsTile(
                key: const ValueKey('tavern-chat-scripts'),
                icon: AppIcons.code,
                tinted: false,
                title: l10n.tavernChatScripts,
                value: Text(l10n.tavernScriptCount(chosen.scripts.length)),
                onTap: () => unawaited(_showChatScripts(context, chosen)),
              ),
          ],
        ),
        SettingsSection(
          title: l10n.tavernSessionLook,
          margin: const EdgeInsets.only(bottom: 12),
          children: [
            SettingsSegmentTile<TavernLayout>(
              key: const ValueKey('tavern-chat-layout'),
              title: l10n.tavernChatLayout,
              tinted: false,
              segments: [
                PillSegment(TavernLayout.bubble, l10n.tavernLayoutBubble),
                PillSegment(TavernLayout.novel, l10n.tavernLayoutNovel),
                PillSegment(TavernLayout.visualNovel, l10n.tavernLayoutVisualNovel),
              ],
              selected: own ?? ref.watch(tavernCardThemeProvider(characterId))?.layout ?? settings.layout,
              onChanged: (value) => unawaited(layout.set(value)),
            ),
            if (own != null)
              SettingsTile(
                key: const ValueKey('tavern-chat-layout-follow'),
                icon: AppIcons.restart,
                tinted: false,
                title: l10n.tavernFollowSettings,
                onTap: () => unawaited(layout.set(null)),
              ),
            SettingsTile(
              key: const ValueKey('tavern-chat-background'),
              icon: AppIcons.addImage,
              tinted: false,
              title: l10n.tavernBackground,
              value: Text(scene == null ? l10n.tavernBackgroundNone : l10n.tavernBackgroundChange),
              onTap: () => unawaited(chooseTavernBackground(context, ref, chatId)),
            ),
            if (scene != null)
              SettingsTile(
                key: const ValueKey('tavern-chat-background-remove'),
                icon: AppIcons.remove,
                tinted: false,
                title: l10n.tavernBackgroundRemove,
                chevron: false,
                onTap: () => unawaited(ref.read(tavernChatBackgroundProvider(chatId).notifier).remove()),
              ),
          ],
        ),
        TavernAudioSection(chatId: chatId),
        TavernChatToolSection(chatId: chatId),
        SettingsSection(
          title: l10n.tavernSessionMore,
          margin: EdgeInsets.zero,
          children: [
            if (characterId != null)
              SettingsTile(
                key: const ValueKey('tavern-character-details'),
                icon: AppIcons.info,
                tinted: false,
                title: l10n.tavernCharacterDetails,
                onTap: () => open(TavernCharacterPage.route(characterId)),
              ),
            SettingsTile(
              key: const ValueKey('tavern-chat-search'),
              icon: AppIcons.search,
              tinted: false,
              title: l10n.tavernSearchChat,
              onTap: () => open(TavernSearchPage.route(chatId)),
            ),
            SettingsTile(
              key: const ValueKey('tavern-bookmarks'),
              icon: AppIcons.bookmark,
              tinted: false,
              title: l10n.tavernBookmarks,
              value: switch (ref.watch(tavernBookmarksProvider(chatId)).length) {
                0 => null,
                final n => Text('$n'),
              },
              onTap: () => open(TavernBookmarksPage.route(chatId)),
            ),
            SettingsTile(
              key: const ValueKey('tavern-chat-branches'),
              icon: AppIcons.fork,
              tinted: false,
              title: l10n.tavernBranches,
              onTap: () => open(TavernBranchesPage.route(chatId)),
            ),
            SettingsTile(
              key: const ValueKey('tavern-chat-inspect'),
              icon: AppIcons.code,
              tinted: false,
              title: l10n.tavernInspectLatest,
              onTap: () => open(TavernInspectorPage.route(chatId)),
            ),
            SettingsTile(
              key: const ValueKey('tavern-chat-export'),
              icon: AppIcons.share,
              tinted: false,
              title: l10n.tavernExportChat,
              onTap: () => unawaited(exportTavernChat(context, ref, chatId, title: name)),
            ),
            SettingsTile(
              key: const ValueKey('tavern-chat-storybook'),
              icon: AppIcons.bookmark,
              tinted: false,
              title: l10n.tavernStorybookMenu,
              onTap: () => open(
                TavernStorybookPage.route(
                  chatId: chatId,
                  character: name,
                  avatarPath: ref
                      .read(tavernCharactersProvider)
                      .value
                      ?.where((c) => c.id == characterId)
                      .firstOrNull
                      ?.avatarPath,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A picture from the gallery under [chatId]; says so when one can't be used.
Future<void> chooseTavernBackground(BuildContext context, WidgetRef ref, String chatId) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final problem = await ref.read(tavernChatBackgroundProvider(chatId).notifier).choose();
  final text = switch (problem) {
    null || LaunchImportProblem.cancelled => null,
    LaunchImportProblem.unavailable => l10n.wallpaperUnavailable,
    LaunchImportProblem.tooLarge || LaunchImportProblem.overLimit => l10n.wallpaperTooLarge,
    LaunchImportProblem.unsupported => l10n.wallpaperUnsupported,
    LaunchImportProblem.unreadable => l10n.wallpaperUnreadable,
  };
  if (text != null) messenger?.showBriefNotice(text);
}

/// 状态 (engine T17): the card's state as of the current message, or, for a
/// card without one, what its macros saved. Each top-level value is a row;
/// what changed this turn carries a mark (「+5」), what the card keeps from the
/// model is folded like a spoiler, and a tap shows one whole and lets it be
/// changed (docs/design/roleplay-ui.md §8).
/// The scripts [chosen] runs, in order, each with where it comes from; and
/// what the engine passed over, as it says it.
Future<void> _showChatScripts(BuildContext context, TavernChatScripts chosen) => showAppSheet<void>(
  context,
  builder: (sheet) {
    final l10n = sheet.l10n;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(l10n.tavernChatScripts),
          Padding(
            padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 6),
            child: Text(
              l10n.tavernChatScriptsNote,
              style: Theme.of(sheet).textTheme.bodySmall?.copyWith(color: DshColors.of(sheet).textTertiary),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: SheetGroup(
                margin: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                children: [
                  for (final s in chosen.scripts)
                    SettingsTile(
                      tinted: false,
                      title: s.name.isEmpty ? l10n.tavernScriptUnnamed : s.name,
                      value: Text(switch (s.owner.kind) {
                        TavernScriptOwnerKind.global => l10n.tavernScriptSourceGlobal,
                        TavernScriptOwnerKind.preset => l10n.tavernScriptSourcePreset,
                        TavernScriptOwnerKind.character => l10n.tavernScriptSourceCard,
                      }),
                    ),
                  if (chosen.issues.isNotEmpty)
                    SettingsTile(
                      key: const ValueKey('tavern-chat-scripts-skipped'),
                      icon: AppIcons.error,
                      tinted: false,
                      title: l10n.tavernChatScriptsSkipped(chosen.issues.length),
                      subtitle: chosen.issues.map((i) => i.message).join('\n'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  },
);

class _StateView extends ConsumerStatefulWidget {
  const _StateView({super.key, required this.chatId, required this.turn, this.onChanged});

  /// An edit went in.
  final VoidCallback? onChanged;

  final String chatId;

  /// The newest message's node: a new one means the state to read again.
  final String? turn;

  @override
  ConsumerState<_StateView> createState() => _StateViewState();
}

class _StateViewState extends ConsumerState<_StateView> {
  late Future<TavernStateSnapshot> _state = _read();

  Future<TavernStateSnapshot> _read() => ref.read(tavernProvider).readState(widget.chatId);

  @override
  void didUpdateWidget(_StateView old) {
    super.didUpdateWidget(old);
    if (old.turn != widget.turn || old.chatId != widget.chatId) _state = _read();
  }

  /// [key] as a JSON Pointer under the root.
  static String _pointer(String key) => '/${key.replaceAll('~', '~0').replaceAll('/', '~1')}';

  /// [value] on a line: text as written, a list of words as a list (a bag,
  /// say), the rest as compact JSON; one the card draws on a line, its parts
  /// side by side.
  static String _line(Object? value, [TavernStateShow? show]) =>
      show == TavernStateShow.line ? tavernStateLine(value) : tavernStateText(value);

  /// What changed at or under [path] in this message: a number's difference,
  /// or that it changed.
  static String? _mark(TavernStateSnapshot state, String path, L10n l10n) {
    final hits = [
      for (final change in state.changes)
        if (change['path'] case final String at when at == path || at.startsWith('$path/') || path.isEmpty) change,
    ];
    if (hits.isEmpty) return null;
    if (hits.length == 1 &&
        hits.single['path'] == path &&
        hits.single['oldExists'] == true &&
        hits.single['newExists'] == true) {
      if ((hits.single['old'], hits.single['new']) case (final num old, final num now) when now != old) {
        final delta = now - old;
        final shown = delta == delta.roundToDouble() ? delta.round().abs().toString() : delta.abs().toString();
        return delta > 0 ? '+$shown' : '−$shown';
      }
    }
    return l10n.tavernStateChanged;
  }

  /// Kept from the model: at, above or below a hidden path.
  static bool _hidden(TavernStateSnapshot state, String path) =>
      state.hiddenPaths.any((at) => at == path || path.startsWith('$at/') || at.startsWith('$path/') || path.isEmpty);

  Future<void> _open(TavernStateSnapshot state, String title, String path, Object? value) async {
    final l10n = context.l10n;
    final edit = await showAppSheet<bool>(
      context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(title),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 8),
                  child: SelectableText(
                    value is String ? value : const JsonEncoder.withIndent('  ').convert(value),
                    key: const ValueKey('tavern-variable-whole'),
                    style: Theme.of(sheet).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.5),
                  ),
                ),
              ),
              // Saved at a message: there is one to change it on.
              if (state.nodeId != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      key: const ValueKey('tavern-state-edit'),
                      onPressed: () => Navigator.of(sheet).pop(true),
                      child: Text(l10n.tavernStateEdit),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (edit != true || !mounted) return;
    await _edit(state, title, path, value);
  }

  /// [value] changed in the whole-page editor: text kept as written, anything
  /// else as JSON. The engine checks it against the card's rules; whether it
  /// went in is said either way.
  Future<void> _edit(TavernStateSnapshot state, String title, String path, Object? value) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final text = await Navigator.of(context).push(
      TavernMessageEditPage.route(
        title: title,
        speaker: value is String ? l10n.tavernStateEditText : l10n.tavernStateEditJson,
        text: value is String ? value : const JsonEncoder.withIndent('  ').convert(value),
      ),
    );
    if (text == null || !mounted) return;
    final Object? next;
    if (value is String) {
      next = text;
    } else {
      try {
        next = jsonDecode(text);
      } on FormatException {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(l10n.tavernStateEditBad)));
        return;
      }
    }
    try {
      final result = await ref
          .read(tavernProvider)
          .setStateValue(widget.chatId, path, next, expectedNodeId: state.nodeId);
      if (!mounted) return;
      setState(() {
        _state = Future.value(result.snapshot);
      });
      if (result.changed) widget.onChanged?.call();
      final reason = [for (final issue in result.issues) '${issue['message'] ?? issue['code'] ?? ''}']
          .where((line) => line.isNotEmpty)
          .join('；');
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              !result.applied
                  ? l10n.tavernStateEditRefused(reason)
                  : result.changed
                  ? l10n.tavernStateEditSaved
                  : l10n.tavernStateEditSame,
            ),
          ),
        );
    } on Object catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.tavernStateEditRefused('$e'))));
    }
  }

  /// Branches opened by a tap, by path.
  final _expanded = <String>{};

  /// What 搜 holds; with words in it the tree lies flat, every match by path.
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// [value] opens into rows of its own: an object, or a list not all words
  /// (a list of words stays one line, as a bag reads).
  static bool _branch(Object? value) =>
      (value is Map<String, Object?> && value.isNotEmpty) ||
      (value is List<Object?> && value.isNotEmpty && !value.every((item) => item is String));

  /// The rows under [value] at [path], opened ones' children after them; with
  /// [all], every row regardless, for 搜. One the card's [schema] says how to
  /// draw is drawn whole on its row, never opened.
  static void _walk(
    List<_StateRow> rows,
    String title,
    String trail,
    String path,
    Object? value,
    int depth, {
    required Object? schema,
    required bool Function(String path) open,
    required bool all,
  }) {
    final show = tavernStateShow(schema, path, value);
    rows.add((title: title, trail: trail, path: path, value: value, depth: depth, show: show));
    if (show != null || !_branch(value) || !(all || open(path))) return;
    switch (value) {
      case final Map<String, Object?> map:
        for (final key in map.keys) {
          _walk(
            rows,
            key,
            '$trail › $key',
            '$path${_pointer(key)}',
            map[key],
            depth + 1,
            schema: schema,
            open: open,
            all: all,
          );
        }
      case final List<Object?> list:
        for (var i = 0; i < list.length; i++) {
          _walk(rows, '[$i]', '$trail › [$i]', '$path/$i', list[i], depth + 1, schema: schema, open: open, all: all);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return FutureBuilder<TavernStateSnapshot>(
      future: _state,
      builder: (context, snapshot) {
        final state = snapshot.data;
        if (state == null && !snapshot.hasError) return const SizedBox.shrink();
        // What is saved; with nothing saved yet, the card's starting values.
        final preview = state != null && !state.valueExists && state.initialValuesAvailable;
        final values = state == null ? null : (preview ? state.initialValues : state.values);
        final top = <(String, String, Object?)>[
          if (values case final Map<String, Object?> map)
            for (final key in state!.legacy ? (map.keys.toList()..sort()) : map.keys) (key, _pointer(key), map[key])
          else if (state != null && (state.valueExists || preview))
            (l10n.tavernStateWhole, '', values),
        ];
        final issues = [
          for (final issue in state?.issues ?? const <Map<String, Object?>>[])
            '${issue['message'] ?? issue['code'] ?? ''}',
        ].where((line) => line.isNotEmpty).toList();
        if (state == null || (top.isEmpty && issues.isEmpty)) {
          return _Waiting(
            key: const ValueKey('tavern-stage-state'),
            icon: AppIcons.chart,
            title: l10n.tavernStageStateEmpty,
            message: l10n.tavernStageStateNote,
          );
        }
        // How the card asks its fields to be drawn; a card without state has none.
        final schema = state.legacy ? null : state.schema;
        // Every row, for 搜 and to know whether there are enough to search.
        final every = <_StateRow>[];
        for (final (title, path, value) in top) {
          _walk(every, title, title, path, value, 0, schema: schema, open: (_) => true, all: true);
        }
        final query = _query.trim().toLowerCase();
        final rows = <_StateRow>[];
        if (query.isEmpty) {
          for (final (title, path, value) in top) {
            _walk(
              rows,
              title,
              title,
              path,
              value,
              0,
              schema: schema,
              open: (path) => _expanded.contains(path) && !_hidden(state, path),
              all: false,
            );
          }
        } else {
          // Flat: each match by its whole path; a spoiler matches by name only.
          for (final row in every) {
            final shown = _hidden(state, row.path) ? '' : _line(row.value, row.show);
            if (row.trail.toLowerCase().contains(query) ||
                ((row.show != null || !_branch(row.value)) && shown.toLowerCase().contains(query))) {
              rows.add((
                title: row.trail,
                trail: row.trail,
                path: row.path,
                value: row.value,
                depth: 0,
                show: row.show,
              ));
            }
          }
        }
        final quiet = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.72));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (every.length >= 8) ...[
              SearchCapsule(
                key: const ValueKey('tavern-state-search'),
                controller: _search,
                hint: l10n.tavernStateSearch,
                onChanged: (q) => setState(() => _query = q),
                onClear: () => setState(() {
                  _search.clear();
                  _query = '';
                }),
              ),
              const SizedBox(height: 12),
            ],
            SettingsSection(
              key: const ValueKey('tavern-stage-variables'),
              title: state.legacy ? l10n.tavernStateVariables : l10n.tavernStageState,
              footer: Text(
                [
                  if (preview) l10n.tavernStatePreview,
                  state.legacy ? l10n.tavernStateVariablesNote : l10n.tavernStateNote,
                ].join('\n'),
              ),
              margin: EdgeInsets.zero,
              children: [
                if (rows.isEmpty)
                  Padding(
                    key: const ValueKey('tavern-state-no-match'),
                    padding: const EdgeInsets.all(SettingsMetrics.inset),
                    child: Text(l10n.tavernStateNoMatch, style: quiet),
                  ),
                for (final row in rows)
                  () {
                    final hidden = _hidden(state, row.path);
                    final show = hidden ? null : row.show;
                    final branch = show == null && _branch(row.value) && !hidden && query.isEmpty;
                    final open = branch && _expanded.contains(row.path);
                    final count = switch (row.value) {
                      final Map<String, Object?> map => map.length,
                      final List<Object?> list => list.length,
                      _ => 0,
                    };
                    // A bag or a list the card asks for goes under the name, the
                    // row's right side saying how many.
                    final below = switch (show) {
                      TavernStateShow.inventory when count > 0 => _StateGoods(
                        key: ValueKey('tavern-state-goods-${row.path}'),
                        goods: tavernStateGoods(row.value),
                      ),
                      TavernStateShow.list when count > 0 => _StateEntries(
                        key: ValueKey('tavern-state-list-${row.path}'),
                        entries: tavernStateEntries(row.value),
                      ),
                      _ => null,
                    };
                    final quietValue = hidden ? quiet?.copyWith(fontStyle: FontStyle.italic) : quiet;
                    final Widget value = switch (show) {
                      _ when hidden => Text(
                        l10n.tavernStateHidden,
                        textAlign: TextAlign.end,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: quietValue,
                      ),
                      TavernStateShow.bar => Row(
                        children: [
                          Expanded(
                            child: _StateBar(
                              key: ValueKey('tavern-state-bar-${row.path}'),
                              fraction: tavernStateFraction(
                                row.value! as num,
                                tavernStateRange(tavernStateSchemaAt(schema, row.path)!)!,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(_line(row.value), style: quiet),
                        ],
                      ),
                      TavernStateShow.tags when count > 0 => _StateTags(
                        key: ValueKey('tavern-state-tags-${row.path}'),
                        tags: [for (final tag in row.value! as List<Object?>) tavernStateText(tag)],
                      ),
                      _ => Text(
                        branch ||
                                show == TavernStateShow.tags ||
                                show == TavernStateShow.inventory ||
                                show == TavernStateShow.list
                            ? l10n.tavernStateItems(count)
                            : _line(row.value, show),
                        textAlign: TextAlign.end,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: quietValue,
                      ),
                    };
                    return InkWell(
                      key: ValueKey(
                        row.depth == 0 && query.isEmpty
                            ? 'tavern-variable-${row.title}'
                            : 'tavern-variable-${row.path}',
                      ),
                      // A branch opens and closes; a long press, or a leaf's tap,
                      // shows it whole to read or change.
                      onTap: branch
                          ? () => setState(() => open ? _expanded.remove(row.path) : _expanded.add(row.path))
                          : () => unawaited(_open(state, row.trail, row.path, row.value)),
                      onLongPress: () => unawaited(_open(state, row.trail, row.path, row.value)),
                      splashFactory: rowSplash(context),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          SettingsMetrics.inset + 16.0 * row.depth,
                          10,
                          SettingsMetrics.inset,
                          10,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: show == TavernStateShow.bar
                                  ? CrossAxisAlignment.center
                                  : CrossAxisAlignment.start,
                              children: [
                                ConstrainedBox(
                                  constraints: BoxConstraints(maxWidth: query.isEmpty ? 120 : 200),
                                  child: Text(
                                    row.title,
                                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                                if (_mark(state, row.path, l10n) case final mark?) ...[
                                  const SizedBox(width: 6),
                                  // Fades in as the turn brings it; a new
                                  // change fades in afresh.
                                  TavernArrive(
                                    key: ValueKey(('tavern-state-change-arrive', state.nodeId, row.path, mark)),
                                    child: Text(
                                      mark,
                                      key: ValueKey('tavern-state-change-${row.title}'),
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.primary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(width: 12),
                                Expanded(child: value),
                                if (branch) ...[
                                  const SizedBox(width: 4),
                                  AnimatedRotation(
                                    turns: open ? 0.25 : 0,
                                    duration: AppMotion.of(context, AppMotion.standard),
                                    child: Icon(AppIcons.disclosure, size: 18, color: dsh.textTertiary),
                                  ),
                                ],
                              ],
                            ),
                            if (below != null) ...[const SizedBox(height: 10), below],
                          ],
                        ),
                      ),
                    );
                  }(),
              ],
            ),
            // The engine's word on what it could not read or keep.
            if (issues.isNotEmpty)
              Padding(
                key: const ValueKey('tavern-state-issues'),
                padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 10, SettingsMetrics.inset, 0),
                child: Text(
                  issues.join('\n'),
                  style: theme.textTheme.bodySmall?.copyWith(color: dsh.danger, height: 1.5),
                ),
              ),
            // Who changed what, and what ran behind the story. On a phone the
            // panel is a drawer: closed on the way.
            SettingsSection(
              margin: const EdgeInsets.only(top: 16),
              children: [
                SettingsTile(
                  key: const ValueKey('tavern-state-runs'),
                  icon: AppIcons.history,
                  title: l10n.tavernRuns,
                  onTap: () {
                    Scaffold.maybeOf(context)?.closeEndDrawer();
                    unawaited(Navigator.of(context).push(TavernRunsPage.route(widget.chatId)));
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// One row of 状态: its name, its whole path to show, its pointer, its value,
/// how deep it sits, and how the card asks it to be drawn.
typedef _StateRow = ({String title, String trail, String path, Object? value, int depth, TavernStateShow? show});

/// A field the card draws as a bar (a bond, say): filled [fraction] of the way
/// between the schema's ends, easing to a new value.
class _StateBar extends StatelessWidget {
  const _StateBar({super.key, required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final tint = Theme.of(context).colorScheme.primary;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: fraction),
      duration: AppMotion.of(context, AppMotion.standard),
      curve: Curves.easeOutCubic,
      builder: (context, at, _) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 6,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: tint.withValues(alpha: 0.14)),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: at,
                child: ColoredBox(color: tint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A field the card draws as tags: small capsules, from the right.
class _StateTags extends StatelessWidget {
  const _StateTags({super.key, required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in tags)
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              child: Text(tag, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
            ),
          ),
      ],
    );
  }
}

/// A field the card draws as a bag: a cell for each thing, how many under it
/// when there is more (or less) than one.
class _StateGoods extends StatelessWidget {
  const _StateGoods({super.key, required this.goods});

  final List<TavernStateGood> goods;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final good in goods)
          Container(
            constraints: const BoxConstraints(minWidth: 64, maxWidth: 160),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: ink.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ink.withValues(alpha: 0.08)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(good.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                if (good.count case final count? when count != 1)
                  Text(
                    '×${tavernStateText(count)}',
                    style: theme.textTheme.labelSmall?.copyWith(color: ink.withValues(alpha: 0.6)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A field the card draws as a list (tasks, say): one line each.
class _StateEntries extends StatelessWidget {
  const _StateEntries({super.key, required this.entries});

  final List<String> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
      height: 1.45,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('·  ', style: style),
                Expanded(child: Text(entry, style: style)),
              ],
            ),
          ),
      ],
    );
  }
}

/// 导演 (engine T18; docs/design/roleplay-agent.md §3): the director's latest
/// word on this chat, followed live. Its beat for the next turn, three things
/// you might do (a tap puts one in the box, never sends it), and its notes,
/// folded as spoilers. It runs on its own every few turns once turned on for
/// this chat, or once now on asking; either is one more model request.
class _DirectorView extends ConsumerStatefulWidget {
  const _DirectorView({super.key, required this.chatId, this.onSuggest});

  final String chatId;
  final ValueChanged<String>? onSuggest;

  @override
  ConsumerState<_DirectorView> createState() => _DirectorViewState();
}

class _DirectorViewState extends ConsumerState<_DirectorView> {
  StreamSubscription<TavernDirectorSnapshot>? _watch;
  TavernDirectorSnapshot? _shown;
  Object? _error;

  /// Asked for and not yet back: the button waits.
  bool _asking = false;

  /// The switch as just set, until the engine's next view says the same.
  bool? _auto;

  /// The notes, shown on asking.
  bool _notes = false;

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(_DirectorView old) {
    super.didUpdateWidget(old);
    if (old.chatId != widget.chatId) _follow();
  }

  @override
  void dispose() {
    unawaited(_watch?.cancel());
    super.dispose();
  }

  void _follow() {
    unawaited(_watch?.cancel());
    _watch = ref
        .read(tavernProvider)
        .watchDirector(widget.chatId)
        .listen(
          (snapshot) => setState(() {
            _shown = snapshot;
            _error = null;
            _auto = null;
          }),
          onError: (Object e) => setState(() => _error = e),
        );
  }

  Future<void> _setAuto(bool on) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(tavernProvider).setSettings({
        'director': {'enabled': on},
      }, chatId: widget.chatId);
      if (mounted) setState(() => _auto = on);
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.tavernDirectorRunFailed('$e'))));
    }
  }

  Future<void> _run() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _asking = true);
    try {
      final run = await ref.read(tavernProvider).runDirector(widget.chatId);
      if (!run.success) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.tavernDirectorFailed(run.failure ?? ''))));
      }
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.tavernDirectorRunFailed('$e'))));
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final shown = _shown;
    if (shown == null) {
      return _error == null
          ? const SizedBox.shrink()
          : _Waiting(
              key: const ValueKey('tavern-stage-director'),
              icon: AppIcons.error,
              title: l10n.tavernStageDirectorEmpty,
              message: '$_error',
            );
    }
    final busy = _asking || shown.running || shown.pendingJobs > 0;
    final success = shown.latestSuccess;
    final attempt = shown.latestAttempt;
    final failed = attempt != null && !attempt.success && attempt.id != success?.id ? attempt : null;
    final quiet = theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.5);
    final issues = [for (final issue in shown.issues) '${issue['message'] ?? issue['code'] ?? ''}']
        .where((line) => line.isNotEmpty)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          footer: Text(l10n.tavernDirectorAutoNote),
          margin: EdgeInsets.zero,
          children: [
            SettingsSwitchTile(
              key: const ValueKey('tavern-director-auto'),
              icon: AppIcons.lorebook,
              tinted: false,
              title: l10n.tavernDirectorAuto,
              value: _auto ?? shown.automaticEnabled,
              onChanged: (on) => unawaited(_setAuto(on)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            key: const ValueKey('tavern-director-run'),
            onPressed: busy ? null : () => unawaited(_run()),
            child: Text(busy ? l10n.tavernDirectorRunning : l10n.tavernDirectorRun),
          ),
        ),
        const SizedBox(height: 16),
        if (failed != null)
          Padding(
            key: const ValueKey('tavern-director-failed'),
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              l10n.tavernDirectorFailed(failed.failure ?? ''),
              style: theme.textTheme.bodySmall?.copyWith(color: dsh.danger, height: 1.5),
            ),
          ),
        if (success == null)
          _Waiting(
            key: const ValueKey('tavern-stage-director'),
            icon: AppIcons.lorebook,
            title: l10n.tavernStageDirectorEmpty,
            message: l10n.tavernStageDirectorNote,
          )
        else ...[
          // Thought for an earlier moment: kept to read, not offered to act on.
          if (shown.stale)
            Padding(
              key: const ValueKey('tavern-director-stale'),
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(l10n.tavernDirectorStale, style: quiet),
            ),
          if ((success.beat ?? '').trim().isNotEmpty) ...[
            SettingsSection(
              title: l10n.tavernDirectorBeat,
              margin: EdgeInsets.zero,
              children: [
                Padding(
                  padding: const EdgeInsets.all(SettingsMetrics.inset),
                  child: Text(
                    success.beat!.trim(),
                    key: const ValueKey('tavern-director-beat'),
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (!shown.stale && success.suggestions.isNotEmpty) ...[
            SettingsSection(
              title: l10n.tavernDirectorSuggestions,
              footer: Text(l10n.tavernDirectorSuggestionsNote),
              margin: EdgeInsets.zero,
              children: [
                for (final (i, suggestion) in success.suggestions.indexed)
                  if (suggestion['text'] case final String text when text.trim().isNotEmpty)
                    InkWell(
                      key: ValueKey('tavern-director-suggestion-$i'),
                      onTap: widget.onSuggest == null ? null : () => widget.onSuggest!(text.trim()),
                      splashFactory: rowSplash(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: SettingsMetrics.inset, vertical: 10),
                        child: SizedBox(
                          width: double.infinity,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(text.trim(), style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
                              if (suggestion['risk'] case final String risk when risk.trim().isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(risk.trim(), style: quiet),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if ((success.notes ?? '').trim().isNotEmpty)
            SettingsSection(
              title: l10n.tavernDirectorNotes,
              margin: EdgeInsets.zero,
              children: [
                InkWell(
                  key: const ValueKey('tavern-director-notes'),
                  onTap: () => setState(() => _notes = !_notes),
                  splashFactory: rowSplash(context),
                  child: Padding(
                    padding: const EdgeInsets.all(SettingsMetrics.inset),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _notes
                          ? SelectableText(
                              success.notes!.trim(),
                              style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                            )
                          : Text(l10n.tavernStateHidden, style: quiet?.copyWith(fontStyle: FontStyle.italic)),
                    ),
                  ),
                ),
              ],
            ),
        ],
        if (issues.isNotEmpty)
          Padding(
            key: const ValueKey('tavern-director-issues'),
            padding: const EdgeInsets.only(top: 12),
            child: Text(issues.join('\n'), style: theme.textTheme.bodySmall?.copyWith(color: dsh.danger, height: 1.5)),
          ),
      ],
    );
  }
}

/// A page whose contents the engine doesn't give yet: what will be here.
class _Waiting extends StatelessWidget {
  const _Waiting({super.key, required this.icon, required this.title, required this.message});

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 24, color: dsh.textTertiary),
          const SizedBox(height: 10),
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(message, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.5)),
        ],
      ),
    );
  }
}

/// 本回合: its tokens and cache, and the lorebook entries that went in.
class _ThisTurn extends StatelessWidget {
  const _ThisTurn({required this.chatId, required this.record});

  final String chatId;
  final TavernTurnInspection record;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final usage = record.reportedUsage;
    final hits = [
      for (final hit in (record.worldInfo['activated'] as List?) ?? const [])
        if (hit is Map) hit,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (usage == null)
          Text(
            l10n.tavernInspectNoUsage,
            key: const ValueKey('tavern-stage-no-usage'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
          )
        else
          Row(
            key: const ValueKey('tavern-stage-usage'),
            children: [
              TavernFigure(label: l10n.tavernStageTokensIn, value: '${usage.promptTokens}'),
              const SizedBox(width: 8),
              TavernFigure(
                label: l10n.tavernStageCache,
                value: usage.promptTokens == 0 ? '—' : '${(100 * usage.cacheHitTokens / usage.promptTokens).round()}%',
              ),
              const SizedBox(width: 8),
              TavernFigure(label: l10n.tavernStageTokensOut, value: '${usage.completionTokens}'),
            ],
          ),
        const SizedBox(height: 12),
        SettingsSection(
          title: l10n.tavernStageWorld,
          margin: EdgeInsets.zero,
          children: [
            if (hits.isEmpty)
              SettingsTile(key: const ValueKey('tavern-stage-world-none'), title: l10n.tavernStageWorldNone)
            else
              for (final hit in hits) TavernWorldHitTile(hit: hit),
          ],
        ),
        const SizedBox(height: 12),
        SettingsSection(
          margin: EdgeInsets.zero,
          children: [
            SettingsTile(
              key: const ValueKey('tavern-stage-inspect'),
              icon: AppIcons.code,
              tinted: false,
              title: l10n.tavernStageInspect,
              onTap: () => unawaited(Navigator.of(context).push(TavernInspectorPage.route(chatId))),
            ),
          ],
        ),
      ],
    );
  }
}

/// One number, under what it is.
/// 本局用量: what the current line's replies took, added up.
class _SessionUsageView extends StatelessWidget {
  const _SessionUsageView({required this.usage});

  final TavernSessionUsage usage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary);
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return Padding(
      key: const ValueKey('tavern-session-usage'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Titled as the sections under it are.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Semantics(
              header: true,
              child: Text(l10n.tavernSessionUsage, style: SettingsSection.titleStyle(context)),
            ),
          ),
          if (usage.replies == 0)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(l10n.tavernSessionUsageNone, style: quiet),
            )
          else ...[
            Row(
              children: [
                TavernFigure(
                  label: l10n.tavernStageTokensIn,
                  value: tavernTokenCount(usage.prompt, zh: zh),
                ),
                const SizedBox(width: 8),
                TavernFigure(
                  label: l10n.tavernStageCache,
                  value: usage.prompt == 0 ? '—' : '${(100 * usage.cacheHit / usage.prompt).round()}%',
                ),
                const SizedBox(width: 8),
                TavernFigure(
                  label: l10n.tavernStageTokensOut,
                  value: tavernTokenCount(usage.completion, zh: zh),
                ),
              ],
            ),
            if (usage.replies > usage.unpriced)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 8),
                child: Text(
                  key: const ValueKey('tavern-session-cost'),
                  l10n.tavernSessionUsageCost('US\$${tavernUsd(usage.cost)}'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (usage.unpriced > 0)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 4),
                child: Text(l10n.tavernSessionUsageUnpriced(usage.unpriced), style: quiet),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 6),
              child: Text(l10n.tavernSessionUsageNote(usage.replies), style: quiet),
            ),
          ],
        ],
      ),
    );
  }
}
