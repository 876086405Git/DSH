// The phone counterpart of DSH Web's right-side session panels (trajectory,
// changes, files, progress, context, subagents) as one full-screen page with a
// glass segmented control — and, on bigger windows, the same tabs as a sheet
// (medium) or a column beside the chat (wide).

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/adaptive_layout_state.dart';
import '../../state/agents_state.dart';
import '../../state/app_notes.dart';
import '../../state/chat_state.dart';
import '../../state/session_detail_state.dart';
import '../../state/usage_state.dart';
import '../agents/agent_widgets.dart';
import '../chat/chat_header.dart';
import '../chat/diff_page.dart';
import '../chat/run_info.dart';
import '../chat/step_detail_page.dart';
import '../chat/tool_view.dart' show PhoneResultText;
import '../chat/trajectory_sheet.dart';
import '../chat/turn_summary.dart';
import '../chat/usage_sheet.dart';
import '../chat/widgets/activity_strip.dart' show TodoProgress;
import '../chat/widgets/change_card.dart' show DiffCounts;
import '../chat/widgets/live_clock.dart';
import '../common/app_sheet.dart' show SheetIconButton, kSheetGutter;
import '../common/empty_view.dart';
import '../common/expand_reveal.dart';
import '../common/feature_tile.dart';
import '../common/fade_in.dart';
import '../common/list_page_row.dart';
import '../common/page_hero.dart';
import '../common/segmented_pill.dart';
import '../common/sheet_title_bar.dart';
import '../common/side_insets.dart';
import '../common/status_chip.dart';
import '../common/tool_glyph.dart';
import '../plugins/seats/session_plugins_tab.dart';
import '../shell/adaptive/detail_panel_keys.dart';
import '../shell/adaptive/detail_sheet.dart';
import '../shell/adaptive/open_detail.dart';
import '../shell/page_frame.dart';
import '../terminal/terminal_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'conversation_panes.dart';
import 'session_tab.dart';

export 'session_tab.dart';

/// Where 对话详情 is drawn.
enum SessionDetailMode {
  /// A page of its own (phones).
  page,

  /// The column beside the chat (wide windows): no back key, the bar on the
  /// chat header's line, a key that folds the column away.
  panel,

  /// The two-height bottom sheet (medium windows).
  sheet,
}

/// Details use tools and prompts, not each changing assistant-text snapshot.
/// Compare the selected immutable items so same-length replacements still notify.
class _DetailItems<T extends ChatItem> {
  _DetailItems(Iterable<T> source) : items = List.unmodifiable(source);

  final List<T> items;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType && other is _DetailItems<T> && listEquals(items, other.items);

  @override
  int get hashCode => Object.hashAll(items);
}

/// Whether [items] show this conversation having sent out a subagent.
bool dispatchedSubagents(Iterable<ChatItem> items) =>
    items.whereType<ToolChatItem>().any((t) => toolKindOf(t) == ToolKind.agent);

/// The whole conversation's details (a detail page): the head carries the
/// title and a few figures, with a row of capsule tabs under it, swiped
/// between. The head fades out on scroll and the title moves into the bar.
///
/// On a phone it is a page, not a right-side drawer: a right-swipe drawer would
/// fight the conversation drawer's gesture on the left. Wider windows change
/// the form ([SessionDetailMode]), not the tabs or their content; all three
/// forms share one current tab ([sessionDetailTabProvider]). Always open it
/// through [open]. 子代理 shows once the conversation has dispatched subagents,
/// or when opened from a subagent entry.
class SessionDetailPage extends ConsumerStatefulWidget {
  const SessionDetailPage({super.key, required this.sessionId, this.initialTab, this.mode = SessionDetailMode.page});

  /// 对话详情 beside the chat.
  const SessionDetailPage.panel({super.key, required this.sessionId})
    : initialTab = null,
      mode = SessionDetailMode.panel;

  final String sessionId;

  /// Null: 轨迹 on a page; the shared tab in the sheet and the panel.
  final SessionTab? initialTab;
  final SessionDetailMode mode;

  static Route<void> route(String sessionId, {SessionTab initialTab = SessionTab.trajectory}) =>
      MaterialPageRoute<void>(
        builder: (_) => SessionDetailPage(sessionId: sessionId, initialTab: initialTab),
      );

  /// Opens 对话详情 in the window's form: the panel beside the chat (shown,
  /// or folded when [toggle] and it already shows), the wide sheet, or a
  /// page. [tab] picks the tab.
  static void open(BuildContext context, String sessionId, {SessionTab? tab, bool toggle = false}) =>
      openAdaptiveDetail(
        context,
        sessionId: sessionId,
        tab: tab,
        toggle: toggle,
        page: (_) => SessionDetailPage(sessionId: sessionId, initialTab: tab),
        sheet: (_) => SessionDetailPage(sessionId: sessionId, initialTab: tab, mode: SessionDetailMode.sheet),
      );

  @override
  ConsumerState<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends ConsumerState<SessionDetailPage> with TickerProviderStateMixin {
  static const _pageBarHeight = 56.0;
  static const _tabsHeight = 52.0;

  /// The tabs but 插件, decided when the page opens.
  late final List<SessionTab> _baseTabs;
  late List<SessionTab> _tabs;
  late TabController _controller;
  final _scroll = ScrollController();
  final _offset = ValueNotifier(0.0);
  final _heroKey = GlobalKey();

  /// Last measured hero height (after layout; never read during build).
  double _heroHeight = 120;

  SessionDetailMode get _mode => widget.mode;

  @override
  void initState() {
    super.initState();
    final items = ref.read(chatProvider(widget.sessionId)).items;
    final delegated = dispatchedSubagents(items) || ref.read(subagentLineageProvider(widget.sessionId)).isNotEmpty;
    final SessionTab initial =
        widget.initialTab ??
        (_mode == SessionDetailMode.page ? SessionTab.trajectory : ref.read(sessionDetailTabProvider));
    _baseTabs = [
      for (final tab in SessionTab.values)
        if (tab != SessionTab.plugins && (tab != SessionTab.subagents || delegated || initial == SessionTab.subagents))
          tab,
    ];
    final plugins = !ref.read(sessionPluginPlanProvider(widget.sessionId)).isEmpty;
    _tabs = [..._baseTabs, if (plugins) SessionTab.plugins];
    _controller = TabController(
      length: _tabs.length,
      vsync: this,
      initialIndex: _tabs.contains(initial) ? _tabs.indexOf(initial) : 0,
    )..addListener(_onTab);
    _scroll.addListener(() => _offset.value = _scroll.hasClients ? _scroll.offset : 0);
  }

  // One tab for every form: a sheet that folds into the panel, or a panel
  // opened again, comes back on the same one.
  void _onTab() {
    if (!mounted) return;
    ref.read(sessionDetailTabProvider.notifier).select(_tabs[_controller.index]);
  }

  /// 插件 comes and goes with the host's plugin tabs for the conversation;
  /// the tab on screen stays where it is.
  void _syncPluginsTab(bool plugins) {
    if (plugins == _tabs.contains(SessionTab.plugins)) return;
    final current = _tabs[_controller.index];
    final next = [..._baseTabs, if (plugins) SessionTab.plugins];
    final old = _controller..removeListener(_onTab);
    _tabs = next;
    _controller = TabController(
      length: next.length,
      vsync: this,
      initialIndex: next.contains(current) ? next.indexOf(current) : 0,
    )..addListener(_onTab);
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    _offset.dispose();
    super.dispose();
  }

  void _measureHero() {
    final box = _heroKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      _heroHeight = box.size.height.clamp(40.0, 400.0);
    }
  }

  void _openTerminal() => Navigator.of(context).push(TerminalPage.route(widget.sessionId));

  /// The page's bar: ‹ back, the title once the hero is gone, the terminal.
  Widget _pageBar(BuildContext context, String title) => SizedBox(
    height: _pageBarHeight,
    child: BackdropGroup(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            GlassIconButton(
              icon: AppIcons.back,
              tooltip: context.l10n.commonBack,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ValueListenableBuilder<double>(
                valueListenable: _offset,
                builder: (context, offset, child) {
                  // In as the hero is half gone, fully 20dp later.
                  final t = ((offset - _heroHeight * 0.4) / 20).clamp(0.0, 1.0);
                  return Opacity(
                    opacity: t,
                    child: Transform.translate(offset: Offset(0, 6 * (1 - t)), child: child),
                  );
                },
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Mirrors the back button: the title stays centred.
            GlassIconButton(icon: AppIcons.terminal, tooltip: context.l10n.hubTerminal, onPressed: _openTerminal),
          ],
        ),
      ),
    ),
  );

  /// The panel's bar, on the chat header's line: the panel's name where the
  /// hero's text starts, the terminal, and the key that folds the panel —
  /// on the window's corner, where the header's key brings it back.
  Widget _panelBar(BuildContext context, double height) => SizedBox(
    key: const ValueKey('panel-bar'),
    height: height,
    child: BackdropGroup(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  context.l10n.hubSessionDetails,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            const SizedBox(width: 8),
            GlassIconButton(icon: AppIcons.terminal, tooltip: context.l10n.hubTerminal, onPressed: _openTerminal),
            const SizedBox(width: 8),
            const DetailPanelCollapseKey(),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measureHero();
    });
    if (_mode != SessionDetailMode.page) {
      // Another entry (the progress strip, 全部功能) picked a tab.
      ref.listen(sessionDetailTabProvider, (_, tab) {
        final i = _tabs.indexOf(tab);
        if (i >= 0 && i != _controller.index) _controller.animateTo(i);
      });
    }
    _syncPluginsTab(!ref.watch(sessionPluginPlanProvider(widget.sessionId)).isEmpty);
    final theme = Theme.of(context);
    final surfaces = DshSurfaces.of(context);
    final padding = MediaQuery.paddingOf(context);
    final id = widget.sessionId;
    final title = ref.watch(chatProvider(id).select((s) => s.title?.trim() ?? ''));
    final shownTitle = title.isEmpty ? l10n.commonUntitledChat : title;
    final sheet = _mode == SessionDetailMode.sheet;
    // What content scrolls under: the page, or the sheet's own surface.
    final band = sheet ? surfaces.sheet.fallbackFill : surfaces.backdropTop;
    // The sheet's gutter is 20 (its title's); the page's and panel's 16.
    final gutter = sheet ? kSheetGutter : 16.0;
    // The page on a wide window (a phone on its side): hero, tabs and
    // content keep the reading column, centred; the bar's keys stay at the
    // edges, like every page's.
    final column = _mode == SessionDetailMode.page
        ? AppPage.sideFor(MediaQuery.sizeOf(context).width - 2 * sideInsetFor(padding))
        : 0.0;

    final barHeight = switch (_mode) {
      SessionDetailMode.page => _pageBarHeight,
      // On the chat header's line, whatever the text size.
      SessionDetailMode.panel => ChatHeader.barHeightOf(context),
      SessionDetailMode.sheet => 0.0,
    };
    final barTop = sheet ? 0.0 : padding.top + barHeight;
    final bar = switch (_mode) {
      SessionDetailMode.page => _pageBar(context, shownTitle),
      SessionDetailMode.panel => _panelBar(context, barHeight),
      SessionDetailMode.sheet => null,
    };

    final scroll = NestedScrollView(
      controller: _scroll,
      headerSliverBuilder: (context, _) => [
        if (bar != null)
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedBox(
              extent: barTop,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _offset,
                      builder: (context, offset, child) =>
                          Opacity(opacity: (offset / 24).clamp(0.0, 1.0), child: child),
                      child: _SolidTop(height: barTop, color: band),
                    ),
                  ),
                  Positioned(left: 0, right: 0, top: padding.top, child: bar),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: ValueListenableBuilder<double>(
            valueListenable: _offset,
            builder: (context, offset, child) => Opacity(
              opacity: (1 - offset / (_heroHeight * 0.6)).clamp(0.0, 1.0),
              alwaysIncludeSemantics: true,
              child: child,
            ),
            child: KeyedSubtree(
              key: _heroKey,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: column),
                child: SessionHero(
                  sessionId: id,
                  // The panel and the sheet are named in their bar; the hero
                  // keeps the figures.
                  title: _mode == SessionDetailMode.page ? shownTitle : null,
                  gutter: sheet ? kSheetGutter : 24,
                ),
              ),
            ),
          ),
        ),
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedBox(
            extent: _tabsHeight,
            child: ValueListenableBuilder<double>(
              valueListenable: _offset,
              builder: (context, offset, child) {
                // Continues the bar's band, then feathers out so
                // the strip has no hard bottom edge.
                final a = 0.96 * (offset / 24).clamp(0.0, 1.0);
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        band.withValues(alpha: band.a * a),
                        band.withValues(alpha: band.a * a),
                        band.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.7, 1],
                    ),
                  ),
                  child: child,
                );
              },
              child: Padding(
                padding: EdgeInsets.fromLTRB(gutter + column, 4, gutter + column, 12),
                child: GlassSegments(controller: _controller, labels: [for (final tab in _tabs) tab.label]),
              ),
            ),
          ),
        ),
      ],
      body: _FadeTop(
        child: Padding(
          // The tabs were drawn on the page's 16; the sheet's edge is 20.
          padding: EdgeInsets.symmetric(horizontal: gutter - 16 + column),
          child: TabBarView(
            controller: _controller,
            children: [for (final tab in _tabs) ConversationPane.ofTab(tab).build(id)],
          ),
        ),
      ),
    );

    switch (_mode) {
      case SessionDetailMode.page:
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: dshSystemOverlay(theme.brightness),
          child: AppBackdrop(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              // A phone on its side: clear of the cutout on both sides.
              body: SideSafeArea(child: scroll),
            ),
          ),
        );
      case SessionDetailMode.panel:
        // A column of the home screen: the shell paints the page behind it.
        return scroll;
      case SessionDetailMode.sheet:
        final drag = DetailSheetScope.maybeOf(context)?.dragArea;
        final titleBar = SheetTitleBar(
          l10n.hubSessionDetails,
          actions: [SheetIconButton(icon: AppIcons.terminal, tooltip: l10n.hubTerminal, onPressed: _openTerminal)],
        );
        return Column(
          children: [
            drag?.call(titleBar) ?? titleBar,
            Expanded(child: scroll),
          ],
        );
    }
  }
}

/// A fixed-height pinned header.
class _PinnedBox extends SliverPersistentHeaderDelegate {
  _PinnedBox({required this.extent, required this.child});

  final double extent;
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) => SizedBox.expand(child: child);

  @override
  bool shouldRebuild(_PinnedBox old) => old.extent != extent || old.child != child;
}

/// The page colour behind the bar once the hero slides under it: solid
/// enough to read the bar over, and continuous with the tabs strip below.
class _SolidTop extends StatelessWidget {
  const _SolidTop({required this.height, required this.color});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ColoredBox(
      color: color.withValues(alpha: color.a * 0.96),
      child: SizedBox(height: height),
    ),
  );
}

/// Content fades out over its top 12dp instead of being cut by the tabs.
class _FadeTop extends StatelessWidget {
  const _FadeTop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (rect) => LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: const [Color(0x00000000), Color(0xFF000000)],
      stops: [0, (12 / rect.height).clamp(0.0, 1.0)],
    ).createShader(rect),
    child: child,
  );
}

/// The page head: the conversation's title (two lines at most), how many
/// rounds and whether one runs, then 用时 / 步骤 / 改动文件. Without a [title]
/// (the panel and the sheet, named in their bar) the rounds line leads.
class SessionHero extends ConsumerWidget {
  const SessionHero({super.key, required this.sessionId, required this.title, this.gutter = 24});

  final String sessionId;
  final String? title;

  /// Where the text starts.
  final double gutter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final turns = ref.watch(chatProvider(sessionId).select((s) => s.turns));
    final tools = ref
        .watch(chatProvider(sessionId).select((s) => _DetailItems(s.items.whereType<ToolChatItem>())))
        .items;
    final skew = ref.watch(chatProvider(sessionId).select((s) => s.clockSkew));
    final running = turns.where((t) => t.running).lastOrNull;
    final finished = turns.fold(Duration.zero, (sum, t) => sum + (t.duration ?? Duration.zero));
    final steps = turns.fold(0, (sum, t) => sum + t.steps);
    final files = sessionChangesOf(tools).length;
    final subtitle = turns.isEmpty
        ? l10n.hubSessionNoTurns
        : running == null
        ? l10n.hubSessionTurns(turns.length)
        : l10n.hubSessionTurnsRunning(turns.length);

    Widget hero(Duration total) {
      final stats = [
        (formatClock(total), l10n.hubSessionElapsed),
        ('$steps', l10n.hubSessionSteps),
        ('$files', l10n.hubSessionChangedFiles),
      ];
      if (title case final title?) {
        return PageHero(
          title: title,
          subtitle: Text(subtitle),
          stats: stats,
          padding: EdgeInsets.fromLTRB(gutter, 4, gutter, 20),
        );
      }
      final theme = Theme.of(context);
      return Padding(
        padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: DshColors.of(context).textTertiary),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, (value, label)) in stats.indexed) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(
                    child: HeroStat(value: value, label: label),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }

    if (running == null) return hero(finished);
    return LiveElapsed(
      since: running.start,
      skew: skew,
      builder: (context, elapsed) => hero(finished + (elapsed ?? Duration.zero)),
    );
  }
}

/// Capsule tabs with the [SegmentedPill] look (track, thumb, labels), but the
/// thumb follows the [TabController]'s swipe progress, moving with the pages.
class GlassSegments extends StatelessWidget {
  const GlassSegments({super.key, required this.controller, required this.labels});

  final TabController controller;
  final List<String> labels;

  void _select(int i) {
    if (controller.index != i) HapticFeedback.selectionClick();
    controller.animateTo(i);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final animation = controller.animation!;
    const inset = SegmentedPill.inset;
    final track = dark ? Colors.white.withValues(alpha: 0.07) : colors.onSurface.withValues(alpha: 0.06);
    final thumb = dark ? Colors.white.withValues(alpha: 0.2) : Colors.white;
    final style = SegmentedPill.labelStyle(context);
    return DecoratedBox(
      decoration: ShapeDecoration(color: track, shape: const StadiumBorder()),
      child: SizedBox(
        height: 36,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final segment = (constraints.maxWidth - 2 * inset) / labels.length;
            return AnimatedBuilder(
              animation: animation,
              builder: (context, _) {
                final at = animation.value;
                return Stack(
                  children: [
                    Positioned(
                      left: inset + at * segment,
                      top: inset,
                      bottom: inset,
                      width: segment,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: thumb,
                          shape: const StadiumBorder(),
                          shadows: dark
                              ? null
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.08),
                                    blurRadius: 6,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: inset),
                      child: Row(
                        children: [
                          for (final (i, label) in labels.indexed)
                            Expanded(
                              child: Semantics(
                                button: true,
                                selected: (at - i).abs() < 0.5,
                                inMutuallyExclusiveGroup: true,
                                label: label,
                                excludeSemantics: true,
                                // A screen reader's tap, as the finger's below.
                                onTap: () => _select(i),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _select(i),
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          label,
                                          maxLines: 1,
                                          softWrap: false,
                                          style: style.copyWith(
                                            fontWeight: (at - i).abs() < 0.5 ? FontWeight.w600 : FontWeight.w500,
                                            color: Color.lerp(
                                              colors.onSurface,
                                              colors.onSurfaceVariant,
                                              (at - i).abs().clamp(0.0, 1.0),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Shared

/// A tab's empty state: a graphic and a sentence (plus a line of detail),
/// centred a little above the middle.
class _Empty extends StatelessWidget {
  const _Empty(this.title, {this.icon = AppIcons.empty, this.tile, this.message});

  final String title;
  final String? message;
  final IconData icon;

  /// The feature's own graphic instead of [icon].
  final FeatureKind? tile;

  @override
  Widget build(BuildContext context) => Align(
    alignment: const Alignment(0, -0.5),
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: EmptyView(
        icon: icon,
        art: switch (tile) {
          final kind? => FeatureTile(kind, size: FeatureTile.empty),
          null => null,
        },
        title: title,
        message: message,
      ),
    ),
  );
}

/// The footnote at the end of a tab (where the data comes from, what is
/// missing), on the cards' content edge.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
    ),
  );
}

EdgeInsets _listPadding(BuildContext context) =>
    EdgeInsets.fromLTRB(0, 4, 0, MediaQuery.paddingOf(context).bottom + 24);

// -----------------------------------------------------------------------------
// 轨迹 (trajectory)

/// One card per round, newest first; opened, it shows the same rows as the
/// 本轮轨迹 sheet.
class TrajectoryTab extends ConsumerWidget {
  const TrajectoryTab({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final turns = ref.watch(chatProvider(sessionId).select((s) => s.turns));
    final items = ref
        .watch(
          chatProvider(sessionId)
              .select((s) => _DetailItems(s.items.where((item) => item is ToolChatItem || item is UserChatItem))),
        )
        .items;
    final more = ref.watch(chatProvider(sessionId).select((s) => (s.hasMoreHistory, s.loadingOlder)));
    final skew = ref.watch(chatProvider(sessionId).select((s) => s.clockSkew));
    if (turns.isEmpty && !more.$1) {
      return _Empty(l10n.hubSessionNoTurns, icon: AppIcons.trajectory, message: l10n.hubSessionTrajectoryHint);
    }
    final tools = toolsById(items);
    final prompts = [
      for (final item in items)
        if (item is UserChatItem) item,
    ];
    String? promptOf(TurnTrace trace) {
      for (final p in prompts) {
        if (p.seq >= trace.startSeq && (trace.endSeq == null || p.seq <= trace.endSeq!)) {
          return withoutAppNotes(p.text);
        }
      }
      return null;
    }

    final ordered = turns.reversed.toList();
    return ListView(
      padding: _listPadding(context),
      children: [
        for (final (i, trace) in ordered.indexed)
          FadeSlideIn(
            key: ValueKey(trace.startSeq),
            index: i,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _TurnCard(
                sessionId: sessionId,
                trace: trace,
                prompt: promptOf(trace),
                tools: tools,
                skew: skew,
                initiallyExpanded: i == 0,
              ),
            ),
          ),
        if (more.$1)
          Center(
            child: more.$2
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 1.8)),
                  )
                : TextButton(
                    onPressed: () => ref.read(chatProvider(sessionId).notifier).loadOlder(),
                    child: Text(l10n.hubSessionLoadEarlier),
                  ),
          ),
      ],
    );
  }
}

class _TurnCard extends StatefulWidget {
  const _TurnCard({
    required this.sessionId,
    required this.trace,
    required this.tools,
    required this.skew,
    this.prompt,
    this.initiallyExpanded = false,
  });

  final String sessionId;
  final TurnTrace trace;
  final String? prompt;
  final Map<String, ToolChatItem> tools;
  final Duration skew;
  final bool initiallyExpanded;

  @override
  State<_TurnCard> createState() => _TurnCardState();
}

class _TurnCardState extends State<_TurnCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final trace = widget.trace;
    final prompt = widget.prompt?.trim().replaceAll(RegExp(r'\s+'), ' ');
    final facts = [
      if (trace.steps > 0) l10n.hubSessionStepCount(trace.steps),
      if (!trace.usage.isEmpty) '${formatTokens(trace.usage.total)} tokens',
      ?turnSpeedLabel(trace),
      if (trace.waitTime > Duration.zero) l10n.hubSessionWaitTime(formatSpan(trace.waitTime)),
      ?turnCostLabel(trace),
    ];
    final (String? state, StatusTone? tone) = trace.running
        ? (l10n.commonInProgress, StatusTone.busy)
        : switch (trace.endReason?.kind) {
            'aborted' => (l10n.commonStopped, StatusTone.idle),
            'error' => (l10n.hubSessionError, StatusTone.error),
            'interrupted' => (l10n.hubSessionInterrupted, StatusTone.warn),
            'max-tokens' => (l10n.hubSessionOutputLimit, StatusTone.warn),
            _ => (null, null),
          };

    Widget duration(Duration? elapsed) => Text(
      trace.running ? formatClock(elapsed ?? Duration.zero) : formatSpan(trace.duration!),
      style: AppType.tabular(theme.textTheme.labelMedium!.copyWith(color: colors.onSurfaceVariant)),
    );

    Widget list(Duration? elapsed) => TrajectoryList(
      trace: trace,
      total: trace.duration ?? elapsed ?? Duration.zero,
      tools: widget.tools,
      onOpen: (span) =>
          Navigator.of(context).push(StepDetailPage.route(sessionId: widget.sessionId, turn: trace.turn, span: span)),
    );

    Widget live(Widget Function(Duration?) child) => trace.running
        ? LiveElapsed(since: trace.start, skew: widget.skew, builder: (context, elapsed) => child(elapsed))
        : child(null);

    return GlassSurface(
      tier: GlassTier.card,
      borderRadius: AppShape.radiusLg,
      child: Material(
        type: MaterialType.transparency,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              expanded: _expanded,
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            l10n.hubSessionTurn(trace.turn),
                            style: AppType.tabular(theme.textTheme.labelMedium!.copyWith(color: dsh.textTertiary)),
                          ),
                          if (state != null && tone != null) ...[
                            const SizedBox(width: 8),
                            StatusChip(tone: tone, label: state),
                          ],
                          const Spacer(),
                          live(duration),
                          const SizedBox(width: 2),
                          AnimatedRotation(
                            turns: _expanded ? 0.5 : 0,
                            duration: AppMotion.of(context, AppMotion.collapse),
                            curve: AppMotion.collapseCurve,
                            child: Icon(AppIcons.expand, size: 18, color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                      if (prompt != null && prompt.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          prompt,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontSize: 15,
                            height: 1.5,
                            color: colors.onSurface,
                          ),
                        ),
                      ],
                      if (facts.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          facts.join(' · '),
                          style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: dsh.textTertiary)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            ExpandReveal(
              open: _expanded,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Divider(height: 0.5, thickness: 0.5, color: colors.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  const SizedBox(height: 4),
                  live(list),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 改动 (changes)

/// Every file the conversation changed: one merged diff per file, tagged with
/// the round that last changed it.
class ChangesTab extends ConsumerStatefulWidget {
  const ChangesTab({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<ChangesTab> createState() => _ChangesTabState();
}

class _ChangesTabState extends ConsumerState<ChangesTab> {
  Object? _inputs;
  List<FileChange> _files = const [];
  Map<String, int> _lastTurn = const {};

  void _derive(List<ToolChatItem> tools, List<TurnTrace> turns) {
    final inputs = (tools, turns);
    if (identical(_inputs, inputs) || _inputs == inputs) return;
    _inputs = inputs;
    _files = sessionChangesOf(tools);
    final turnOf = <String, int>{
      for (final trace in turns)
        for (final span in trace.spans)
          if (span.callId != null) span.callId!: trace.turn,
    };
    _lastTurn = {for (final file in _files) file.shownPath: ?turnOf[file.lastCallId]};
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final tools = ref
        .watch(chatProvider(widget.sessionId).select((s) => _DetailItems(s.items.whereType<ToolChatItem>())))
        .items;
    final turns = ref.watch(chatProvider(widget.sessionId).select((s) => s.turns));
    _derive(tools, turns);
    final files = _files;
    if (files.isEmpty) {
      return _Empty(l10n.hubSessionNoChanges, icon: AppIcons.diff, message: l10n.hubSessionShellChangesHint);
    }
    final added = files.fold(0, (sum, f) => sum + f.added);
    final removed = files.fold(0, (sum, f) => sum + f.removed);
    return ListView(
      padding: _listPadding(context),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Row(
            children: [
              Text(
                l10n.hubSessionFileCount(files.length),
                style: theme.textTheme.labelLarge?.copyWith(color: dsh.textTertiary),
              ),
              const Spacer(),
              DiffCounts(added: added, removed: removed),
            ],
          ),
        ),
        ListPageCard(
          children: [
            for (final (i, file) in files.indexed)
              FadeSlideIn(
                index: i,
                child: ListPageRow(
                  icon: file.created ? AppIcons.fileNew : AppIcons.document,
                  iconColor: file.created ? dsh.success : null,
                  title: file.fileName,
                  subtitle: [
                    if (file.directory.isNotEmpty) file.directory,
                    if (_lastTurn[file.shownPath] case final turn?) l10n.hubSessionTurn(turn),
                    if (file.edits > 1) l10n.hubSessionEditCount(file.edits),
                  ].join(' · '),
                  trailing: DiffCounts(added: file.added, removed: file.removed),
                  chevron: true,
                  onTap: () =>
                      Navigator.of(context)
                          .push(ChangeDiffPage.route(files, initialIndex: i, title: l10n.hubSessionChanges)),
                ),
              ),
          ],
        ),
        _Note(l10n.hubSessionChangesNote),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// 进度 (progress)

/// The goal, plan mode and the todo list.
class ProgressTab extends ConsumerWidget {
  const ProgressTab({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final panels = ref.watch(sessionPanelsProvider(sessionId));
    final logged = ref.watch(chatProvider(sessionId).select((s) => s.todos));
    final todos = panels.todos ?? logged ?? const <TodoItem>[];
    final goal = panels.goal;
    if (goal == null && todos.isEmpty && !panels.planActive) {
      return _Empty(l10n.hubSessionNoGoal, icon: AppIcons.todo, message: l10n.hubSessionGoalHint);
    }
    final done = todos.where((t) => t.status == 'completed').length;
    final (goalIcon, goalColor, goalState) = switch (goal?.phase) {
      'complete' => (AppIcons.success, dsh.success, l10n.commonCompleted),
      'blocked' => (
        AppIcons.error,
        dsh.warning,
        goal?.blockedReason == null ? l10n.hubSessionBlocked : l10n.hubSessionBlockedReason(goal!.blockedReason!),
      ),
      'paused' => (AppIcons.paused, colors.onSurfaceVariant, l10n.commonPaused),
      'active' => (AppIcons.goal, colors.primary, l10n.commonInProgress),
      final other => (AppIcons.goal, colors.primary, other ?? ''),
    };
    final sections = <Widget>[
      if (goal != null)
        ListPageCard(
          title: l10n.hubSessionGoal,
          children: [
            _TextBlock(
              child: Text(goal.objective, style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.6)),
            ),
            ListPageRow(
              icon: goalIcon,
              iconColor: goalColor,
              title: goalState,
              meta: goal.maxRounds == null
                  ? l10n.hubSessionTurn(goal.roundsStarted)
                  : l10n.hubSessionTurnOf(goal.roundsStarted, goal.maxRounds!),
            ),
          ],
        ),
      if (panels.planActive || panels.planPending)
        ListPageCard(
          children: [
            ListPageRow(
              icon: AppIcons.planMode,
              iconColor: colors.primary,
              title: panels.planActive ? l10n.hubSessionPlanMode : l10n.hubSessionPlanSwitching,
              subtitle: panels.planActive ? l10n.hubSessionPlanHint : null,
            ),
          ],
        ),
      if (todos.isNotEmpty)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Row(
                children: [
                  Text(l10n.hubSessionTodos, style: theme.textTheme.labelLarge?.copyWith(color: dsh.textTertiary)),
                  const Spacer(),
                  TodoProgress(done: done, total: todos.length, barWidth: 64, showLabel: false),
                ],
              ),
            ),
            ListPageCard(children: [for (final todo in todos) _TodoRow(todo: todo)]),
          ],
        ),
    ];
    return ListView(
      padding: _listPadding(context),
      children: [
        for (final (i, section) in sections.indexed) ...[
          if (i > 0) const SizedBox(height: 24),
          FadeSlideIn(index: i, child: section),
        ],
      ],
    );
  }
}

/// Full-width text block inside a card, on the rows' 16 inset.
class _TextBlock extends StatelessWidget {
  const _TextBlock({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: SizedBox(width: double.infinity, child: child),
  );
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.todo});

  final TodoItem todo;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final (IconData icon, Color color) = switch (todo.status) {
      'completed' => (AppIcons.success, dsh.success),
      'in_progress' => (AppIcons.inProgress, colors.primary),
      _ => (AppIcons.pending, dsh.textTertiary),
    };
    final done = todo.status == 'completed';
    return Semantics(
      label: l10n.hubSessionTodoSemantics(todo.content, switch (todo.status) {
        'completed' => l10n.commonCompleted,
        'in_progress' => l10n.commonInProgress,
        _ => l10n.hubSessionNotStarted,
      }),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: ListPageRow.glyphSlot,
              height: 22,
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: ListPageRow.gap),
            Expanded(
              child: Text(
                todo.content,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontSize: 15,
                  height: 1.45,
                  color: done ? dsh.textTertiary : colors.onSurface,
                  fontWeight: todo.status == 'in_progress' ? FontWeight.w600 : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 上下文 (context)

/// The context window and this conversation's tokens (the usage sheet's
/// data), plus the usage of each round.
class ContextTab extends ConsumerWidget {
  const ContextTab({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final usage = ref.watch(sessionUsageProvider(sessionId));
    final model = ref.watch(chatProvider(sessionId).select((s) => s.model));
    final turns = ref.watch(chatProvider(sessionId).select((s) => s.turns));
    final pricing = model == null ? null : knownPricing['${model.provider}/${model.model}'];
    final recent = [
      for (final trace in turns.reversed)
        if (!trace.usage.isEmpty) trace,
    ].take(12).toList();
    final peak = recent.fold(0, (m, t) => t.usage.total > m ? t.usage.total : m);
    final subagents = ref
        .watch(
          chatProvider(sessionId).select(
            (s) => _DetailItems(s.items.whereType<ToolChatItem>().where((item) => toolKindOf(item) == ToolKind.agent)),
          ),
        )
        .items
        .length;
    final speed = speedFigure(tracesTokensPerSecond(turns));
    // A turn's own line of detail: how long it took, how fast it decoded.
    String? metaOf(TurnTrace trace) {
      final parts = [if (trace.duration case final duration?) formatSpan(duration), ?turnSpeedLabel(trace)];
      return parts.isEmpty ? null : parts.join(' · ');
    }

    return ListView(
      padding: _listPadding(context),
      children: [
        if (speed != null || subagents > 0)
          ListPageCard(
            margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Row(
                  children: [
                    if (speed != null)
                      Expanded(
                        child: HeroStat(value: speed, label: l10n.hubSessionTokenSpeed),
                      ),
                    if (subagents > 0)
                      Expanded(
                        child: HeroStat(value: '$subagents', label: l10n.hubTabSubagents),
                      ),
                  ],
                ),
              ),
            ],
          ),
        SessionUsageSections(usage: usage, pricing: pricing),
        if (recent.isNotEmpty)
          ListPageCard(
            title: l10n.hubSessionTurnUsage,
            // Same rhythm as the usage groups above (SheetGroup: 6 + 6).
            margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            children: [
              for (final trace in recent)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 52,
                            child: Text(
                              l10n.hubSessionTurn(trace.turn),
                              style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: dsh.textTertiary)),
                            ),
                          ),
                          Expanded(
                            child: TimelineBar(
                              start: Duration.zero,
                              duration: Duration(milliseconds: trace.usage.total),
                              total: Duration(milliseconds: peak <= 0 ? 1 : peak),
                              color: theme.colorScheme.primary.withValues(alpha: 0.75),
                              height: 6,
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 52,
                            child: Text(
                              formatTokens(trace.usage.total),
                              textAlign: TextAlign.right,
                              style: AppType.tabular(
                                theme.textTheme.bodySmall!.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 64,
                            child: Text(
                              trace.usage.cacheHitRate == null
                                  ? ''
                                  : l10n.hubSessionCacheHit(formatPercent(trace.usage.cacheHitRate!)),
                              textAlign: TextAlign.right,
                              style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: dsh.textTertiary)),
                            ),
                          ),
                        ],
                      ),
                      if (metaOf(trace) case final meta?)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            meta,
                            style: AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: dsh.textTertiary)),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// 子代理 (subagents)

/// This conversation's subagents: the lineage first (who dispatched whom and
/// what each is doing; a row opens its own conversation, where it can be
/// continued), then the dispatch log (what was asked, how long it took, how it
/// went).
class SubagentsTab extends ConsumerWidget {
  const SubagentsTab({super.key, required this.sessionId});

  final String sessionId;

  void _open(BuildContext context, WidgetRef ref, SubagentNode node) {
    selectSubagent(ref, node.address);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    final nodes = ref.watch(subagentLineageProvider(sessionId));
    final calls = ref
        .watch(
          chatProvider(sessionId).select(
            (s) => _DetailItems(s.items.whereType<ToolChatItem>().where((item) => toolKindOf(item) == ToolKind.agent)),
          ),
        )
        .items
        .reversed
        .toList();
    final turns = ref.watch(chatProvider(sessionId).select((s) => s.turns));
    if (calls.isEmpty && nodes.isEmpty) {
      return _Empty(l10n.hubSessionNoSubagents, tile: FeatureKind.subagents);
    }
    TraceSpan? spanOf(String callId) {
      for (final trace in turns) {
        for (final span in trace.spans) {
          if (span.callId == callId && span.kind != TraceKind.approval) {
            return span;
          }
        }
      }
      return null;
    }

    int? turnOf(String callId) {
      for (final trace in turns) {
        if (trace.spans.any((s) => s.callId == callId)) return trace.turn;
      }
      return null;
    }

    return ListView(
      padding: _listPadding(context),
      children: [
        if (nodes.isNotEmpty) ...[
          SubagentTreeCard(title: lineageTitle(nodes), nodes: nodes, onOpen: (node) => _open(context, ref, node)),
          if (calls.isNotEmpty) const SizedBox(height: 24),
        ],
        if (calls.isNotEmpty)
          ListPageCard(
            title: nodes.isEmpty ? null : l10n.hubSessionDelegations,
            children: [
              for (final (i, call) in calls.indexed)
                FadeSlideIn(
                  index: i,
                  child: Builder(
                    builder: (context) {
                      final view = viewOfSpan(
                        TraceSpan(
                          kind: TraceKind.tool,
                          step: 0,
                          seq: call.seq ?? 0,
                          start: DateTime(0),
                          callId: call.callId,
                          toolName: call.name,
                          arguments: call.arguments,
                        ),
                        call,
                      );
                      final span = spanOf(call.callId);
                      final turn = turnOf(call.callId);
                      final status = switch (call.status) {
                        _ when view.phoneResult != null => view.phoneResult!.word,
                        ToolStatus.succeeded => l10n.commonCompleted,
                        ToolStatus.failed => l10n.commonFailed,
                        ToolStatus.cancelled => l10n.commonCancelled,
                        ToolStatus.denied => l10n.commonDeclined,
                        _ => l10n.commonInProgress,
                      };
                      return ListPageRow(
                        leading: ToolGlyph(name: call.name, size: 24),
                        title: view.summary.isEmpty ? view.verb : view.summary,
                        subtitle: [
                          view.verb,
                          status,
                          if (span?.duration case final d?) formatSpan(d),
                          if (turn != null) l10n.hubSessionTurn(turn),
                        ].join(' · '),
                        subtitleColor: call.status == ToolStatus.failed && (view.phoneResult?.isFault ?? true)
                            ? dsh.danger
                            : null,
                        chevron: span != null && turn != null,
                        onTap: span == null || turn == null
                            ? null
                            : () =>
                                  Navigator.of(context)
                                      .push(StepDetailPage.route(sessionId: sessionId, turn: turn, span: span)),
                      );
                    },
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
