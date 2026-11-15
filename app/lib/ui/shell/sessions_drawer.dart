// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../runtime/local_footprint.dart';
import '../../state/bots_state.dart';
import '../../state/connection_state.dart';
import '../../state/engine_control.dart';
import '../../state/hosts_state.dart';
import '../../state/drawer_view_state.dart';
import '../../state/session_attention_state.dart';
import '../../state/session_deletion_state.dart';
import '../../state/sessions_state.dart';
import '../../state/read_list_identity.dart';
import '../../state/workspaces_state.dart';
import '../bots/bots_page.dart' show BotsPage, UnreadBadge;
import '../chat/media/media_format.dart' show chatTitleShown;
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/pressable.dart';
import '../common/smooth_size.dart';
import '../common/read_list_status.dart';
import '../common/status_dot.dart';
import '../onboarding/local_install.dart';
import '../modes/mode_switch.dart';
import '../remote/host_status.dart';
import '../remote/host_switcher.dart' show showHostSheet;
import '../remote/network_details_sheet.dart' show showRemoteNetworkDetails;
import '../safe_mode/engine_failure_card.dart';
import '../safe_mode/safe_mode_banner.dart';
import '../share/share_entry.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/mode_home.dart';
import '../workspace/text_prompt.dart';
import '../workspace/workspace_switcher.dart';
import '../workspace/workspaces_page.dart';
import 'adaptive/adaptive_layout.dart' show WindowClass;
import 'brand_mark.dart';
import 'drawer/drawer_actions.dart';
import 'drawer/drawer_destination.dart';
import 'drawer/archive_notice.dart';
import 'drawer/drawer_filter_bar.dart';
import 'drawer/drawer_list.dart';
import 'drawer/selection_bars.dart';
import 'drawer/session_deletion.dart';
import 'session_search_page.dart';

export '../../state/drawer_view_state.dart' show SessionDay, sessionDayOf;
export 'drawer/drawer_destination.dart';
export 'drawer/session_tile.dart' show SessionTile;

/// Display title for a session: DSH's generated title (a generation
/// request's header left out), else a neutral fallback.
String sessionTitle(SessionSummary s) {
  final t = s.title?.trim();
  return t == null || t.isEmpty ? appL10n.commonUntitledChat : chatTitleShown(t);
}

/// The soft fill behind the current conversation (drawer and search).
Color sessionSelectionColor(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return scheme.primary.withValues(alpha: scheme.brightness == Brightness.dark ? 0.18 : 0.09);
}

/// The sessions drawer: brand and "新对话" on top, search, the workspace
/// switcher with the list's options, the status filters, the active host's
/// conversations (pinned, folders, then by day), and an identity bar at the
/// bottom (the host, 网页版, 设置). In multi-select the brand row and the
/// identity bar give way to the selection header and its action bar.
class SessionsDrawer extends ConsumerWidget {
  const SessionsDrawer({
    super.key,
    required this.onClose,
    required this.onOpen,
    this.now,
    this.identityBarHeight,
    this.drawerMotion,
  });

  final VoidCallback onClose;
  final ValueChanged<DrawerDestination> onOpen;

  /// Clock override for grouping (tests).
  final DateTime? now;

  /// Told the height of the identity bar (and of the action bar over it in
  /// multi-select) once it is laid out: the pulled-over drawer's notices
  /// stand above it.
  final ValueNotifier<double>? identityBarHeight;

  /// The pulled-over drawer's 0 → 1 animation (null for the persistent
  /// sidebar). While it moves, the panel drops its backdrop blur: a moving
  /// glass surface re-samples the whole chat behind it every frame, which is
  /// the expensive part on mid-range GPUs.
  final Animation<double>? drawerMotion;

  /// Where the content sits in from either edge: the search bar, the rows'
  /// highlights and the identity bar's keys.
  static const contentEdge = 10.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void newChat() {
      ref.read(currentSessionProvider.notifier).select(null);
      onClose();
    }

    void manageWorkspaces() {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WorkspacesPage()));
      // Close once the page covers us, so "back" lands on the chat.
      Future<void>.delayed(AppMotion.slow, onClose);
    }

    final selecting =
        ref.watch(drawerSelectionProvider.select((s) => s != null)) && ref.watch(drawerScopeProvider)?.readOnly != true;
    // The drawer stays mounted with the shell: it keeps the unread record
    // following what the person opens and leaves.
    ref.listen(drawerSeenProvider, (_, _) {});
    // Folders forget conversations the host no longer has.
    ref.listen(sessionsProvider, (_, next) {
      if (!next.hasValue || next.isLoading) return;
      final known = {for (final s in ref.read(sessionsProvider.notifier).allSessions) s.sessionId};
      if (known.isNotEmpty) unawaited(ref.read(drawerViewProvider.notifier).forgetMissing(known));
    });
    // Hidden (closed by a tap, a swipe or back): multi-select ends with it.
    if (selecting && !TickerMode.valuesOf(context).enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) ref.read(drawerSelectionProvider.notifier).end();
      });
    }
    final quick = AppMotion.of(context, AppMotion.quick);
    // A phone on its side: the top of the drawer (brand, search, filters)
    // would leave room for two conversations, so it scrolls away with them.
    final short = MediaQuery.sizeOf(context).height < WindowClass.compactHeight;
    final top = <Widget>[
      AnimatedSwitcher(
        duration: quick,
        child: selecting
            ? DrawerSelectionHeader(key: const ValueKey('selecting'), now: now)
            : Padding(
                key: const ValueKey('brand'),
                // The lockup lines up with the rows' text (20); the
                // button's edge with the search bar's and the rows'
                // edges (10).
                padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
                child: LayoutBuilder(
                  builder: (context, box) => Row(
                    children: [
                      // On a narrow drawer with large text the lockup gives
                      // way a little rather than the keys.
                      const Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: FittedBox(fit: BoxFit.scaleDown, child: BrandLockup(height: 19)),
                        ),
                      ),
                      // 模式 and 网页模式, quietly: the one solid element stays 新对话.
                      const ModeKey(),
                      const SizedBox(width: 8),
                      const WebModeKey(tier: GlassTier.pill),
                      const SizedBox(width: 8),
                      // When even the lockup's room is not enough, 新对话
                      // keeps its glyph and lets its words go.
                      NewChatButton(
                        onTap: newChat,
                        compact: NewChatButton.widthOf(context) > box.maxWidth - (36 + 8 + 36 + 8),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      SafeModeBanner(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        onDetails: () => onOpen(DrawerDestination.engine),
      ),
      SessionSearchBar(onClose: onClose),
      // The workspace switcher (once the host's workspace list has
      // arrived) and the list's options, then the status filters.
      SmoothSize(
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
        alignment: Alignment.topCenter,
        child: Row(
          children: [
            Expanded(child: WorkspaceSwitcher(onManage: manageWorkspaces)),
            _ViewOptionsKey(onClose: onClose),
          ],
        ),
      ),
      SmoothSize(
        duration: AppMotion.of(context, AppMotion.standard),
        curve: AppMotion.std,
        alignment: Alignment.topCenter,
        child: const DrawerFilterBar(),
      ),
    ];
    final list = _EdgeFade(
      child: _SessionList(onClose: onClose, now: now),
    );

    const radius = BorderRadius.only(topRight: Radius.circular(AppShape.xl), bottomRight: Radius.circular(AppShape.xl));
    final content = Material(
      type: MaterialType.transparency,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (short)
              Expanded(
                child: NestedScrollView(
                  headerSliverBuilder: (context, _) => [
                    SliverToBoxAdapter(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: top),
                    ),
                  ],
                  body: list,
                ),
              )
            else ...[
              ...top,
              Expanded(child: list),
            ],
            // The action bar lies exactly over the identity bar, which
            // keeps its size while hidden: same height at any text size.
            _ReportHeight(
              height: identityBarHeight,
              child: Stack(
                children: [
                  AnimatedOpacity(
                    opacity: selecting ? 0 : 1,
                    duration: quick,
                    child: IgnorePointer(
                      ignoring: selecting,
                      child: ExcludeSemantics(
                        excluding: selecting,
                        child: IdentityBar(
                          onHost: () => showHostSheet(context, onManage: () => onOpen(DrawerDestination.remote)),
                          onLocalDetails: () => onOpen(DrawerDestination.engine),
                          onFeatures: () => onOpen(DrawerDestination.features),
                          onSettings: () => onOpen(DrawerDestination.settings),
                          onSettingsHold: () => onOpen(DrawerDestination.settingsSearch),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: AnimatedSwitcher(
                      duration: quick,
                      child: selecting
                          ? SelectionActionBar(
                              key: const ValueKey('selecting'),
                              onMove: () {
                                if (ref.read(drawerScopeProvider)?.readOnly == false) {
                                  moveToFolderFlow(
                                    context,
                                    ref,
                                    ref.read(drawerSelectionProvider)?.toList() ?? const [],
                                  );
                                }
                              },
                              onPin: () {
                                if (ref.read(drawerScopeProvider)?.readOnly == false) pinSelectionFlow(context, ref);
                              },
                              onArchive: () {
                                if (ref.read(drawerScopeProvider)?.readOnly == false) {
                                  archiveSelectionFlow(context, ref);
                                }
                              },
                              onDelete: () {
                                if (ref.read(drawerScopeProvider)?.readOnly == false) {
                                  unawaited(deleteSelectionFlow(context, ref));
                                }
                              },
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final motion = drawerMotion;
    if (motion == null) {
      return GlassSurface(tier: GlassTier.sheet, borderRadius: radius, child: content);
    }
    return SlidingGlass(motion: motion, tier: GlassTier.sheet, borderRadius: radius, child: content);
  }
}

/// Tells [height] the child's height after each layout that changes it (on
/// the next frame: nothing above is rebuilt while laying out).
class _ReportHeight extends SingleChildRenderObjectWidget {
  const _ReportHeight({required this.height, required super.child});

  final ValueNotifier<double>? height;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderReportHeight(height);

  @override
  void updateRenderObject(BuildContext context, _RenderReportHeight renderObject) => renderObject.height = height;
}

class _RenderReportHeight extends RenderProxyBox {
  _RenderReportHeight(this.height);

  ValueNotifier<double>? height;

  @override
  void performLayout() {
    super.performLayout();
    final target = height;
    final value = size.height;
    if (target == null || target.value == value) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (attached && identical(height, target)) target.value = value;
    });
  }
}

/// "新对话": the drawer's one solid primary element, a 36dp pill.
class NewChatButton extends StatelessWidget {
  const NewChatButton({super.key, required this.onTap, this.compact = false});

  final VoidCallback onTap;

  /// Only the glyph, in a 36dp circle: for a row too narrow for the words.
  final bool compact;

  /// How wide the pill with its words is, in [context]'s text size.
  static double widthOf(BuildContext context) {
    final label = TextPainter(
      text: TextSpan(text: context.l10n.commonNewChat, style: Theme.of(context).textTheme.labelLarge),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final width = 12 + 20 + 4 + label.width + 15;
    label.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      label: l10n.commonNewChat,
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        child: Material(
          color: scheme.primary,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36, minWidth: 36),
              child: compact
                  ? Center(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: Icon(AppIcons.newChat, size: 20, color: scheme.onPrimary),
                    )
                  : Padding(
                      // The glyph carries ~3dp of its own air on the left: 12 + 3
                      // reads as the 15 on the right.
                      padding: const EdgeInsets.fromLTRB(12, 0, 15, 0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(AppIcons.newChat, size: 20, color: scheme.onPrimary),
                          const SizedBox(width: 4),
                          Text(
                            l10n.commonNewChat,
                            style: theme.textTheme.labelLarge?.copyWith(color: scheme.onPrimary),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「对话列表」 options at the end of the workspace row, its circle on the 10
/// line; only while there are conversations to organise.
class _ViewOptionsKey extends ConsumerWidget {
  const _ViewOptionsKey({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(drawerScopeProvider);
    final filtered = ref.watch(drawerFilterProvider) != DrawerFilter.all;
    ref.watch(sessionsProvider);
    final hasArchived = ref.read(sessionsProvider.notifier).archivedSessions.isNotEmpty;
    if (scope == null || (scope.sessions.isEmpty && !filtered && !hasArchived)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: DrawerViewButton(onTap: () => openDrawerViewOptions(context, ref, onClose: onClose)),
    );
  }
}

/// Soft top and bottom edges on the list, so rows fade into the header and
/// the identity bar instead of being cut. At rest nothing is under either fade
/// (the list's own padding is deeper).
class _EdgeFade extends StatelessWidget {
  const _EdgeFade({required this.child});

  final Widget child;

  static const _top = 10.0;
  static const _bottom = 16.0;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final h = rect.height <= 0 ? 1.0 : rect.height;
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
          stops: [0, (_top / h).clamp(0.0, 0.5), (1 - _bottom / h).clamp(0.5, 1.0), 1],
        ).createShader(rect);
      },
      child: child,
    );
  }
}

class _SessionList extends ConsumerWidget {
  const _SessionList({required this.onClose, this.now});

  final VoidCallback onClose;
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final sessions = ref.watch(sessionsProvider);
    final identity = ref.watch(readListIdentityProvider);
    final workspace = ref.watch(selectedWorkspaceProvider);
    // Null while loading, or while a selected workspace's members haven't
    // arrived (rather than flash every conversation).
    final scope = ref.watch(drawerScopeProvider);
    if (scope == null) {
      if (ref.watch(readListLiveConnectionProvider) == null && !sessions.isLoading) return const _EmptyState();
      if (sessions.hasError) {
        return _Centered(
          child: EmptyView(
            compact: true,
            icon: AppIcons.offline,
            title: l10n.shellChatsLoadFailed,
            actionLabel: l10n.commonRetry,
            onAction: () => ref.read(sessionsProvider.notifier).refresh(),
          ),
        );
      }
      return const _SkeletonList();
    }
    // DS Bot's conversations (its Bots' chats, groups, members' sessions)
    // fold into one row that opens the Bot pages.
    final botReady = ref.watch(dsBotProvider.select((s) => s.ready));
    final showBots = scope.bots.isNotEmpty || (workspace == null && botReady);
    if (scope.sessions.isEmpty && !showBots && ref.watch(drawerViewProvider).folders.isEmpty) {
      if (scope.readOnly) return _Centered(child: Text(readListStatusText(scope.status)));
      return workspace == null ? const _EmptyState() : const _WorkspaceEmptyState();
    }
    return DrawerConversationList(
      now: now,
      onNewChat: onClose,
      readOnly: scope.readOnly,
      leading: showBots
          ? DsBotDrawerRow(
              running: scope.bots.any((s) => s.running),
              onTap: () {
                Navigator.of(context).push(BotsPage.route());
                // Close once the page covers us, so "back" lands on the chat.
                Future<void>.delayed(AppMotion.slow, onClose);
              },
            )
          : null,
      onOpen: (id) {
        if (ref.read(readListIdentityProvider) != identity ||
            ref.read(drawerScopeProvider)?.sessions.any((s) => s.sessionId == id) != true) {
          return;
        }
        ref.read(currentSessionProvider.notifier).select(id);
        onClose();
      },
      onLongPress: (s) {
        final current = ref.read(drawerScopeProvider);
        if (ref.read(readListIdentityProvider) == identity &&
            current?.readOnly == false &&
            current!.sessions.any((row) => identical(row, s))) {
          _showActions(context, ref, s);
        }
      },
    );
  }

  Future<void> _showActions(BuildContext context, WidgetRef ref, SessionSummary s) async {
    // Consent belongs to the host/generation present before the action sheet.
    final owner = captureSessionDeletionOwner(ref);
    try {
      await _showOwnedActions(context, ref, s, owner);
    } finally {
      owner?.close();
    }
  }

  Future<void> _showOwnedActions(
    BuildContext context,
    WidgetRef ref,
    SessionSummary s,
    SessionDeletionOwner? deletionOwner,
  ) async {
    final title = sessionTitle(s);
    final workspaces = ref.read(workspacesProvider);
    final pinned = workspaces.pinnedSessionIds.contains(s.sessionId);
    final inFolder = ref.read(drawerViewProvider).folderOf.containsKey(s.sessionId);
    final action = await showAppSheet<String>(
      context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.8),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SheetHeader(title),
                SheetGroup(
                  children: [
                    // Pinning lives in the host's workspace registry.
                    if (workspaces.ready)
                      ListTile(
                        leading: Icon(pinned ? AppIcons.pinActive : AppIcons.pin),
                        title: Text(pinned ? context.l10n.shellUnpin : context.l10n.commonPin),
                        onTap: () => Navigator.pop(sheet, pinned ? 'unpin' : 'pin'),
                      ),
                    ListTile(
                      leading: const Icon(AppIcons.rename),
                      title: Text(context.l10n.commonRename),
                      onTap: () => Navigator.pop(sheet, 'rename'),
                    ),
                    ListTile(
                      leading: const Icon(AppIcons.moveToFolder),
                      title: Text(inFolder ? context.l10n.shellMoveToOtherFolder : context.l10n.shellMoveToFolder),
                      onTap: () => Navigator.pop(sheet, 'folder'),
                    ),
                    ListTile(
                      leading: const Icon(AppIcons.share),
                      title: Text(context.l10n.commonShare),
                      onTap: () => Navigator.pop(sheet, 'share'),
                    ),
                    ListTile(
                      leading: const Icon(AppIcons.multiSelect),
                      title: Text(context.l10n.shellMultiSelect),
                      onTap: () => Navigator.pop(sheet, 'select'),
                    ),
                    ListTile(
                      leading: const Icon(AppIcons.archive),
                      title: Text(context.l10n.shellArchive),
                      subtitle: Text(context.l10n.shellArchiveStopsTurn),
                      onTap: () => Navigator.pop(sheet, 'archive'),
                    ),
                    SessionDeleteTile(
                      ids: [s.sessionId],
                      owner: deletionOwner,
                      onTap: () {
                        if (deletionOwner?.isCurrent(ref) == true) Navigator.pop(sheet, 'delete');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    switch (action) {
      case 'pin' || 'unpin':
        try {
          final notifier = ref.read(workspacesProvider.notifier);
          await (action == 'pin' ? notifier.pinSession(s.sessionId) : notifier.unpinSession(s.sessionId));
        } catch (_) {
          messenger?.showSnackBar(
            SnackBar(content: Text(action == 'pin' ? appL10n.shellPinFailed : appL10n.shellUnpinFailed)),
          );
        }
      case 'share':
        await shareConversation(context, s.sessionId);
      case 'folder':
        await moveToFolderFlow(context, ref, [s.sessionId]);
      case 'select':
        ref.read(drawerSelectionProvider.notifier).start(s.sessionId);
      case 'rename':
        final next = await _askTitle(context, s.title?.trim() ?? '');
        if (next == null || next.isEmpty || next == s.title) return;
        try {
          await ref.read(sessionsProvider.notifier).rename(s.sessionId, next);
        } catch (_) {
          messenger?.showSnackBar(SnackBar(content: Text(appL10n.shellRenameFailed)));
        }
      case 'delete':
        if (deletionOwner != null && deletionOwner.isCurrent(ref)) {
          await deleteSessionsFlow(context, ref, [s.sessionId], owner: deletionOwner);
        }
      case 'archive':
        unawaited(
          scheduleArchiveNotice(context, ref, [
            s.sessionId,
          ], s.running ? appL10n.shellChatStoppedArchived(title) : appL10n.shellChatArchived(title)),
        );
    }
  }

  Future<String?> _askTitle(BuildContext context, String initial) {
    return showTextPrompt(
      context,
      title: context.l10n.shellRenameChat,
      initial: initial,
      hint: context.l10n.shellChatTitle,
      maxLength: 80,
    );
  }
}

/// DS Bot's conversations as one row above the list: the glyph on the 20
/// text line, 「DS Bot」, then a breathing dot while a Bot works and the
/// unread count. Opens the Bot pages.
class DsBotDrawerRow extends ConsumerWidget {
  const DsBotDrawerRow({super.key, required this.running, required this.onTap});

  final bool running;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = ref.watch(dsBotInboxProvider.select((i) => i.total));
    final shape = Squircle.border(AppShape.md);
    return Semantics(
      button: true,
      label: [
        'DS Bot',
        if (running) l10n.shellCurrentlyRunning,
        if (unread > 0) l10n.shellUnreadCount(unread),
      ].join(l10n.shellSemanticsSeparator),
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          child: SizedBox(
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Icon(AppIcons.bot, size: 20, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'DS Bot',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontSize: 15,
                        height: 1.4,
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (running) ...[const SizedBox(width: 10), const StatusDot(tone: StatusTone.busy, size: 7)],
                  if (unread > 0) ...[const SizedBox(width: 10), UnreadBadge(unread)],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Loading: a few quiet placeholder rows on the same grid as the real ones,
/// breathing slowly (still under reduced motion).
class _SkeletonList extends StatefulWidget {
  const _SkeletonList();

  @override
  State<_SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<_SkeletonList> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: AppMotion.breath);
  late final Animation<double> _opacity = _breath.drive(
    Tween(begin: 0.55, end: 1.0).chain(CurveTween(curve: AppMotion.std)),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _breath
        ..stop()
        ..value = 1;
    } else if (!_breath.isAnimating) {
      _breath.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final fill = scheme.onSurface.withValues(alpha: scheme.brightness == Brightness.dark ? 0.09 : 0.07);
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
    );
    const widths = [0.72, 0.5, 0.64, 0.42, 0.58];
    return Semantics(
      label: l10n.shellLoadingChats,
      child: FadeTransition(
        opacity: _opacity,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final row = constraints.maxWidth - 40;
            return ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              children: [
                Padding(padding: const EdgeInsets.only(top: 19, bottom: 9), child: bar(28, 8)),
                for (final w in widths)
                  SizedBox(
                    height: 44,
                    child: Align(alignment: Alignment.centerLeft, child: bar(row * w, 10)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Keeps an empty view in the upper third of the list area.
class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Align(
            alignment: const Alignment(0, -0.4),
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: child),
          ),
        ),
      ),
    );
  }
}

/// The selected workspace has no conversations yet.
class _WorkspaceEmptyState extends ConsumerWidget {
  const _WorkspaceEmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return _Centered(
      child: EmptyView(
        compact: true,
        icon: AppIcons.folderOpen,
        title: l10n.shellWorkspaceNoChats,
        message: l10n.shellWorkspaceNewChatsHint,
        actionLabel: l10n.remoteWorkspaceAllChats,
        onAction: () => ref.read(workspacePrefsProvider.notifier).select(null),
      ),
    );
  }
}

/// No sessions: either the engine (or remote host) isn't up yet, or there
/// simply are none.
class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final host = ref.watch(activeHostProvider);
    if (!host.isLocal) return _RemoteEmptyState(host: host);
    final status = ref.watch(localRuntimeProvider.select((s) => s.status));
    if (EngineFailureCard.visibleFor(status)) {
      return const SingleChildScrollView(padding: EdgeInsets.fromLTRB(10, 8, 10, 16), child: EngineFailureCard());
    }
    final view = switch (status.phase) {
      RuntimePhase.running => EmptyView(
        compact: true,
        icon: AppIcons.chat,
        title: l10n.shellNoChatsYet,
        message: l10n.shellNewChatsHint,
      ),
      RuntimePhase.starting => EmptyView(
        compact: true,
        icon: AppIcons.loading,
        title: l10n.shellEngineStarting,
        message: l10n.shellChatsAfterStarting,
      ),
      RuntimePhase.installed || RuntimePhase.error => EmptyView(
        compact: true,
        icon: AppIcons.power,
        title: l10n.shellEngineNotRunning,
        message: l10n.shellChatsAfterStarting,
        actionLabel: l10n.shellStartEngine,
        onAction: () => unawaited(EngineControl.ensureStarted(ProviderScope.containerOf(context))),
      ),
      RuntimePhase.notInstalled when status.runtimeMissing => switch (localMissingCopy(
        l10n,
        available: ref.watch(localRuntimeProvider.select((s) => s.available)),
      )) {
        final copy => EmptyView(
          compact: true,
          icon: AppIcons.thisPhone,
          title: copy.title,
          actionLabel: copy.action,
          onAction: () => unawaited(openLocalInstall(context)),
        ),
      },
      _ => EmptyView(
        compact: true,
        icon: AppIcons.power,
        title: l10n.shellEngineNotRunning,
        message: l10n.shellEngineStatusHint,
      ),
    };
    return _Centered(child: view);
  }
}

/// Empty list on a remote host: connecting, failed (with the reason and a
/// retry), or connected with no conversations yet.
class _RemoteEmptyState extends ConsumerWidget {
  const _RemoteEmptyState({required this.host});

  final HostRef host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final name = ref.watch(hostNameProvider(host)) ?? l10n.commonRemoteHost;
    final status = ref.watch(hostLinkStatusProvider(host)).value ?? HostLinkStatus.idle;
    void retry() => ref.read(remoteConnectionProvider(host).notifier).retry();
    final view = switch (status.phase) {
      HostLinkPhase.connected => EmptyView(
        compact: true,
        icon: AppIcons.chat,
        title: l10n.shellNoChatsYet,
        message: l10n.shellNewChatsHint,
      ),
      HostLinkPhase.failed => EmptyView(
        compact: true,
        icon: AppIcons.disconnected,
        title: l10n.shellHostUnreachable(name),
        message: status.error?.message ?? l10n.commonConnectionFailed,
        actionLabel: status.error?.retryable ?? true ? l10n.commonRetry : null,
        onAction: retry,
      ),
      HostLinkPhase.reconnecting => EmptyView(
        compact: true,
        icon: AppIcons.reconnecting,
        title: l10n.shellHostReconnecting(name),
        message: status.error?.message,
        actionLabel: l10n.shellRetryNow,
        onAction: retry,
      ),
      _ => EmptyView(
        compact: true,
        icon: AppIcons.reconnecting,
        title: l10n.shellHostConnecting(name),
        message: status.step == null ? l10n.shellHostChatsAfterConnecting : '${status.step!.label}…',
      ),
    };
    return _Centered(child: view);
  }
}

/// The drawer's footer: the host icon opens its details; the name and dropdown
/// switch hosts. 全部功能 and 设置 follow as two equal round buttons.
class IdentityBar extends ConsumerWidget {
  const IdentityBar({
    super.key,
    required this.onHost,
    required this.onFeatures,
    required this.onSettings,
    this.onSettingsHold,
    this.onLocalDetails,
  });

  final VoidCallback onHost;

  /// Local hosts have engine details, not a remote network path.
  final VoidCallback? onLocalDetails;

  /// 全部功能: what there is to do now. (网页版 is in 全部功能, in 设置 ›
  /// 界面 and on the brand row's switch.)
  final VoidCallback onFeatures;
  final VoidCallback onSettings;

  /// ⚙ held down: straight to settings search.
  final VoidCallback? onSettingsHold;

  /// The round keys, and the host pill's height beside them.
  static const keySize = 44.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final host = ref.watch(activeHostProvider);
    final name = ref.watch(hostNameProvider(host)) ?? (host.isLocal ? l10n.commonThisPhone : l10n.commonRemoteHost);
    final view = watchHostStatus(ref, host);
    final link = host.kind == HostKind.relay ? ref.watch(hostLinkStatusProvider(host)).value : null;
    final path = link?.isConnected == true ? link?.network?.path ?? link?.path : null;
    final statusLabel = path == null ? view.label : path.label;
    final tint = hostKindTint(host.kind);
    return Padding(
      // Same 10 / 20 grid as the rows above: the highlight's edge at 10, the
      // avatar on the 20 text line, the last button's edge at 10. The host
      // pill is as tall as the round keys beside it (44; taller only for
      // large text).
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 13),
      child: Row(
        children: [
          Expanded(
            child: Row(
              key: const ValueKey('identity-host-controls'),
              children: [
                const SizedBox(width: 6),
                IconButton(
                  key: const ValueKey('identity-host-details'),
                  tooltip: host.isLocal ? l10n.phoneEngineTitle : l10n.remoteNetworkDetails,
                  onPressed: host.isLocal ? onLocalDetails : () => showRemoteNetworkDetails(context, host),
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints.tightFor(width: keySize, height: keySize),
                  style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  icon: DecoratedBox(
                    decoration: ShapeDecoration(color: colors.identity[tint], shape: const CircleBorder()),
                    child: SizedBox.square(
                      dimension: 36,
                      child: Icon(hostKindIcon(host.kind), size: 19, color: colors.onIdentity[tint]),
                    ),
                  ),
                ),
                Expanded(
                  child: Semantics(
                    button: true,
                    label: l10n.shellCurrentHostLabel(name, statusLabel),
                    onTap: onHost,
                    excludeSemantics: true,
                    child: InkWell(
                      key: const ValueKey('identity-host-switcher'),
                      onTap: onHost,
                      customBorder: Squircle.border(AppShape.md),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: IdentityBar.keySize),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              Flexible(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleSmall,
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        StatusDot(tone: view.tone, size: 6),
                                        const SizedBox(width: 6),
                                        Flexible(
                                          child: AnimatedSwitcher(
                                            duration: AppMotion.of(context, AppMotion.quick),
                                            layoutBuilder: (current, previous) => Stack(
                                              alignment: Alignment.centerLeft,
                                              children: [...previous, ?current],
                                            ),
                                            child: Text(
                                              statusLabel,
                                              key: ValueKey(statusLabel),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: AppType.tabular(
                                                theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(AppIcons.dropdown, size: 18, color: colors.textTertiary),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _RoundButton(icon: AppIcons.allFeatures, tooltip: l10n.hubSettingsAllFeatures, onTap: onFeatures),
          const SizedBox(width: 8),
          _RoundButton(
            icon: AppIcons.settings,
            tooltip: l10n.commonSettings,
            onTap: onSettings,
            onLongPress: onSettingsHold,
          ),
        ],
      ),
    );
  }
}

/// 44dp pill-glass circle (no blur: the drawer is already glass).
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.tooltip, required this.onTap, this.onLongPress});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final hold = onLongPress;
    Widget button = SizedBox.square(
      dimension: IdentityBar.keySize,
      child: GlassSurface(
        tier: GlassTier.pill,
        circle: true,
        onTap: onTap,
        child: Center(child: Icon(icon, size: 22, color: Theme.of(context).colorScheme.onSurface)),
      ),
    );
    if (hold != null) {
      button = GestureDetector(
        onLongPress: () {
          unawaited(HapticFeedback.mediumImpact());
          hold();
        },
        child: button,
      );
    }
    return Tooltip(
      message: tooltip,
      // Holding it does something of its own.
      triggerMode: hold == null ? null : TooltipTriggerMode.manual,
      child: Semantics(
        button: true,
        label: tooltip,
        onTap: onTap,
        onLongPress: hold,
        excludeSemantics: true,
        child: button,
      ),
    );
  }
}
