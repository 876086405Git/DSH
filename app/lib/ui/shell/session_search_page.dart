import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/session_deletion_state.dart';
import '../../state/session_search.dart';
import '../../state/sessions_state.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/fade_in.dart';
import '../common/side_insets.dart';
import '../common/status_dot.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'drawer/session_deletion.dart';
import 'page_frame.dart';
import 'sessions_drawer.dart' show sessionSelectionColor, sessionTitle;

/// "搜索对话" at the top of the sessions drawer. Opens [SessionSearchPage];
/// picking a result opens that conversation and closes the drawer.
class SessionSearchBar extends ConsumerWidget {
  const SessionSearchBar({
    super.key,
    required this.onClose,
    this.padding = const EdgeInsets.fromLTRB(10, 2, 10, 6),
    this.trailing,
  });

  /// Closes the drawer.
  final VoidCallback onClose;
  final EdgeInsetsGeometry padding;

  /// A key beside the bar, outside it (the list's options when nothing else
  /// in the drawer has room for them).
  final Widget? trailing;

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final sessionId = await showSessionSearch(context);
    if (sessionId == null || !context.mounted) return;
    ref.read(currentSessionProvider.notifier).select(sessionId);
    onClose();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final tertiary = DshColors.of(context).textTertiary;
    final bar = Semantics(
      button: true,
      label: l10n.shellSearchChats,
      onTap: () => _open(context, ref),
      excludeSemantics: true,
      child: GlassSurface(
        tier: GlassTier.pill,
        stadium: true,
        onTap: () => _open(context, ref),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Row(
            children: [
              Icon(AppIcons.search, size: 20, color: tertiary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  l10n.shellSearchChats,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: tertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: padding,
      child: trailing == null
          ? bar
          : Row(
              children: [
                Expanded(child: bar),
                trailing!,
              ],
            ),
    );
  }
}

/// Opens the search page; resolves to the picked session id, or null.
Future<String?> showSessionSearch(BuildContext context, {bool archivedOnly = false}) {
  return Navigator.of(context).push<String>(
    PageRouteBuilder<String>(
      transitionDuration: AppMotion.of(context, AppMotion.standard),
      reverseTransitionDuration: AppMotion.of(context, AppMotion.quick),
      pageBuilder: (_, _, _) => SessionSearchPage(archivedOnly: archivedOnly),
      transitionsBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(parent: animation, curve: AppMotion.enter, reverseCurve: AppMotion.exit);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(curved),
            child: child,
          ),
        );
      },
    ),
  );
}

/// Full-screen search over the active host's conversations: titles match as
/// you type, the Host's message-content search (when it has one) adds hits
/// with an excerpt, archived conversations come last and can be restored.
/// Pops with the picked session id.
class SessionSearchPage extends ConsumerStatefulWidget {
  const SessionSearchPage({super.key, this.now, this.archivedOnly = false});

  /// Browse archived chats without first knowing a title or search keyword.
  final bool archivedOnly;

  /// A window [width] wide centres the field over the results' reading
  /// column when that clears the back key (12 + 44 + 8 from the edge).
  static bool centresField(double width) => (width - AppSpace.floatingWidth) / 2 >= 12 + 44 + 8;

  /// The results' side padding: 12, or the reading column's edge plus 12.
  static double sideFor(double width) => math.max(12, (width - AppSpace.readingWidth) / 2 + 12);

  /// Clock override for the date labels (goldens).
  @visibleForTesting
  final DateTime? now;

  @override
  ConsumerState<SessionSearchPage> createState() => _SessionSearchPageState();
}

class _SessionSearchPageState extends ConsumerState<SessionSearchPage> {
  final _field = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _field.addListener(() => ref.read(sessionSearchProvider.notifier).setInput(_field.value));
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _clear() {
    _field.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final padding = MediaQuery.paddingOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(theme.brightness),
      child: AppBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          // A phone on its side: clear of the cutout on both sides.
          body: SideSafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: padding.top),
                BackdropGroup(
                  child: Padding(
                    // 12 on both sides, like every page header.
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final back = GlassIconButton(
                          icon: AppIcons.back,
                          tooltip: l10n.commonBack,
                          onPressed: () => Navigator.of(context).maybePop(),
                        );
                        final field = _SearchField(
                          controller: _field,
                          focusNode: _focus,
                          onClear: _clear,
                          autofocus: !widget.archivedOnly,
                          hint: widget.archivedOnly ? l10n.shellArchived : null,
                        );
                        // Wide: the field over the results' column, centred;
                        // the back key stays at the edge, like a page's.
                        if (SessionSearchPage.centresField(constraints.maxWidth + 24)) {
                          return Stack(
                            alignment: Alignment.center,
                            children: [
                              Align(alignment: Alignment.centerLeft, child: back),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: AppSpace.floatingWidth),
                                child: field,
                              ),
                            ],
                          );
                        }
                        return Row(
                          children: [
                            back,
                            const SizedBox(width: 8),
                            Expanded(child: field),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                Expanded(
                  child: _SearchBody(
                    now: widget.now,
                    archivedOnly: widget.archivedOnly,
                    onPick: (id) => Navigator.of(context).pop(id),
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

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onClear,
    this.autofocus = true,
    this.hint,
  });

  final bool autofocus;
  final String? hint;

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final tertiary = DshColors.of(context).textTertiary;
    const none = InputBorder.none;
    return GlassSurface(
      tier: GlassTier.chrome,
      stadium: true,
      grouped: true,
      // As tall as the 44 dp back button (a bare TextField takes 48); large
      // text grows it.
      child: SizedBox(
        height: math.max(44, MediaQuery.textScalerOf(context).scale(15) * 1.3 + 22),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          textInputAction: TextInputAction.search,
          inputFormatters: [LengthLimitingTextInputFormatter(200)],
          // The search key shows the results the keyboard was hiding.
          onSubmitted: (_) => focusNode.unfocus(),
          style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.3),
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            filled: false,
            border: none,
            enabledBorder: none,
            focusedBorder: none,
            isCollapsed: true,
            hintText: hint ?? l10n.shellSearchChats,
            hintStyle: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.3, color: tertiary),
            prefixIcon: Icon(AppIcons.search, size: 20, color: tertiary),
            prefixIconConstraints: const BoxConstraints(minWidth: 42, minHeight: 44),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) => value.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: l10n.commonClear,
                      onPressed: onClear,
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: const Size(40, 40),
                      ),
                      icon: Icon(AppIcons.clear, size: 18, color: tertiary),
                    ),
            ),
            suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 44),
          ),
        ),
      ),
    );
  }
}

enum _ArchivedAction { restore, delete }

class _SearchBody extends ConsumerWidget {
  const _SearchBody({required this.onPick, this.now, this.archivedOnly = false});

  final bool archivedOnly;

  final ValueChanged<String> onPick;
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final view = ref.watch(sessionSearchViewProvider);
    final sessions = ref.watch(sessionsProvider);
    final connected = ref.watch(activeConnectionProvider.select((c) => c.value != null));
    final host = ref.watch(activeHostProvider);
    final hostName = ref.watch(hostNameProvider(host)) ?? (host.isLocal ? l10n.commonThisPhone : l10n.commonRemoteHost);

    if (!connected && (sessions.value?.isEmpty ?? true)) {
      return _Notice(
        icon: host.isLocal ? AppIcons.power : AppIcons.disconnected,
        title: host.isLocal ? l10n.shellEngineNotRunning : l10n.shellHostNotConnected(hostName),
        body: l10n.shellSearchAfterConnecting,
      );
    }
    if (sessions.value == null && sessions.hasError) {
      return _Notice(
        icon: AppIcons.offline,
        title: l10n.shellChatsLoadFailed,
        action: (l10n.commonRetry, () => ref.read(sessionsProvider.notifier).refresh()),
      );
    }
    if (view.query.isEmpty && !archivedOnly) {
      final titlesOnly = ref.watch(sessionContentSearchProvider)?.knownUnsupported ?? false;
      return _Notice(
        icon: AppIcons.search,
        title: l10n.shellSearchHostChats(hostName),
        body: titlesOnly ? l10n.shellSearchTitlesHint : l10n.shellSearchContentHint,
      );
    }
    if (sessions.value == null) return _Notice(icon: AppIcons.loading, title: l10n.shellLoadingChatsEllipsis);

    late final archived = ref.read(sessionsProvider.notifier).archivedSessions;
    final results = !archivedOnly
        ? view.results
        : SessionSearchResults(
            terms: view.results.terms,
            archived: view.query.isEmpty
                ? [for (final session in archived) SessionSearchResult(session: session, archived: true, byTitle: true)]
                : view.results.archived,
            showFolders: view.query.isEmpty ? archived.map((s) => s.cwd).toSet().length > 1 : view.results.showFolders,
          );
    if (archivedOnly && view.query.isEmpty && archived.isEmpty) {
      return _Notice(icon: AppIcons.archive, title: l10n.shellArchived, body: l10n.shellNoChatsYet);
    }
    if (results.isEmpty) {
      if (view.content == ContentSearchStatus.pending) {
        return const Padding(padding: EdgeInsets.only(top: 12), child: _ContentFooter.pending());
      }
      return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.zero,
        children: [
          _Notice(icon: AppIcons.noResults, title: l10n.shellNoMatchingChats, body: l10n.shellSearchDifferentKeywords),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: _ContentFooter(view: view, centered: true),
          ),
        ],
      );
    }

    final current = ref.watch(currentSessionProvider);
    final clock = now ?? DateTime.now();
    Widget tile(SessionSearchResult r) => SearchResultTile(
      result: r,
      terms: results.terms,
      showFolder: results.showFolders,
      current: r.session.sessionId == current,
      now: clock,
      onTap: () => r.archived ? _openArchived(context, ref, r.session) : onPick(r.session.sessionId),
    );
    final side = SessionSearchPage.sideFor(MediaQuery.sizeOf(context).width);
    final activeCount = results.active.length;
    final footerIndex = results.length + (results.archived.isEmpty ? 0 : 1);
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(side, 4, side, MediaQuery.paddingOf(context).bottom + 24),
      itemCount: footerIndex + 1,
      itemBuilder: (context, i) {
        if (i == footerIndex) return _ContentFooter(view: view);
        final row = i < activeCount
            ? tile(results.active[i])
            : i == activeCount
            ? _Eyebrow(l10n.shellArchived)
            : tile(results.archived[i - activeCount - 1]);
        return FadeSlideIn(index: i, child: row);
      },
    );
  }

  /// Archived conversations can't be opened as they are (the Host stops their
  /// work); offer to restore before opening, or permanently delete them.
  Future<void> _openArchived(BuildContext context, WidgetRef ref, SessionSummary session) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final owner = container.read(activeHostProvider);
    final connection = container.read(activeConnectionProvider).value;
    final generation = connection?.client.mux.generation;
    final deletionOwner = captureSessionDeletionOwner(ref);
    var retired = false;
    final hosts = container.listen(activeHostProvider, (_, next) {
      if (next != owner) retired = true;
    });
    final connections = container.listen(activeConnectionProvider, (_, next) {
      if (next.isLoading || next.hasError || !identical(next.value, connection)) retired = true;
    }, fireImmediately: true);
    bool owned() =>
        !retired && !hosts.closed && !connections.closed && identical(connection?.client.mux.generation, generation);
    try {
      final action = await showAppSheet<_ArchivedAction>(
        context,
        builder: (sheet) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader(sessionTitle(session)),
              Padding(
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 8),
                child: Text(
                  context.l10n.shellRestoreBeforeOpening,
                  style: Theme.of(sheet).textTheme.bodyMedium
                      ?.copyWith(color: Theme.of(sheet).colorScheme.onSurfaceVariant),
                ),
              ),
              SheetGroup(
                children: [
                  ListTile(
                    leading: const Icon(AppIcons.unarchive),
                    title: Text(context.l10n.shellRestoreAndOpen),
                    onTap: () => Navigator.pop(sheet, _ArchivedAction.restore),
                  ),
                  SessionDeleteTile(
                    ids: [session.sessionId],
                    owner: deletionOwner,
                    archived: true,
                    onTap: () => Navigator.pop(sheet, _ArchivedAction.delete),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );
      if (!context.mounted) return;
      if (action == _ArchivedAction.delete && deletionOwner != null) {
        await deleteSessionsFlow(context, ref, [session.sessionId], owner: deletionOwner, archived: true);
        return;
      }
      if (action != _ArchivedAction.restore || !owned()) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      try {
        await unarchiveSession(ref, session.sessionId);
        if (context.mounted && owned()) onPick(session.sessionId);
      } catch (_) {
        if (context.mounted && owned()) messenger?.showSnackBar(SnackBar(content: Text(appL10n.shellRestoreFailed)));
      }
    } finally {
      deletionOwner?.close();
      hosts.close();
      connections.close();
    }
  }
}

/// One search hit: highlighted title with its date, the folder when the host's
/// conversations span several, and the Host's excerpt around a content match.
class SearchResultTile extends StatelessWidget {
  const SearchResultTile({
    super.key,
    required this.result,
    required this.terms,
    required this.showFolder,
    required this.current,
    required this.now,
    required this.onTap,
  });

  final SessionSearchResult result;
  final List<String> terms;
  final bool showFolder;
  final bool current;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final shape = Squircle.border(AppShape.md);
    final session = result.session;
    final title = sessionTitle(session);
    final folder = showFolder ? folderLabel(session.cwd) : null;
    final snippet = result.snippet;
    final excerpt = snippet == null || snippet.isEmpty ? null : excerptAround(snippet, matchRanges(snippet, terms));
    final hit = TextStyle(color: scheme.primary, fontWeight: FontWeight.w600);
    final date = searchDateLabel(session.updatedAt, now);

    return Semantics(
      button: true,
      selected: current,
      label: [
        title,
        if (session.running) l10n.shellCurrentlyRunning,
        if (result.archived) l10n.shellArchived,
        date,
        ?excerpt?.text,
      ].join(l10n.shellSemanticsSeparator),
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          child: Ink(
            decoration: ShapeDecoration(
              color: current ? sessionSelectionColor(context) : Colors.transparent,
              shape: shape,
            ),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: HighlightedText(
                        title,
                        ranges: session.title == null ? const [] : matchRanges(title, terms),
                        maxLines: 1,
                        style: theme.textTheme.bodyLarge!.copyWith(
                          fontSize: 15,
                          height: 1.4,
                          color: result.archived ? scheme.onSurfaceVariant : scheme.onSurface,
                          fontWeight: current ? FontWeight.w600 : FontWeight.w500,
                        ),
                        highlight: hit,
                      ),
                    ),
                    if (session.running) ...[const SizedBox(width: 8), const StatusDot(tone: StatusTone.busy, size: 7)],
                    const SizedBox(width: 10),
                    Text(
                      date,
                      style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: colors.textTertiary)),
                    ),
                  ],
                ),
                if (folder != null) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(AppIcons.workspace, size: 13, color: colors.textTertiary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: HighlightedText(
                          folder,
                          ranges: matchRanges(folder, terms),
                          maxLines: 1,
                          style: theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary),
                          highlight: hit,
                        ),
                      ),
                    ],
                  ),
                ],
                if (excerpt != null) ...[
                  const SizedBox(height: 3),
                  HighlightedText(
                    excerpt.text,
                    ranges: excerpt.ranges,
                    maxLines: 2,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontSize: 13,
                      height: 1.45,
                      color: scheme.onSurfaceVariant,
                    ),
                    highlight: hit,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [text] with [ranges] drawn in [highlight] over [style].
class HighlightedText extends StatelessWidget {
  const HighlightedText(
    this.text, {
    super.key,
    required this.ranges,
    required this.style,
    required this.highlight,
    this.maxLines,
  });

  final String text;
  final List<MatchRange> ranges;
  final TextStyle style;
  final TextStyle highlight;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    var at = 0;
    for (final r in ranges) {
      if (r.start < at || r.end > text.length) continue;
      if (r.start > at) spans.add(TextSpan(text: text.substring(at, r.start)));
      spans.add(TextSpan(text: text.substring(r.start, r.end), style: highlight));
      at = r.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

/// Short date for a result: the time today, 昨天, `M月d日` this year, else
/// `yyyy/M/d`.
String searchDateLabel(DateTime at, DateTime now) {
  final local = at.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (diff == 1) return appL10n.commonYesterday;
  if (local.year == now.year) return appL10n.monthDay(local);
  return '${local.year}/${local.month}/${local.day}';
}

/// Content-search status under the results: searching, titles only on this
/// host, a failure with retry, or the Host's 20-hit cap.
class _ContentFooter extends ConsumerWidget {
  const _ContentFooter({required this.view, this.centered = false}) : _pending = false;

  const _ContentFooter.pending() : view = const SessionSearchView(), centered = false, _pending = true;

  final SessionSearchView view;

  /// Under the "nothing found" notice: centred like it.
  final bool centered;
  final bool _pending;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary);
    Widget line(Widget child) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
      child: centered ? Center(child: child) : child,
    );
    final status = _pending ? ContentSearchStatus.pending : view.content;
    return switch (status) {
      ContentSearchStatus.pending => line(
        Row(
          children: [
            SizedBox.square(
              dimension: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: colors.textTertiary),
            ),
            const SizedBox(width: 8),
            Text(l10n.shellSearchingMessages, style: style),
          ],
        ),
      ),
      ContentSearchStatus.unsupported => line(
        Text(l10n.shellHostTitleSearchOnly, textAlign: centered ? TextAlign.center : null, style: style),
      ),
      ContentSearchStatus.failed => line(
        Row(
          mainAxisSize: centered ? MainAxisSize.min : MainAxisSize.max,
          children: [
            Flexible(
              fit: centered ? FlexFit.loose : FlexFit.tight,
              child: Text(l10n.shellContentSearchFailed, style: style),
            ),
            TextButton(
              onPressed: () => ref.read(sessionSearchProvider.notifier).retry(),
              style: TextButton.styleFrom(minimumSize: const Size(0, 32), visualDensity: VisualDensity.compact),
              child: Text(l10n.commonRetry),
            ),
          ],
        ),
      ),
      ContentSearchStatus.ready when view.hasMore => line(Text(l10n.shellContentSearchLimit, style: style)),
      _ => const SizedBox.shrink(),
    };
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
      child: Text(text, style: AppType.eyebrow(color: DshColors.of(context).textTertiary)),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.title, this.body, this.action});

  final IconData icon;
  final String title;
  final String? body;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 56),
      child: EmptyView(icon: icon, title: title, message: body, actionLabel: action?.$1, onAction: action?.$2),
    );
  }
}
