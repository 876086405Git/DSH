import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../common/ui_trace.dart';
import '../common/side_insets.dart';
import '../settings/index/spot_anchor.dart' show seekSpot;
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Frame for every secondary page (settings, engine, remote, diagnostics…).
///
/// No app bar slab. A floating glass back button sits top-left, the
/// page title is a large headline at the top of the content (or a [hero] header
/// on detail pages). Scrolling is continuous, system style: the headline fades as
/// it slides under the bar while a compact title rises into the bar. A soft fade
/// at the top keeps scrolled text from running naked under the status bar.
///
/// Pushed with a plain `MaterialPageRoute`, the page gets the app-wide push
/// transition and back gesture from the theme (`AppPageTransitionsBuilder`).
///
/// On a window wider than [contentWidth] (tablets, open foldables) the
/// headline and the content keep that width, centred; the bar's keys stay on
/// the window's edges.
class AppPage extends StatefulWidget {
  const AppPage({
    super.key,
    required this.title,
    this.subtitle,
    this.hero,
    this.slivers = const [],
    this.actions = const [],
    this.showLargeTitle = true,
    this.padBottom = true,
    this.solidBar = true,
    this.leading,
  });

  final String title;

  /// Optional line under the large title (bodyMedium, secondary colour).
  final Widget? subtitle;

  /// Detail-page header (usually a `PageHero`) shown instead of the large title
  /// and [subtitle]. It fades out as the page scrolls, and [title] moves into
  /// the bar; fully faded, its tickers are muted.
  final Widget? hero;

  /// Page content. Use [AppPage.list] for a plain column of boxes.
  final List<Widget> slivers;

  /// Trailing glass buttons in the bar.
  final List<Widget> actions;

  final bool showLargeTitle;
  final bool padBottom;

  /// Once content scrolls under the bar, the page's own backdrop is opaque
  /// behind it ([BackdropVeil.top], feathered below) so nothing reads through
  /// the bar title. False uses the shared [TopFade] instead.
  final bool solidBar;

  /// Takes the back button's seat (a page that is the app's home, with
  /// nothing to go back to: 网页模式's native handle).
  final Widget? leading;

  /// The widest the page's column gets: the chat's reading width.
  static const contentWidth = AppSpace.readingWidth;

  /// Space on each side of the centred column in a window [width] wide; at
  /// least [inset], the side inset of a phone on its side ([sideInsetOf]).
  static double sideFor(double width, {double inset = 0}) =>
      math.max(inset, (width - contentWidth) / 2).floorToDouble();

  /// Convenience: [children] become one padded sliver list.
  static Widget list({
    Key? key,
    required String title,
    Widget? subtitle,
    required List<Widget> children,
    List<Widget> actions = const [],
    bool solidBar = true,
  }) => AppPage(
    key: key,
    title: title,
    subtitle: subtitle,
    actions: actions,
    solidBar: solidBar,
    slivers: [SliverList.list(children: children)],
  );

  @override
  State<AppPage> createState() => _AppPageState();
}

class _AppPageState extends State<AppPage> {
  final _controller = ScrollController();

  /// Scroll offset; the header fade, the bar title and the top fade all follow
  /// it continuously (no threshold flips).
  final _offset = ValueNotifier(0.0);

  /// The large title or hero, measured so the hand-off to the bar title lands
  /// when the headline is actually under the bar.
  final _headerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => _offset.value = _controller.hasClients ? _controller.offset : 0.0);
    // Opened for one row (a search result, a row link): bring it into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(seekSpot(context, _controller));
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _offset.dispose();
    super.dispose();
  }

  bool get _hasHeader => widget.hero != null || widget.showLargeTitle;

  /// Last measured header height (after layout; never read during build).
  double _headerHeight = 56;

  void _measureHeader() {
    final box = _headerKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) _headerHeight = box.size.height.clamp(40.0, 400.0);
  }

  /// Header opacity: gone once ~60% of it has slid under the bar.
  double _headerOpacity(double offset) => (1 - offset / (_headerHeight * 0.6)).clamp(0.0, 1.0);

  /// Bar title: starts as the header is half gone, fully in 20dp later.
  double _barTitle(double offset) {
    if (!_hasHeader) return 1;
    return ((offset - _headerHeight * 0.4) / 20).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measureHeader();
    });
    final theme = Theme.of(context);
    final padding = MediaQuery.paddingOf(context);
    const barHeight = 56.0;
    final top = padding.top + barHeight;
    // Wide windows: one centred column (zero on phones). A phone on its side
    // keeps the column and the bar's keys clear of the cutout or navigation
    // bar, on both sides alike.
    final inset = sideInsetFor(padding);
    final side = EdgeInsets.symmetric(horizontal: AppPage.sideFor(MediaQuery.sizeOf(context).width, inset: inset));
    Widget? header;
    if (widget.hero case final hero?) {
      header = hero;
    } else if (widget.showLargeTitle) {
      header = Padding(
        padding: const EdgeInsets.fromLTRB(24, 6, 24, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(header: true, namesRoute: true, child: Text(widget.title, style: theme.textTheme.headlineLarge)),
            if (widget.subtitle case final subtitle?) ...[
              const SizedBox(height: 4),
              DefaultTextStyle.merge(
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                child: subtitle,
              ),
            ],
          ],
        ),
      );
    }
    final page = AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(theme.brightness),
      child: AppBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              CustomScrollView(
                controller: _controller,
                physics: AppMotion.scrollPhysics(context),
                slivers: [
                  SliverToBoxAdapter(child: SizedBox(height: top)),
                  if (header != null)
                    SliverPadding(
                      padding: side,
                      sliver: SliverToBoxAdapter(
                        child: ValueListenableBuilder<double>(
                          valueListenable: _offset,
                          // Pulled past the top (only the fluid tier's lists go there), the
                          // headline swells a little with the pull. Faded out, its
                          // animations (the engine's status ring) hold still.
                          builder: (context, offset, child) => Opacity(
                            opacity: _headerOpacity(offset),
                            alwaysIncludeSemantics: true,
                            child: TickerMode(
                              enabled: _headerOpacity(offset) > 0,
                              child: Transform.scale(
                                scale: 1 + (-offset / 900).clamp(0.0, 0.1),
                                alignment: AlignmentDirectional.topStart,
                                child: child,
                              ),
                            ),
                          ),
                          child: KeyedSubtree(key: _headerKey, child: header),
                        ),
                      ),
                    ),
                  for (final sliver in widget.slivers) SliverPadding(padding: side, sliver: sliver),
                  if (widget.padBottom) SliverToBoxAdapter(child: SizedBox(height: padding.bottom + 32)),
                ],
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                // The veil paints the page's own backdrop, so it spans the page.
                bottom: widget.solidBar ? 0 : null,
                child: ValueListenableBuilder<double>(
                  valueListenable: _offset,
                  // Only once content is under the bar: at rest it would just
                  // tint the glow.
                  builder: (context, offset, child) => Opacity(opacity: (offset / 24).clamp(0.0, 1.0), child: child),
                  child: widget.solidBar ? BackdropVeil.top(height: top, feather: 12) : TopFade(height: top + 12),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: padding.top,
                height: barHeight,
                child: BackdropGroup(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12 + inset),
                    child: NavigationToolbar(
                      centerMiddle: true,
                      middleSpacing: 8,
                      leading: Center(
                        widthFactor: 1,
                        child:
                            widget.leading ??
                            GlassIconButton(
                              icon: AppIcons.back,
                              tooltip: l10n.commonBack,
                              onPressed: () => Navigator.of(context).maybePop(),
                            ),
                      ),
                      middle: ValueListenableBuilder<double>(
                        valueListenable: _offset,
                        builder: (context, offset, child) {
                          final t = _barTitle(offset);
                          return Opacity(
                            opacity: t,
                            child: Transform.translate(offset: Offset(0, 6 * (1 - t)), child: child),
                          );
                        },
                        child: Semantics(
                          header: !_hasHeader,
                          child: Text(
                            widget.title,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                      ),
                      trailing: widget.actions.isEmpty
                          ? const SizedBox(width: 44)
                          : Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: widget.actions),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return UiTrace(scope: 'page', child: page);
  }
}

/// 44dp round chrome-glass button (top bars), 22dp glyph, with press feedback.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.grouped = true,
    this.tier = GlassTier.chrome,
    this.size = 44,
    this.iconSize = 22,
    this.badge,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool grouped;

  /// On glass already (the drawer), [GlassTier.pill]: a blur over a blur shows bands.
  final GlassTier tier;
  final double size;

  /// The glyph in it; smaller buttons in a page's own chrome shrink it.
  final double iconSize;

  /// Small widget pinned to the top-right corner (e.g. a status dot).
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    Widget button = SizedBox.square(
      dimension: size,
      child: GlassSurface(
        tier: tier,
        circle: true,
        grouped: grouped,
        onTap: onPressed,
        child: Center(
          child: Icon(icon, size: iconSize, color: enabled ? scheme.onSurface : DshColors.of(context).textDisabled),
        ),
      ),
    );
    if (badge case final badge?) {
      button = Stack(
        clipBehavior: Clip.none,
        children: [
          button,
          Positioned(top: 4, right: 4, child: badge),
        ],
      );
    }
    if (tooltip case final tip?) button = Tooltip(message: tip, child: button);
    return Semantics(button: true, enabled: enabled, label: tooltip, child: button);
  }
}

/// A short eyebrow above a group of cards when [SheetGroup.title] doesn't fit.
class PageSectionLabel extends StatelessWidget {
  const PageSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Semantics(
        header: true,
        child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ),
    );
  }
}
