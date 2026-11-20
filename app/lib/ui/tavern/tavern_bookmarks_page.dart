// 舞台 › 本局 › 书签: the lines of this chat you marked (a message's menu,
// 加书签). One goes back to its place in the story: its branch becomes the
// current one and the chat scrolls there.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_bookmarks.dart';
import '../../tavern/tavern_jump.dart';
import '../../tavern/tavern_provider.dart';
import '../bots/bot_format.dart' show shortTime;
import '../common/brief_notice.dart';
import '../features/feature_kit.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';

class TavernBookmarksPage extends ConsumerWidget {
  const TavernBookmarksPage({super.key, required this.chatId});

  final String chatId;

  static Route<void> route(String chatId) =>
      MaterialPageRoute<void>(builder: (_) => TavernBookmarksPage(chatId: chatId));

  /// To [mark] in the story; a line no longer there loses its mark.
  Future<void> _go(BuildContext context, TavernBookmark mark) async {
    final l10n = context.l10n;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final page = Navigator.of(context);
    try {
      await container.read(tavernProvider).selectSibling(chatId, mark.nodeId, mark.siblingIndex);
    } on Object {
      messenger?.showBriefNotice(l10n.tavernBookmarkGone);
      await container.read(tavernBookmarksProvider(chatId).notifier).remove(mark.nodeId);
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    container.read(tavernJumpProvider(chatId).notifier).go(mark.nodeId);
    if (page.mounted) page.pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final marks = ref.watch(tavernBookmarksProvider(chatId));
    return AppPage.list(
      title: l10n.tavernBookmarks,
      children: [
        if (marks.isEmpty)
          Padding(
            key: const ValueKey('tavern-bookmarks-empty'),
            padding: const EdgeInsets.only(top: 32),
            child: EmptyView(
              icon: AppIcons.bookmark,
              title: l10n.tavernBookmarksEmpty,
              message: l10n.tavernBookmarksEmptyMessage,
              compact: true,
            ),
          )
        else
          SettingsSection(
            children: [
              for (final mark in marks)
                SettingsTile(
                  key: ValueKey('tavern-bookmark-${mark.nodeId}'),
                  title: mark.preview.isEmpty ? '…' : mark.preview,
                  subtitle: '${mark.speaker} · ${shortTime(mark.at)}',
                  chevron: false,
                  value: IconButton(
                    key: ValueKey('tavern-bookmark-remove-${mark.nodeId}'),
                    tooltip: l10n.tavernBookmarkRemove,
                    icon: const Icon(AppIcons.remove, size: 18),
                    onPressed: () => unawaited(ref.read(tavernBookmarksProvider(chatId).notifier).remove(mark.nodeId)),
                  ),
                  onTap: () => unawaited(_go(context, mark)),
                ),
            ],
          ),
      ],
    );
  }
}
