// 酒馆's home (docs/design/roleplay-ui.md §1, roleplay-roadmap.md §4), in four
// sections: 书架 (the chats to pick up again, then every character), 对话
// (every chat, newest first), 资源库 (what a story is built with) and 我的
// (酒馆设置). Back returns to 工作; the 模式 key switches elsewhere.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/app_mode_state.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_shelf.dart';
import '../../tavern/tavern_quick_replies.dart';
import '../bots/bot_format.dart' show shortTime;
import '../common/app_sheet.dart';
import '../common/capsule_chip.dart';
import '../common/search_capsule.dart';
import '../features/feature_kit.dart';
import '../modes/mode_switch.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_character_edit_page.dart';
import 'tavern_character_page.dart';
import 'tavern_chat_page.dart';
import 'tavern_deepseek_import.dart';
import 'tavern_drafts_page.dart';
import 'tavern_packs_page.dart';
import 'tavern_group_new_page.dart';
import 'tavern_lorebooks_page.dart';
import 'tavern_personas.dart';
import 'tavern_presets_page.dart';
import 'tavern_regex_page.dart';
import 'tavern_scripts_page.dart';
import 'tavern_quick_replies_page.dart';
import 'tavern_settings_page.dart';
import 'tavern_widgets.dart';

/// The home's four sections.
enum TavernSection { shelf, chats, library, me }

class TavernHomePage extends ConsumerStatefulWidget {
  const TavernHomePage({super.key});

  /// From this many characters on, the home offers search and tag filters.
  @visibleForTesting
  static int searchFrom = 6;

  @override
  ConsumerState<TavernHomePage> createState() => _TavernHomePageState();
}

class _TavernHomePageState extends ConsumerState<TavernHomePage> {
  final _search = TextEditingController();
  String _query = '';

  /// 对话's own search: who, the chat's title, its last line.
  final _chatSearch = TextEditingController();
  String _chatQuery = '';
  String? _tag;
  var _section = TavernSection.shelf;

  /// The characters picked on the shelf; null when not picking.
  Set<String>? _picked;

  void _toggle(String id) => setState(() {
    final picked = {...?_picked};
    picked.contains(id) ? picked.remove(id) : picked.add(id);
    _picked = picked;
  });

  Future<void> _deletePicked(List<TavernCharacter> all) async {
    final picked = [
      for (final c in all)
        if (_picked?.contains(c.id) ?? false) c,
    ];
    if (await deleteTavernCharacters(context, ref, picked) && mounted) setState(() => _picked = null);
  }

  Future<void> _exportPicked(List<TavernCharacter> all) async {
    final picked = [
      for (final c in all)
        if (_picked?.contains(c.id) ?? false) c,
    ];
    if (picked.isNotEmpty) await shareTavernCards(context, ref, picked);
  }

  @override
  void dispose() {
    _search.dispose();
    _chatSearch.dispose();
    super.dispose();
  }

  /// 导入 (a file or a link), then the card's page.
  Future<void> _import() async {
    final navigator = Navigator.of(context);
    final result = await showTavernImport(context, ref);
    if (result == null || !mounted) return;
    unawaited(navigator.push(TavernCharacterPage.route(result.character.id)));
    // A blank card of your own opens for writing, its page under it.
    if (result.blank) unawaited(navigator.push(TavernCharacterEditPage.route(result.character.id)));
  }

  /// 自己写一个角色: a blank card, open for writing.
  Future<void> _writeOwn() async {
    final navigator = Navigator.of(context);
    final character = await createBlankTavernCharacter(context, ref);
    if (character == null || !mounted) return;
    unawaited(navigator.push(TavernCharacterPage.route(character.id)));
    unawaited(navigator.push(TavernCharacterEditPage.route(character.id)));
  }

  /// Imports the sample card and opens it, as an imported card would be.
  Future<void> _trySample() async {
    final navigator = Navigator.of(context);
    final character = await importSampleTavernCard(context, ref);
    if (character != null && mounted) unawaited(navigator.push(TavernCharacterPage.route(character.id)));
  }

  bool _matches(TavernCharacter c) {
    if (_tag != null && !c.tags.contains(_tag)) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [c.name, ?c.nickname, ?c.creator, ...c.tags].any((field) => field.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final characters = ref.watch(tavernCharactersProvider);
    final chats = ref.watch(tavernChatsProvider(null)).value ?? const [];
    final byId = {for (final c in characters.value ?? const <TavernCharacter>[]) c.id: c};
    return AppPage(
      title: l10n.tavernTitle,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-import'),
          icon: AppIcons.add,
          tooltip: l10n.tavernImport,
          onPressed: () => unawaited(_import()),
        ),
        const ModeKey(current: AppMode.tavern, size: 44, tier: GlassTier.chrome),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SegmentedPill<TavernSection>(
              key: const ValueKey('tavern-sections'),
              expand: true,
              segments: [
                PillSegment(TavernSection.shelf, l10n.tavernSectionShelf),
                PillSegment(TavernSection.chats, l10n.tavernSectionChats),
                PillSegment(TavernSection.library, l10n.tavernSectionLibrary),
                PillSegment(TavernSection.me, l10n.tavernSectionMe),
              ],
              selected: _section,
              onChanged: (section) => setState(() => _section = section),
            ),
          ),
        ),
        ...switch (_section) {
          TavernSection.shelf => _shelf(characters, chats, byId),
          TavernSection.chats => _chats(chats, byId),
          TavernSection.library => [_library()],
          // 酒馆设置, right here.
          TavernSection.me => [
            SliverPadding(
              key: const ValueKey('tavern-me'),
              padding: const EdgeInsets.only(bottom: 24),
              sliver: SliverList.list(children: tavernSettingsGroups(context, ref)),
            ),
          ],
        },
      ],
    );
  }

  /// 书架: the chats to pick up again, then every character.
  List<Widget> _shelf(
    AsyncValue<List<TavernCharacter>> characters,
    List<TavernChatSummary> chats,
    Map<String, TavernCharacter> byId,
  ) {
    final l10n = context.l10n;
    final all = characters.value;
    final searchable = (all?.length ?? 0) >= TavernHomePage.searchFrom;
    final filtering = _tag != null || _query.trim().isNotEmpty;
    final shelf = ref.watch(tavernShelfProvider);
    final list = all == null ? null : tavernShelfSort(all.where(_matches).toList(), shelf);
    final tags = _topTags(all ?? const [], keep: _tag);
    return [
      // The engine could not open its folder or database: say so, and let
      // a retry open it afresh rather than spin forever.
      if (list == null && characters.hasError)
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyView(
            key: const ValueKey('tavern-open-failed'),
            icon: AppIcons.error,
            title: l10n.tavernOpenFailed,
            message: l10n.tavernOpenFailedMessage,
            actionLabel: l10n.commonRetry,
            onAction: () => ref.invalidate(tavernProvider),
          ),
        )
      else if (list == null)
        const SliverToBoxAdapter(child: QuietSpinner())
      else if (all!.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyView(
            icon: AppIcons.tavern,
            title: l10n.tavernEmptyTitle,
            message: l10n.tavernEmptyMessage,
            action: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // A conversation DeepSeek's own app won't continue, carried
                // over: what most people arriving at an empty shelf came for.
                OutlinedButton(
                  key: const ValueKey('tavern-empty-deepseek'),
                  onPressed: () => unawaited(takeInDeepSeekExport(context, ref)),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                  ),
                  child: Text(l10n.tavernImportFromDeepSeek),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const ValueKey('tavern-empty-import'),
                  onPressed: () => unawaited(_import()),
                  child: Text(l10n.tavernImport),
                ),
                // A card to start from before you have your own.
                TextButton(
                  key: const ValueKey('tavern-try-sample'),
                  onPressed: () => unawaited(_trySample()),
                  child: Text(l10n.tavernTrySample),
                ),
                TextButton(
                  key: const ValueKey('tavern-write-own'),
                  onPressed: () => unawaited(_writeOwn()),
                  child: Text(l10n.tavernWriteOwn),
                ),
              ],
            ),
          ),
        )
      else ...[
        // Search waits for a full shelf; tags show as soon as one splits it.
        if (searchable || tags.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (searchable)
                    SearchCapsule(
                      key: const ValueKey('tavern-search'),
                      controller: _search,
                      hint: l10n.tavernSearchHint,
                      onChanged: (q) => setState(() => _query = q),
                      onClear: () => setState(() {
                        _search.clear();
                        _query = '';
                      }),
                    ),
                  if (tags.isNotEmpty) ...[
                    if (searchable) const SizedBox(height: 8),
                    SingleChildScrollView(
                      key: const ValueKey('tavern-tags'),
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final tag in [null, ...tags]) ...[
                            CapsuleChoiceChip(
                              label: tag ?? l10n.tavernAllTags,
                              selected: _tag == tag,
                              onSelected: () => setState(() => _tag = tag),
                            ),
                            const SizedBox(width: 8),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (chats.isNotEmpty && !filtering) ...[
          _SectionLabel(l10n.tavernContinue),
          SliverToBoxAdapter(
            child: SizedBox(
              // The card's text grows with the system's; its padding doesn't.
              height: MediaQuery.textScalerOf(context).scale(108) + 24,
              child: ListView.separated(
                key: const ValueKey('tavern-continue'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: chats.length.clamp(0, 8),
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, i) => _ContinueCard(chat: chats[i], character: byId[chats[i].characterId]),
              ),
            ),
          ),
        ],
        _ShelfLabel(
          order: shelf.order,
          picked: _picked?.length,
          onPick: () => setState(() => _picked = {}),
          onDone: () => setState(() => _picked = null),
          onExport: () => unawaited(_exportPicked(all)),
          onDelete: () => unawaited(_deletePicked(all)),
        ),
        if (list.isEmpty)
          SliverToBoxAdapter(
            child: EmptyView(icon: AppIcons.noResults, title: l10n.tavernNoMatch, compact: true),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.62,
            ),
            itemCount: list.length,
            itemBuilder: (context, i) => _CharacterTile(
              character: list[i],
              picked: _picked?.contains(list[i].id),
              onPick: () => _toggle(list[i].id),
            ),
          ),
        ),
      ],
    ];
  }

  /// 对话: every chat, the newest first.
  List<Widget> _chats(List<TavernChatSummary> chats, Map<String, TavernCharacter> byId) {
    final l10n = context.l10n;
    // 新建群聊: two characters or more on the shelf.
    final newGroup = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const ValueKey('tavern-group-new'),
            icon: const Icon(AppIcons.newGroupChat, size: 18),
            label: Text(l10n.tavernGroupNew),
            onPressed: byId.length < 2 ? null : () => unawaited(Navigator.of(context).push(TavernGroupNewPage.route())),
          ),
        ),
      ),
    );
    if (chats.isEmpty) {
      return [
        newGroup,
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyView(
            key: const ValueKey('tavern-no-chats'),
            icon: AppIcons.tavern,
            title: l10n.tavernNoChats,
            message: l10n.tavernNoChatsMessage,
          ),
        ),
      ];
    }
    final q = _chatQuery.trim().toLowerCase();
    final shown = q.isEmpty
        ? chats
        : [
            for (final chat in chats)
              if ([
                ?byId[chat.characterId]?.name,
                chat.title,
                plainPreview(chat.lastText ?? ''),
              ].any((field) => field.toLowerCase().contains(q)))
                chat,
          ];
    return [
      newGroup,
      if (chats.length >= TavernHomePage.searchFrom)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SearchCapsule(
              key: const ValueKey('tavern-chat-search'),
              controller: _chatSearch,
              hint: l10n.tavernChatSearchHint,
              onChanged: (q) => setState(() => _chatQuery = q),
              onClear: () => setState(() {
                _chatSearch.clear();
                _chatQuery = '';
              }),
            ),
          ),
        ),
      if (shown.isEmpty)
        SliverToBoxAdapter(
          child: EmptyView(
            key: const ValueKey('tavern-chats-no-match'),
            icon: AppIcons.noResults,
            title: l10n.tavernNoChatMatch,
            compact: true,
          ),
        ),
      SliverPadding(
        key: const ValueKey('tavern-chats'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        sliver: SliverList.separated(
          itemCount: shown.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, i) => _ChatRow(chat: shown[i], character: byId[shown[i].characterId]),
        ),
      ),
    ];
  }

  /// 资源库: what stories are built with: presets, lorebooks, regex scripts,
  /// personas and quick replies (roleplay-roadmap.md §4).
  Widget _library() {
    final l10n = context.l10n;
    final persona = ref.watch(tavernPersonaSelectionProvider(null)).value?.persona;
    return SliverToBoxAdapter(
      child: SheetGroup(
        key: const ValueKey('tavern-library'),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          SettingsTile(
            key: const ValueKey('tavern-library-presets'),
            icon: AppIcons.article,
            title: l10n.tavernPresets,
            value: Text(switch (ref.watch(tavernPresetsProvider).value?.length ?? 0) {
              0 => l10n.tavernPersonaNotSet,
              final n => l10n.tavernPresetCount(n),
            }),
            onTap: () => unawaited(Navigator.of(context).push(TavernPresetsPage.route())),
          ),
          SettingsTile(
            key: const ValueKey('tavern-library-lorebooks'),
            icon: AppIcons.lorebook,
            title: l10n.tavernLorebooks,
            value: Text(switch (ref.watch(tavernLorebooksProvider).value?.books.length ?? 0) {
              0 => l10n.tavernPersonaNotSet,
              final n => l10n.tavernLorebookCount(n),
            }),
            onTap: () => unawaited(Navigator.of(context).push(TavernLorebooksPage.route())),
          ),
          SettingsTile(
            key: const ValueKey('tavern-library-regex'),
            icon: AppIcons.code,
            title: l10n.tavernRegex,
            value: Text(switch (ref.watch(tavernRegexProvider).value?.length ?? 0) {
              0 => l10n.tavernPersonaNotSet,
              final n => l10n.tavernRegexCount(n),
            }),
            onTap: () => unawaited(Navigator.of(context).push(TavernRegexPage.route())),
          ),
          SettingsTile(
            key: const ValueKey('tavern-library-scripts'),
            icon: AppIcons.code,
            title: l10n.tavernScripts,
            value: Text(switch (tavernScriptCount(ref.watch(tavernGlobalScriptsProvider).value ?? const [])) {
              0 => l10n.tavernPersonaNotSet,
              final n => l10n.tavernScriptCount(n),
            }),
            onTap: () => unawaited(Navigator.of(context).push(TavernScriptsPage.route())),
          ),
          SettingsTile(
            key: const ValueKey('tavern-library-personas'),
            icon: AppIcons.profile,
            title: l10n.tavernDefaultPersona,
            value: Text(persona?.name ?? l10n.tavernPersonaNotSet),
            onTap: () => unawaited(Navigator.of(context).push(TavernPersonasPage.route())),
          ),
          SettingsTile(
            key: const ValueKey('tavern-library-quick-replies'),
            icon: AppIcons.reply,
            title: l10n.tavernQuickReplies,
            value: Text(switch (ref.watch(tavernQuickRepliesProvider).length) {
              0 => l10n.tavernPersonaNotSet,
              final n => l10n.tavernQuickReplyCount(n),
            }),
            onTap: () => unawaited(Navigator.of(context).push(TavernQuickRepliesPage.route())),
          ),
          SettingsTile(
            key: const ValueKey('tavern-library-drafts'),
            icon: AppIcons.askAi,
            title: l10n.tavernDrafts,
            onTap: () => unawaited(Navigator.of(context).push(TavernDraftsPage.route())),
          ),
          SettingsTile(
            key: const ValueKey('tavern-library-packs'),
            icon: AppIcons.zip,
            title: l10n.tavernPacks,
            onTap: () => unawaited(Navigator.of(context).push(TavernPacksPage.route())),
          ),
        ],
      ),
    );
  }
}

/// A chat in 对话: who, when, how long, and the last line on its path.
class _ChatRow extends ConsumerWidget {
  const _ChatRow({required this.chat, required this.character});

  final TavernChatSummary chat;
  final TavernCharacter? character;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final group = chat.kind == TavernChatKind.group;
    final name = group ? chat.title : character?.name ?? chat.title;
    return GlassSurface(
      key: ValueKey('tavern-chat-row-${chat.id}'),
      tier: GlassTier.card,
      borderRadius: AppShape.radiusLg,
      padding: const EdgeInsets.all(12),
      onTap: () => Navigator.of(context).push(TavernChatPage.route(chat.id)),
      onLongPress: () => unawaited(
        showTavernActions(context, [
          (AppIcons.delete, context.l10n.tavernDeleteChat, () => deleteTavernChat(context, ref, chat.id)),
        ]),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: TavernPortrait(name: name, path: character?.avatarPath, radius: AppShape.md, initialSize: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (group) ...[
                      Icon(
                        AppIcons.groupChat,
                        key: ValueKey('tavern-chat-group-${chat.id}'),
                        size: 14,
                        color: dsh.textTertiary,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      [
                        if (group) context.l10n.tavernGroupMemberCount(chat.memberCharacterIds.length),
                        context.l10n.tavernMessageCount(chat.messageCount),
                        shortTime(chat.updatedAt),
                      ].join(' · '),
                      style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: dsh.textTertiary)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  plainPreviewLines(chat.lastText ?? '', 2),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(color: DshColors.of(context).textTertiary),
      ),
    ),
  );
}

/// 角色, and how they are ordered: a tap picks another order.
class _ShelfLabel extends ConsumerWidget {
  const _ShelfLabel({
    required this.order,
    required this.picked,
    required this.onPick,
    required this.onDone,
    required this.onExport,
    required this.onDelete,
  });

  final TavernShelfOrder order;

  /// How many are picked; null when not picking.
  final int? picked;
  final VoidCallback onPick;
  final VoidCallback onDone;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    String name(TavernShelfOrder o) => switch (o) {
      TavernShelfOrder.recent => l10n.tavernShelfOrderRecent,
      TavernShelfOrder.name => l10n.tavernShelfOrderName,
      TavernShelfOrder.imported => l10n.tavernShelfOrderImported,
    };
    final shelf = ref.read(tavernShelfProvider.notifier);
    final label = theme.textTheme.labelMedium?.copyWith(color: dsh.textTertiary);
    final picked = this.picked;
    // Picking: how many, and what to do with them.
    if (picked != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.tavernShelfPicked(picked),
                  key: const ValueKey('tavern-shelf-picked'),
                  style: theme.textTheme.titleSmall?.copyWith(color: dsh.textTertiary),
                ),
              ),
              IconButton(
                key: const ValueKey('tavern-shelf-export'),
                tooltip: l10n.tavernShelfExport,
                icon: const Icon(AppIcons.share, size: 20),
                onPressed: picked == 0 ? null : onExport,
              ),
              IconButton(
                key: const ValueKey('tavern-shelf-delete'),
                tooltip: l10n.commonDelete,
                icon: Icon(AppIcons.delete, size: 20, color: picked == 0 ? null : dsh.danger),
                onPressed: picked == 0 ? null : onDelete,
              ),
              TextButton(
                key: const ValueKey('tavern-shelf-done'),
                onPressed: onDone,
                child: Text(l10n.commonCancel, style: label),
              ),
            ],
          ),
        ),
      );
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 8, 2),
        child: Row(
          children: [
            Expanded(
              child: Text(l10n.tavernCharacters, style: theme.textTheme.titleSmall?.copyWith(color: dsh.textTertiary)),
            ),
            TextButton(
              key: const ValueKey('tavern-shelf-select'),
              onPressed: onPick,
              child: Text(l10n.tavernShelfSelect, style: label),
            ),
            TextButton.icon(
              key: const ValueKey('tavern-shelf-sort'),
              onPressed: () => unawaited(
                showTavernActions(context, [
                  for (final o in TavernShelfOrder.values)
                    (o == order ? AppIcons.radioOn : AppIcons.radioOff, name(o), () => unawaited(shelf.setOrder(o))),
                ]),
              ),
              iconAlignment: IconAlignment.end,
              icon: Icon(AppIcons.dropdown, size: 16, color: dsh.textTertiary),
              label: Text(
                name(order),
                semanticsLabel: '${l10n.tavernShelfSort}：${name(order)}',
                style: theme.textTheme.labelMedium?.copyWith(color: dsh.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A card in the grid: the picture at 2:3, the name, the tags.
class _CharacterTile extends ConsumerWidget {
  const _CharacterTile({required this.character, this.picked, this.onPick});

  final TavernCharacter character;

  /// Picking: whether this one is picked; null when not picking.
  final bool? picked;
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final l10n = context.l10n;
    final favorite = ref.watch(tavernShelfProvider.select((s) => s.favorites.contains(character.id)));
    return Semantics(
      button: true,
      selected: picked,
      label: favorite ? '${character.name}，${l10n.tavernFavorited}' : character.name,
      child: GestureDetector(
        key: ValueKey('tavern-character-${character.id}'),
        onTap: picked != null ? onPick : () => Navigator.of(context).push(TavernCharacterPage.route(character.id)),
        onLongPress: picked != null
            ? null
            : () => unawaited(
                showTavernActions(context, [
                  (
                    favorite ? AppIcons.favoriteActive : AppIcons.favorite,
                    favorite ? l10n.tavernUnfavorite : l10n.tavernFavorite,
                    () => unawaited(ref.read(tavernShelfProvider.notifier).setFavorite(character.id, !favorite)),
                  ),
                  (
                    AppIcons.edit,
                    context.l10n.commonEdit,
                    () => unawaited(Navigator.of(context).push(TavernCharacterEditPage.route(character.id))),
                  ),
                  (
                    AppIcons.delete,
                    context.l10n.tavernDeleteCharacter,
                    () => deleteTavernCharacter(context, ref, character),
                  ),
                ]),
              ),
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  TavernPortrait(name: character.name, path: character.avatarPath),
                  if (picked case final picked?)
                    Positioned(
                      key: ValueKey('tavern-pick-${character.id}'),
                      top: 6,
                      left: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: picked ? theme.colorScheme.primary : Colors.black.withValues(alpha: 0.32),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: Icon(AppIcons.done, size: 14, color: picked ? Colors.white : Colors.transparent),
                        ),
                      ),
                    ),
                  if (favorite)
                    Positioned(
                      key: ValueKey('tavern-favorite-${character.id}'),
                      top: 6,
                      right: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.32), shape: BoxShape.circle),
                        child: const Padding(
                          padding: EdgeInsets.all(5),
                          child: Icon(AppIcons.favoriteActive, size: 14, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(character.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
            Text(
              character.tags.isEmpty ? (character.creator ?? '') : character.tags.take(3).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// A chat to pick up again: who, and the last line on its path.
class _ContinueCard extends ConsumerWidget {
  const _ContinueCard({required this.chat, required this.character});

  final TavernChatSummary chat;
  final TavernCharacter? character;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final name = chat.kind == TavernChatKind.group ? chat.title : character?.name ?? chat.title;
    return SizedBox(
      width: 236,
      child: GlassSurface(
        key: ValueKey('tavern-continue-${chat.id}'),
        tier: GlassTier.card,
        borderRadius: AppShape.radiusLg,
        padding: const EdgeInsets.all(12),
        onTap: () => Navigator.of(context).push(TavernChatPage.route(chat.id)),
        onLongPress: () => unawaited(
          showTavernActions(context, [
            (AppIcons.delete, context.l10n.tavernDeleteChat, () => deleteTavernChat(context, ref, chat.id)),
          ]),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              height: 84,
              child: TavernPortrait(name: name, path: character?.avatarPath, radius: AppShape.md, initialSize: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        shortTime(chat.updatedAt),
                        style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: dsh.textTertiary)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    plainPreviewLines(chat.lastText ?? '', 4),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.4),
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

/// A message as one quiet line: Markdown emphasis and tags dropped, runs of
/// white space folded.
String plainPreview(String text) =>
    text.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'[*_`#>]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// [plainPreview] for a text of at most [lines] lines, cut to more than any
/// of its lines could hold: a text is laid out whole however few lines it
/// shows (a 4,000-character reply in two lines takes 13 times what 300
/// characters do).
String plainPreviewLines(String text, int lines) {
  final plain = plainPreview(text);
  var end = lines * 300;
  if (plain.length <= end) return plain;
  // Not between the halves of a surrogate pair.
  if (plain.codeUnitAt(end - 1) & 0xFC00 == 0xD800) end--;
  return plain.substring(0, end);
}

/// The most used tags, most used first.
/// The shelf's most used tags, leaving out any every character has: picking
/// it would narrow nothing. [keep], the tag picked now, stays so it can be
/// let go.
List<String> _topTags(List<TavernCharacter> characters, {int limit = 8, String? keep}) {
  final counts = <String, int>{};
  for (final c in characters) {
    for (final tag in c.tags.toSet()) {
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
  }
  final tags = counts.keys.where((t) => counts[t]! < characters.length).toList()
    ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  final top = tags.take(limit).toList();
  if (keep != null && !top.contains(keep)) top.add(keep);
  return top;
}
