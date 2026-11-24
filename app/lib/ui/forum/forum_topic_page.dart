// One forum topic (a detail page) — the title as the page hero, then the posts,
// more as you scroll; likes, bookmarks, replies.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../forum/discourse_client.dart';
import '../../forum/forum_auth.dart';
import '../../forum/forum_models.dart';
import '../../forum/forum_state.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/fade_in.dart';
import '../common/list_page_row.dart';
import '../common/page_hero.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'forum_account_sheet.dart';
import 'forum_composer_sheet.dart';
import 'forum_post_body.dart';
import 'forum_widgets.dart';
import '../common/brief_notice.dart';

class ForumTopicPage extends ConsumerStatefulWidget {
  const ForumTopicPage({super.key, required this.topicId, this.title, this.postNumber});

  final int topicId;

  /// Shown until the topic loads (from the list row).
  final String? title;

  /// Scroll to this post once it is loaded (from a notification).
  final int? postNumber;

  static Route<void> route({required int topicId, String? title, int? postNumber}) => MaterialPageRoute(
    builder: (_) => ForumTopicPage(topicId: topicId, title: title, postNumber: postNumber),
  );

  @override
  ConsumerState<ForumTopicPage> createState() => _ForumTopicPageState();
}

class _ForumTopicPageState extends ConsumerState<ForumTopicPage> {
  final _keys = <int, GlobalKey>{};
  final _veil = ValueNotifier<double>(0);
  bool _jumped = false;
  bool _loadingMore = false;
  String? _moreError;

  @override
  void dispose() {
    _veil.dispose();
    super.dispose();
  }

  ForumTopicController get _controller => ref.read(forumTopicProvider(widget.topicId).notifier);

  GlobalKey _keyFor(int postNumber) => _keys.putIfAbsent(postNumber, GlobalKey.new);

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      await _controller.loadMore();
    } on ForumException catch (e) {
      if (mounted) setState(() => _moreError = e.message);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// Loads chunks until [widget.postNumber] is in, then scrolls to it.
  Future<void> _jump(ForumTopicDetail detail) async {
    final target = widget.postNumber;
    if (_jumped || target == null || target <= 1) return;
    _jumped = true;
    var current = detail;
    for (var i = 0; i < 8 && !current.posts.any((p) => p.postNumber >= target) && current.hasMore; i++) {
      try {
        await _controller.loadMore();
      } catch (_) {
        break;
      }
      final next = ref.read(forumTopicProvider(widget.topicId)).value;
      if (next == null || !mounted) return;
      current = next;
    }
    final post = current.posts.where((p) => p.postNumber >= target).firstOrNull;
    if (post == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[post.postNumber]?.currentContext;
      if (ctx != null && ctx.mounted) {
        unawaited(Scrollable.ensureVisible(ctx, alignment: 0.1, duration: AppMotion.of(context, AppMotion.standard)));
      }
    });
  }

  bool _signedInOrAsk() {
    if (ref.read(forumAuthProvider).signedIn) return true;
    unawaited(showForumAccountSheet(context));
    return false;
  }

  Future<void> _reply(ForumTopicDetail detail, {ForumPost? to}) async {
    if (!_signedInOrAsk()) return;
    final result = await showForumComposer(
      context,
      ForumReplyTarget(topicId: detail.id, topicTitle: detail.title, replyTo: to),
    );
    if (result == null || !mounted) return;
    if (result.queued) {
      _toast(context.l10n.remoteForumPendingApproval);
    } else if (result.post case final post?) {
      _controller.addPost(post);
    }
  }

  Future<void> _like(ForumPost post) async {
    if (!_signedInOrAsk()) return;
    try {
      await _controller.toggleLike(post);
    } on ForumException catch (e) {
      if (mounted) _toast(e.message);
    }
  }

  Future<void> _bookmark(ForumPost post) async {
    if (!_signedInOrAsk()) return;
    try {
      await _controller.toggleBookmark(post);
      if (mounted) {
        showBriefNotice(
          context,
          post.bookmarked ? context.l10n.remoteForumBookmarkRemoved : context.l10n.remoteForumBookmarkAdded,
        );
      }
    } on ForumException catch (e) {
      if (mounted) _toast(e.message);
    }
  }

  Uri _urlOf(ForumTopicDetail detail, [ForumPost? post]) => forumTopicUrl(
    ref.read(forumApiProvider).baseUrl,
    topicId: detail.id,
    slug: detail.slug,
    postNumber: post?.postNumber,
  );

  Future<void> _more(ForumTopicDetail detail, [ForumPost? post]) => showAppSheet<void>(
    context,
    builder: (sheet) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(post == null ? context.l10n.remoteForumTopic : '#${post.postNumber}'),
          SheetGroup(
            children: [
              ListPageRow(
                icon: AppIcons.link,
                title: context.l10n.commonCopyLink,
                chevron: false,
                onTap: () {
                  unawaited(Clipboard.setData(ClipboardData(text: _urlOf(detail, post).toString())));
                  Navigator.of(sheet).pop();
                  showBriefNotice(context, context.l10n.remoteLinkCopied);
                },
              ),
              ListPageRow(
                icon: AppIcons.openExternal,
                title: context.l10n.commonOpenInWeb,
                chevron: false,
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(openForumLink(_urlOf(detail, post)));
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(forumTopicProvider(widget.topicId));
    final detail = async.value;
    final hasMore = detail?.hasMore ?? false;
    final site = ref.watch(forumSiteProvider).value;
    final signedIn = ref.watch(forumAuthProvider.select((s) => s.signedIn));
    ref.listen(forumTopicProvider(widget.topicId), (_, next) {
      if (next.value case final d?) unawaited(_jump(d));
    });
    final title = detail?.title ?? widget.title ?? l10n.remoteForumTopic;
    final category = site?.category(detail?.categoryId);
    final colors = DshColors.of(context);
    final meta = Theme.of(context).textTheme.bodyMedium!.copyWith(color: colors.textTertiary);

    final hero = PageHero(
      title: title,
      titleMaxLines: 4,
      // On the posts' column (16), not the usual 24: a reading page lines its
      // title up with the avatars below it.
      padding: const EdgeInsets.fromLTRB(ForumPostTile.horizontal, 4, ForumPostTile.horizontal, 12),
      subtitle: detail == null
          ? null
          : Row(
              children: [
                if (category != null) ...[
                  Flexible(
                    child: ForumCategoryLabel(category: category, style: meta),
                  ),
                  Text(' · ', style: meta),
                ],
                Text(
                  l10n.remoteForumCompactReplies(detail.replies, forumCount(detail.replies)),
                  style: AppType.tabular(meta),
                ),
                Text(' · ', style: meta),
                Text(
                  l10n.remoteForumCompactViews(detail.views, forumCount(detail.views)),
                  style: AppType.tabular(meta),
                ),
              ],
            ),
    );

    final List<Widget> slivers;
    if (detail == null && async.hasError) {
      final error = async.error;
      slivers = [
        SliverToBoxAdapter(
          child: EmptyView(
            icon: AppIcons.offline,
            title: error is ForumException ? error.message : l10n.remoteForumErrTopic,
            actionLabel: l10n.commonRetry,
            onAction: () => ref.invalidate(forumTopicProvider(widget.topicId)),
          ),
        ),
      ];
    } else if (detail == null) {
      slivers = const [SliverToBoxAdapter(child: _PostsSkeleton())];
    } else {
      slivers = [
        SliverList.builder(
          itemCount: detail.posts.length,
          itemBuilder: (context, i) {
            final post = detail.posts[i];
            return FadeSlideIn(
              index: i,
              child: KeyedSubtree(
                key: _keyFor(post.postNumber),
                child: post.isSmallAction
                    ? _SmallAction(post: post)
                    : ForumPostTile(
                        post: post,
                        postUrl: _urlOf(detail, post),
                        signedIn: signedIn,
                        onLike: () => unawaited(_like(post)),
                        onReply: detail.closed || detail.archived ? null : () => unawaited(_reply(detail, to: post)),
                        onBookmark: () => unawaited(_bookmark(post)),
                        onMore: () => unawaited(_more(detail, post)),
                        onOpenTopic: (id, number) => unawaited(
                          Navigator.of(context).push(ForumTopicPage.route(topicId: id, postNumber: number)),
                        ),
                      ),
              ),
            );
          },
        ),
        SliverToBoxAdapter(
          child: hasMore || _loadingMore || _moreError != null
              ? ForumListFooter(
                  loading: _loadingMore || hasMore && _moreError == null,
                  error: _moreError,
                  onRetry: _loadMore,
                )
              : const SizedBox(height: 24),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: _ReplyBar.height + 12)),
      ];
    }

    final page = NotificationListener<ScrollUpdateNotification>(
      onNotification: (n) {
        if (hasMore && n.metrics.extentAfter < 900 && _moreError == null && !_loadingMore) {
          unawaited(_loadMore());
        }
        return false;
      },
      child: RefreshIndicator(
        edgeOffset: MediaQuery.paddingOf(context).top + 56,
        onRefresh: () async {
          try {
            await _controller.refresh();
          } on ForumException catch (e) {
            if (mounted) _toast(e.message);
          }
        },
        child: AppPage(
          title: title,
          hero: hero,
          actions: [
            if (detail != null)
              GlassIconButton(icon: AppIcons.more, tooltip: l10n.commonMore, onPressed: () => unawaited(_more(detail))),
          ],
          slivers: slivers,
        ),
      ),
    );

    _veil.value = MediaQuery.paddingOf(context).bottom + 12 + _ReplyBar.height - 6;
    return Stack(
      children: [
        Positioned.fill(child: page),
        if (detail != null) Positioned.fill(child: BackdropVeil(solidHeight: _veil)),
        if (detail != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: MediaQuery.paddingOf(context).bottom + 12,
            child: _ReplyBar(
              label: detail.closed || detail.archived
                  ? l10n.remoteForumTopicClosed
                  : (signedIn ? l10n.remoteForumReplyHint : l10n.remoteForumSignInToReply),
              enabled: !(detail.closed || detail.archived),
              onTap: () => unawaited(_reply(detail)),
            ),
          ),
      ],
    );
  }
}

/// The floating 「写回复…」 pill at the bottom (12 from the screen's edges,
/// like the chat composer).
class _ReplyBar extends StatelessWidget {
  const _ReplyBar({required this.label, required this.onTap, this.enabled = true});

  final String label;
  final VoidCallback onTap;
  final bool enabled;

  static const height = 48.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        child: GlassSurface(
          tier: GlassTier.chrome,
          stadium: true,
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                Icon(
                  AppIcons.reply,
                  size: 20,
                  color: enabled ? theme.colorScheme.onSurfaceVariant : colors.textDisabled,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: enabled ? colors.textTertiary : colors.textDisabled,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One post: who and when, the body, then like · reply · bookmark · more.
class ForumPostTile extends StatelessWidget {
  const ForumPostTile({
    super.key,
    required this.post,
    required this.signedIn,
    required this.onLike,
    required this.onReply,
    required this.onBookmark,
    required this.onMore,
    this.onOpenTopic,
    this.postUrl,
  });

  final ForumPost post;
  final bool signedIn;
  final VoidCallback onLike;
  final VoidCallback? onReply;
  final VoidCallback onBookmark;
  final VoidCallback onMore;
  final void Function(int topicId, int? postNumber)? onOpenTopic;
  final Uri? postUrl;

  static const horizontal = 16.0;
  static const avatarSize = 36.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final meta = theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary);
    final name = post.user.displayName;
    final handle = post.user.name?.trim();
    final subline = [
      if (handle != null && handle.isNotEmpty && handle != post.user.username) '@${post.user.username}',
      if (post.replyToUsername case final to?) l10n.remoteForumReplyTo(to),
      ?post.userTitle,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(horizontal, 16, horizontal, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ForumAvatar(username: post.user.username, template: post.user.avatarTemplate, size: avatarSize),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                    if (subline.isNotEmpty) Text(subline, maxLines: 1, overflow: TextOverflow.ellipsis, style: meta),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(forumAgo(post.createdAt), style: AppType.tabular(meta)),
            ],
          ),
          const SizedBox(height: 10),
          if (post.hidden || post.deleted)
            Text(
              post.deleted ? l10n.remoteForumPostDeleted : l10n.remoteForumPostHidden,
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
            )
          else
            ForumPostBody(cooked: post.cooked, onOpenTopic: onOpenTopic, postUrl: postUrl),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _PostAction(
                icon: post.liked ? AppIcons.postLikeActive : AppIcons.postLike,
                label: post.likeCount > 0 ? forumCount(post.likeCount) : null,
                tooltip: post.liked ? l10n.remoteForumUnlike : l10n.remoteForumLike,
                color: post.liked ? colors.danger : null,
                onTap: post.yours ? null : onLike,
              ),
              _PostAction(icon: AppIcons.reply, tooltip: l10n.commonReply, onTap: onReply),
              _PostAction(
                icon: post.bookmarked ? AppIcons.bookmarkActive : AppIcons.bookmark,
                tooltip: post.bookmarked ? l10n.remoteForumRemoveBookmark : l10n.remoteForumBookmark,
                onTap: onBookmark,
              ),
              _PostAction(icon: AppIcons.more, tooltip: l10n.commonMore, onTap: onMore),
            ],
          ),
        ],
      ),
    );
  }
}

/// A 36 tall icon key (with an optional count) under a post.
class _PostAction extends StatelessWidget {
  const _PostAction({required this.icon, required this.tooltip, this.label, this.color, this.onTap});

  final IconData icon;
  final String tooltip;
  final String? label;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final tint = onTap == null ? colors.textDisabled : (color ?? colors.textTertiary);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: tint),
                if (label case final label?) ...[
                  const SizedBox(width: 4),
                  Text(label, style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: tint))),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「置顶了话题」 and other moderator actions: one quiet centred line.
class _SmallAction extends StatelessWidget {
  const _SmallAction({required this.post});

  final ForumPost post;

  static String describe(String? code) => switch (code) {
    'pinned.enabled' || 'pinned_globally.enabled' => appL10n.remoteForumActionPinned,
    'pinned.disabled' || 'pinned_globally.disabled' => appL10n.remoteForumActionUnpinned,
    'closed.enabled' => appL10n.remoteForumActionClosed,
    'closed.disabled' => appL10n.remoteForumActionReopened,
    'autoclosed.enabled' => appL10n.remoteForumActionAutoClosed,
    'autoclosed.disabled' => appL10n.remoteForumActionAutoOpened,
    'archived.enabled' => appL10n.remoteForumActionArchived,
    'archived.disabled' => appL10n.remoteForumActionUnarchived,
    'visible.enabled' => appL10n.remoteForumActionListed,
    'visible.disabled' => appL10n.remoteForumActionUnlisted,
    'split_topic' => appL10n.remoteForumActionSplit,
    'banner.enabled' => appL10n.remoteForumActionBanner,
    'banner.disabled' => appL10n.remoteForumActionRemoveBanner,
    _ => appL10n.remoteForumActionUpdated,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Text(
        '${post.user.username} ${describe(post.actionCode)} · ${forumAgo(post.createdAt)}',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
      ),
    );
  }
}

class _PostsSkeleton extends StatelessWidget {
  const _PostsSkeleton();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.onSurface.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.08 : 0.06);
    Widget bar(double? width, double height) => Container(
      width: width,
      height: height,
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
    );
    return Semantics(
      label: l10n.remoteLoading,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < 3; i++) ...[
              Row(
                children: [
                  DecoratedBox(
                    decoration: ShapeDecoration(color: fill, shape: const CircleBorder()),
                    child: const SizedBox.square(dimension: ForumPostTile.avatarSize),
                  ),
                  const SizedBox(width: 10),
                  bar(96, 12),
                ],
              ),
              const SizedBox(height: 14),
              bar(double.infinity, 12),
              const SizedBox(height: 10),
              bar(double.infinity, 12),
              const SizedBox(height: 10),
              bar(180, 12),
              const SizedBox(height: 32),
            ],
          ],
        ),
      ),
    );
  }
}
