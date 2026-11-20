// A character (docs/design/roleplay-ui.md §1): the picture and the chat to
// pick up again on top; under it three tabs (docs/design/roleplay-roadmap.md
// P1): 对话 (the greetings to start from, the chats so far), 设定 (what the
// card says about itself) and 配置 (its lorebooks, Live2D, import report).

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_settings.dart';
import '../bots/bot_format.dart' show shortTime;
import '../chat/render/markdown_body.dart';
import '../common/app_sheet.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_character_edit_page.dart';
import 'tavern_chat_files.dart';
import 'tavern_chat_page.dart';
import 'tavern_drafts_page.dart';
import 'tavern_pack_bindings_page.dart';
import 'tavern_pack_export_page.dart';
import 'tavern_home_page.dart' show plainPreviewLines;
import 'tavern_live2d_tile.dart';
import 'tavern_lorebooks_page.dart';
import 'tavern_report_page.dart';
import 'tavern_lorebook_page.dart';
import 'tavern_widgets.dart';

class TavernCharacterPage extends ConsumerStatefulWidget {
  const TavernCharacterPage({super.key, required this.characterId});

  final String characterId;

  static Route<void> route(String characterId) =>
      MaterialPageRoute<void>(builder: (_) => TavernCharacterPage(characterId: characterId));

  @override
  ConsumerState<TavernCharacterPage> createState() => _TavernCharacterPageState();
}

/// The character page's tabs.
enum TavernCharacterTab { chats, card, setup }

class _TavernCharacterPageState extends ConsumerState<TavernCharacterPage> {
  final _greetings = PageController(viewportFraction: 0.9);
  int _greeting = 0;
  bool _starting = false;
  var _tab = TavernCharacterTab.chats;

  @override
  void dispose() {
    _greetings.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    final navigator = Navigator.of(context);
    try {
      final id = await ref.read(tavernProvider).createChat(widget.characterId, greeting: _greeting);
      if (mounted) unawaited(navigator.push(TavernChatPage.route(id)));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _delete(TavernCharacter character) async {
    final navigator = Navigator.of(context);
    if (await deleteTavernCharacter(context, ref, character) && mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final characters = ref.watch(tavernCharactersProvider).value;
    final character = characters?.where((c) => c.id == widget.characterId).firstOrNull;
    if (characters == null) return AppPage.list(title: l10n.tavernTitle, children: const [QuietSpinner()]);
    if (character == null) {
      return AppPage.list(
        title: l10n.tavernTitle,
        children: [EmptyView(icon: AppIcons.tavern, title: l10n.tavernCharacterGone)],
      );
    }
    final chats = ref.watch(tavernChatsProvider(character.id)).value ?? const <TavernChatSummary>[];
    // Newest first: the one to pick up again.
    final last = chats.firstOrNull;
    // The list leaves the long fields out; until the details arrive, the page
    // shows what the list has.
    final full = ref.watch(tavernCharacterDetailProvider(character.id)).value ?? character;
    final greetings = full.greetings.isEmpty ? const [''] : full.greetings;
    return AppPage(
      title: character.name,
      showLargeTitle: false,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-character-edit'),
          icon: AppIcons.edit,
          tooltip: l10n.commonEdit,
          onPressed: () => unawaited(Navigator.of(context).push(TavernCharacterEditPage.route(character.id))),
        ),
        GlassIconButton(
          key: const ValueKey('tavern-character-more'),
          icon: AppIcons.more,
          tooltip: l10n.commonMore,
          onPressed: () => unawaited(_showMore(character)),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Column(
              children: [
                SizedBox(
                  width: 168,
                  height: 252,
                  child: TavernPortrait(name: character.name, path: character.avatarPath, initialSize: 64),
                ),
                const SizedBox(height: 16),
                Text(character.name, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                if (character.creator != null || character.tags.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    [?character.creator, ...character.tags.take(4)].join(' · '),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                  ),
                ],
                // Back again: the last chat first, on the first screen; a new
                // one is further down, from a greeting.
                if (last != null) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('tavern-continue-last'),
                    onPressed: () => Navigator.of(context).push(TavernChatPage.route(last.id)),
                    child: Text(l10n.tavernContinueLast),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      shortTime(last.updatedAt),
                      plainPreviewLines(last.lastText ?? '', 1),
                    ].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(color: dsh.textTertiary),
                  ),
                ],
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SegmentedPill<TavernCharacterTab>(
              key: const ValueKey('tavern-character-tabs'),
              expand: true,
              segments: [
                PillSegment(TavernCharacterTab.chats, l10n.tavernCharacterTabChats),
                PillSegment(TavernCharacterTab.card, l10n.tavernCharacterTabCard),
                PillSegment(TavernCharacterTab.setup, l10n.tavernCharacterTabSetup),
              ],
              selected: _tab,
              onChanged: (tab) => setState(() => _tab = tab),
            ),
          ),
        ),
        if (_tab == TavernCharacterTab.chats)
          SliverToBoxAdapter(
            child: Column(
              children: [
                SizedBox(
                  height: 168,
                  child: PageView.builder(
                    key: const ValueKey('tavern-greetings'),
                    controller: _greetings,
                    itemCount: greetings.length,
                    onPageChanged: (i) => setState(() => _greeting = i),
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: GlassSurface(
                        tier: GlassTier.card,
                        borderRadius: AppShape.radiusLg,
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                        child: Text(
                          plainPreviewLines(greetings[i], 6),
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  greetings.length > 1 ? l10n.tavernGreetingOf(_greeting + 1, greetings.length) : l10n.tavernGreeting,
                  style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: dsh.textTertiary)),
                ),
                const SizedBox(height: 16),
                if (last == null)
                  FilledButton(
                    key: const ValueKey('tavern-start'),
                    onPressed: _starting ? null : _start,
                    child: Text(l10n.tavernStart),
                  )
                else
                  OutlinedButton(
                    key: const ValueKey('tavern-start'),
                    onPressed: _starting ? null : _start,
                    child: Text(l10n.tavernStartNew),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        if (_tab == TavernCharacterTab.chats && chats.isNotEmpty)
          SliverToBoxAdapter(
            child: SheetGroup(
              title: l10n.tavernChats,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                for (final chat in chats)
                  GestureDetector(
                    onLongPress: () => unawaited(
                      showTavernActions(context, [
                        (
                          AppIcons.share,
                          l10n.tavernExportChat,
                          () => unawaited(exportTavernChat(context, ref, chat.id, title: _chatTitle(character, chat))),
                        ),
                        (AppIcons.delete, l10n.tavernDeleteChat, () => deleteTavernChat(context, ref, chat.id)),
                      ]),
                    ),
                    child: SettingsTile(
                      key: ValueKey('tavern-chat-${chat.id}'),
                      icon: AppIcons.chat,
                      tinted: false,
                      title: plainPreviewLines(chat.lastText ?? chat.title, 2),
                      titleMaxLines: 2,
                      subtitle: '${l10n.tavernMessageCount(chat.messageCount)} · ${shortTime(chat.updatedAt)}',
                      onTap: () => Navigator.of(context).push(TavernChatPage.route(chat.id)),
                    ),
                  ),
              ],
            ),
          ),
        if (_tab == TavernCharacterTab.setup)
          SliverToBoxAdapter(
            child: SheetGroup(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                // Every card: one without a book starts one here (engine T16).
                SettingsTile(
                  key: const ValueKey('tavern-lorebook'),
                  icon: AppIcons.lorebook,
                  tinted: false,
                  title: l10n.tavernLorebook,
                  subtitle: l10n.tavernLorebookSubtitle,
                  onTap: () => Navigator.of(context).push(TavernLorebookPage.route(character.id)),
                ),
                TavernLorebookBindingTile(
                  key: const ValueKey('tavern-character-lorebooks'),
                  scope: (source: WorldInfoSource.character, id: character.id),
                  title: l10n.tavernLorebooksBound,
                  subtitle: l10n.tavernLorebooksBoundCharacter,
                  sheetTitle: l10n.tavernLorebookForCharacter(character.name),
                  note: l10n.tavernLorebookCharacterNote,
                ),
                TavernLive2dTile(character: character),
                // A copy to change with the AI, applied when chosen.
                SettingsTile(
                  key: const ValueKey('tavern-character-drafts'),
                  icon: AppIcons.askAi,
                  tinted: false,
                  title: l10n.tavernDraftsForCard,
                  subtitle: l10n.tavernDraftsForCardSubtitle,
                  onTap: () => Navigator.of(context).push(TavernDraftsPage.route(characterId: character.id)),
                ),
                // The 玩法包 every chat of this card uses.
                SettingsTile(
                  key: const ValueKey('tavern-character-packs'),
                  icon: AppIcons.zip,
                  tinted: false,
                  title: l10n.tavernPacks,
                  subtitle: l10n.tavernPackForCardSubtitle,
                  onTap: () => Navigator.of(context).push(
                    TavernPackBindingsPage.route((
                      kind: TavernGameplayScope.character,
                      targetId: character.id,
                    ), characterId: character.id),
                  ),
                ),
                // How its chats show the card: its own, or as 酒馆设置 say.
                ...switch (ref.watch(tavernCharacterRenderProvider(character.id))) {
                  final own => [
                    SettingsSegmentTile<TavernRender>(
                      key: const ValueKey('tavern-character-render'),
                      title: l10n.tavernRender,
                      subtitle: l10n.tavernRenderSubtitle,
                      tinted: false,
                      segments: [
                        PillSegment(TavernRender.text, l10n.tavernRenderText),
                        PillSegment(TavernRender.islands, l10n.tavernRenderIslands),
                        PillSegment(TavernRender.canvas, l10n.tavernRenderCanvas),
                      ],
                      selected: own ?? tavernRenderOf(ref.watch(tavernSettingsProvider)),
                      onChanged: (r) =>
                          unawaited(ref.read(tavernCharacterRenderProvider(character.id).notifier).set(r)),
                    ),
                    if (own != null)
                      SettingsTile(
                        key: const ValueKey('tavern-character-render-follow'),
                        icon: AppIcons.restart,
                        tinted: false,
                        title: l10n.tavernFollowSettings,
                        onTap: () =>
                            unawaited(ref.read(tavernCharacterRenderProvider(character.id).notifier).set(null)),
                      ),
                  ],
                },
                // What of the card runs here, and what is kept but not run.
                SettingsTile(
                  key: const ValueKey('tavern-character-report'),
                  icon: AppIcons.info,
                  tinted: false,
                  title: l10n.tavernReport,
                  value: Text(switch (ref
                      .watch(tavernImportReportProvider((TavernImportKind.character, character.id)))
                      .value) {
                    final report? => tavernVerdictText(l10n, report.verdict),
                    null => '',
                  }),
                  onTap: () => Navigator.of(context).push(
                    TavernImportReportPage.route(
                      kind: TavernImportKind.character,
                      assetId: character.id,
                      name: character.name,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_tab == TavernCharacterTab.card)
          SliverToBoxAdapter(
            child: Padding(
              key: const ValueKey('tavern-character-card'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (full.creatorNotes.isNotEmpty) _Section(title: l10n.tavernCreatorNotes, text: full.creatorNotes),
                  if (full.description.isNotEmpty) _Section(title: l10n.tavernDefinition, text: full.description),
                  if (full.creatorNotes.isEmpty && full.description.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Text(
                        l10n.tavernCharacterNoDefinition,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _showMore(TavernCharacter character) => showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: SheetGroup(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          children: [
            SettingsTile(
              key: const ValueKey('tavern-export-png'),
              icon: AppIcons.share,
              tinted: false,
              title: context.l10n.tavernExportPng,
              subtitle: context.l10n.tavernExportPngSubtitle,
              chevron: false,
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(shareTavernCard(context, ref, character, TavernCardFormat.png));
              },
            ),
            SettingsTile(
              key: const ValueKey('tavern-export-json'),
              icon: AppIcons.shareFile,
              tinted: false,
              title: context.l10n.tavernExportJson,
              chevron: false,
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(shareTavernCard(context, ref, character, TavernCardFormat.json));
              },
            ),
            SettingsTile(
              key: const ValueKey('tavern-export-packs'),
              icon: AppIcons.zip,
              tinted: false,
              title: context.l10n.tavernPackCardExport,
              chevron: false,
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(Navigator.of(context).push(TavernPackCardExportPage.route(character)));
              },
            ),
            SettingsTile(
              key: const ValueKey('tavern-import-chats'),
              icon: AppIcons.download,
              tinted: false,
              title: context.l10n.tavernImportChats,
              subtitle: context.l10n.tavernImportChatsSubtitle,
              chevron: false,
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(importTavernChats(context, ref, character.id));
              },
            ),
            SettingsTile(
              icon: AppIcons.delete,
              danger: true,
              tinted: false,
              chevron: false,
              title: context.l10n.tavernDeleteCharacter,
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(_delete(character));
              },
            ),
          ],
        ),
      ),
    ),
  );
}

/// 「林晚 2026-11-10 0530」: a chat's export name, its character and when.
String _chatTitle(TavernCharacter character, TavernChatSummary chat) {
  final t = chat.updatedAt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${character.name} ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}${two(t.minute)}';
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(title, style: theme.textTheme.titleSmall?.copyWith(color: DshColors.of(context).textTertiary)),
          ),
          GlassSurface(
            tier: GlassTier.card,
            borderRadius: AppShape.radiusLg,
            padding: const EdgeInsets.all(16),
            child: MarkdownBody(text: text),
          ),
        ],
      ),
    );
  }
}
