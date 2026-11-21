// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../links/app_links.dart';
import '../../pets/overlay_channel.dart' show petOverlayChannelProvider;
import '../../pets/pet_overlay_bridge.dart';
import '../../state/adaptive_layout_state.dart';
import '../../state/android_features.dart';
import '../../state/drawer_view_state.dart' show drawerSelectionProvider;
import '../../state/quick_panel_state.dart';
import '../../state/sessions_state.dart' show currentSessionProvider;
import '../bots/bot_alerts.dart';
import '../chat/chat_screen.dart';
import '../chat/composer_toast.dart' show composerToastGap;
import '../engine/engine_screen.dart';
import '../engine/reset_outcome.dart';
import '../features/all_features_page.dart';
import '../forum/forum_link_host.dart';
import '../notify/background_net_host.dart';
import '../notify/background_pause_host.dart';
import '../notify/chat_alert_host.dart';
import '../notify/voice_model_host.dart';
import '../plugins/plugins_screen.dart';
import '../pets/pet_settings_page.dart';
import '../phone/phone_stop_watcher.dart';
import '../phone/system_actions_host.dart';
import '../remote/host_switcher.dart' show showHostSheet;
import '../remote/remote_screen.dart';
import '../safe_mode/safe_mode_notice_listener.dart';
import '../session/session_detail_page.dart';
import '../settings/search/settings_search_page.dart';
import '../settings/settings_screen.dart';
import '../share_code/share_code_host.dart';
import '../tavern/tavern_intake.dart';
import '../star/star_prompt_host.dart';
import '../theme/theme.dart';
import '../update/update_launch_check.dart';
import '../wallpaper/wallpaper_backdrop.dart';
import '../web/dsh_web_launcher.dart';
import 'adaptive/adaptive_layout.dart';
import 'adaptive/adaptive_rail.dart';
import 'adaptive/adaptive_scaffold.dart';
import 'drawer_drag.dart';
import 'quick_panel.dart';
import 'session_search_page.dart' show showSessionSearch;
import 'sessions_drawer.dart';
import 'system_entry_host.dart';

/// Home: the chat screen, with the sessions drawer pulled over it from the left.
///
/// The drawer is driven by one [AnimationController] that a swipe moves
/// continuously (right to open, left to push back, same finger), so the drawer
/// follows the hand instead of playing a canned animation. Only the overlay
/// rebuilds per frame; the chat underneath never does.
///
/// From 840dp wide ([AdaptiveLayout]) the list stays on screen as a rail or a
/// sidebar and 对话详情 is a column beside the chat; ≡ then folds and unfolds
/// the list, and the drawer is only pulled over when the sidebar doesn't fit.
///
/// A left swipe pulls [QuickPanel] over from the right the same way, wherever
/// the drawer's swipe works and what's under the finger has no horizontal drag
/// of its own. Each panel keeps the finger that moved it: neither becomes the
/// other mid-gesture, and open, one covers the chat and the other's swipe.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, this.chatBuilder, this.initiallyOpen = false});

  /// Replaces [ChatScreen] (widget tests use a stand-in).
  @visibleForTesting
  final Widget Function(VoidCallback openDrawer)? chatBuilder;

  /// Starts with the drawer fully open (goldens).
  @visibleForTesting
  final bool initiallyOpen;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> with TickerProviderStateMixin {
  late final AnimationController _drawer = AnimationController(
    vsync: this,
    duration: AppMotion.emphasized,
    value: widget.initiallyOpen ? 1 : 0,
  );

  late final AnimationController _quickPanel = AnimationController(vsync: this, duration: AppMotion.emphasized);

  /// Mirrors "drawer at all open" so PopScope rebuilds only on the 0 ↔ >0 edge.
  late bool _open = widget.initiallyOpen;

  /// The same for [_quickPanel].
  bool _quickPanelOpen = false;

  /// The pulled-over drawer's identity bar height: its notices stand above it.
  final _identityBar = ValueNotifier<double>(0);

  /// 「宠物设置」 from the floating pet's menu (every tap, not deduplicated).
  StreamSubscription<void>? _petSettings;

  @override
  void initState() {
    super.initState();
    _drawer.addListener(() {
      final open = _drawer.value > 0;
      if (open != _open) setState(() => _open = open);
    });
    _quickPanel.addListener(() {
      final open = _quickPanel.value > 0;
      if (open != _quickPanelOpen) setState(() => _quickPanelOpen = open);
    });
    _petSettings = ref.read(petOverlayChannelProvider).settingsRequests.listen((_) {
      if (mounted) unawaited(PetSettingsPage.open(context));
    });
  }

  @override
  void dispose() {
    unawaited(_petSettings?.cancel());
    _drawer.dispose();
    _quickPanel.dispose();
    _identityBar.dispose();
    super.dispose();
  }

  /// 320 of list, plus the cutout or navigation bar it covers on a phone on
  /// its side (the drawer's content keeps clear of it), like the sidebar.
  double _drawerWidth(BuildContext context) => math.min(
    AdaptiveMetrics.sidebarWidth + MediaQuery.paddingOf(context).left,
    MediaQuery.sizeOf(context).width - 56,
  );

  /// [QuickPanel.width], plus what it covers on a phone on its side.
  double _quickPanelWidth(BuildContext context) => math.min(
    (ref.read(currentSessionProvider) == null ? QuickPanel.width : QuickPanel.conversationWidth) +
        MediaQuery.paddingOf(context).right,
    MediaQuery.sizeOf(context).width - 56,
  );

  void _slideOpen(AnimationController side) {
    FocusManager.instance.primaryFocus?.unfocus();
    side.animateTo(1, curve: AppMotion.glide, duration: AppMotion.of(context, AppMotion.emphasized));
  }

  void _slideClosed(AnimationController side) {
    FocusManager.instance.primaryFocus?.unfocus();
    side.animateBack(0, curve: AppMotion.glide, duration: AppMotion.of(context, AppMotion.standard));
  }

  void _openDrawer() => _slideOpen(_drawer);

  void _closeDrawer() => _slideClosed(_drawer);

  void _closeQuickPanel() => _slideClosed(_quickPanel);

  void _revealChat(bool animate) {
    for (final side in [_drawer, _quickPanel]) {
      if (side.value == 0) continue;
      if (animate) {
        _slideClosed(side);
      } else {
        side.value = 0;
      }
    }
  }

  /// The columns as last built; what ≡ does depends on them.
  AdaptiveLayout _layout = const AdaptiveLayout.compact();

  /// ≡ (the header's, or the rail's): pull the drawer over, or fold / unfold
  /// the sidebar of a wide window.
  void _onMenu() {
    final prefs = ref.read(layoutPrefsProvider.notifier);
    switch (_layout.menuAction) {
      case MenuAction.overlay:
        _openDrawer();
      case MenuAction.expand:
        prefs.setSidebarOpen(true);
      case MenuAction.collapse:
        prefs.setSidebarOpen(false);
    }
  }

  Future<void> _search() async {
    final sessionId = await showSessionSearch(context);
    if (sessionId == null || !mounted) return;
    ref.read(currentSessionProvider.notifier).select(sessionId);
  }

  void _onDragStart(AnimationController side) {
    side.stop();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// [opening]: pixels towards fully open.
  void _onDragDelta(AnimationController side, double width, double opening) {
    if (width <= 0) return;
    side.value = (side.value + opening / width).clamp(0.0, 1.0);
  }

  /// [velocity]: pixels a second towards fully open.
  void _onDragEnd(AnimationController side, double width, double velocity) {
    if (velocity.abs() >= kMinFlingVelocity && width > 0) {
      final target = velocity > 0 ? 1.0 : 0.0;
      if (AppMotion.reduced(context)) {
        side.value = target;
        return;
      }
      // Not `fling`, which refuses a spring with any bounce. The controller's
      // bounds clip it: the bounce shapes the arrival, nothing goes past the edge.
      final spring = AppMotion.settle(AppMotion.flingSpring, side.value, target, velocity / width, landing: false);
      if (velocity > 0) {
        side.animateWith(spring);
      } else {
        side.animateBackWith(spring);
      }
      return;
    }
    if (side.value >= 0.5) {
      _slideOpen(side);
    } else {
      _slideClosed(side);
    }
  }

  void _openDestination(DrawerDestination destination) {
    final page = switch (destination) {
      // The active host's DSH Web, as every other 网页版 entry opens it.
      DrawerDestination.web => null,
      DrawerDestination.remote => const RemoteScreen(),
      DrawerDestination.plugins => const PluginsScreen(),
      DrawerDestination.engine => const EngineScreen(),
      DrawerDestination.settings => const SettingsScreen(),
      DrawerDestination.settingsSearch => const SettingsSearchPage(),
      DrawerDestination.features => const AllFeaturesPage(),
    };
    if (page == null) {
      openDshWeb(context, ref);
    } else {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    }
    // Close once the new page covers us, so "back" lands on the chat.
    Future<void>.delayed(AppMotion.slow, () {
      if (!mounted) return;
      _drawer.value = 0;
      _quickPanel.value = 0;
    });
  }

  /// The drawer's swipe (right to open, left to push back).
  Map<Type, GestureRecognizerFactory> get _drawerGestures => {
    DrawerDragRecognizer: GestureRecognizerFactoryWithHandlers<DrawerDragRecognizer>(
      () => DrawerDragRecognizer(
        isOpen: () => _drawer.value > 0,
        onStart: () => _onDragStart(_drawer),
        onDelta: (dx) => _onDragDelta(_drawer, _drawerWidth(context), dx),
        onEnd: (velocity) => _onDragEnd(_drawer, _drawerWidth(context), velocity),
        debugOwner: this,
      ),
      (_) {},
    ),
  };

  /// The quick panel's swipe (left to open, right to push back).
  Map<Type, GestureRecognizerFactory> get _quickPanelGestures {
    final settings = MediaQuery.maybeGestureSettingsOf(context);
    return {
      QuickPanelDragRecognizer: GestureRecognizerFactoryWithHandlers<QuickPanelDragRecognizer>(
        () => QuickPanelDragRecognizer(
          isOpen: () => _quickPanel.value > 0,
          onStart: () => _onDragStart(_quickPanel),
          onDelta: (dx) => _onDragDelta(_quickPanel, _quickPanelWidth(context), -dx),
          onEnd: (velocity) => _onDragEnd(_quickPanel, _quickPanelWidth(context), -velocity),
          debugOwner: this,
        ),
        (recognizer) => recognizer.gestureSettings = settings,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final width = _drawerWidth(context);
    final sessionId = ref.watch(currentSessionProvider);
    final prefs = ref.watch(layoutPrefsProvider);
    // Multi-select in a list on screen (the open drawer, or the sidebar):
    // back ends it before anything else.
    final selecting = ref.watch(drawerSelectionProvider.select((s) => s != null));
    final layout = _layout = AdaptiveLayout.resolve(
      window: MediaQuery.sizeOf(context),
      padding: MediaQuery.paddingOf(context),
      hasSession: sessionId != null,
      sidebarOpen: prefs.sidebarOpen,
      panelOpen: prefs.panelOpen,
    );
    // No quick panel beside a sidebar (the swipes are off there), or once
    // it's turned off: one left open goes, at once, as the window changes.
    final sidebar = layout.left == LeftPane.sidebar;
    // With a conversation open the panel has that to show, whatever shortcuts it lists.
    final quickPanelOn =
        !sidebar && ref.watch(quickPanelProvider.select((p) => p.available || (p.swipe && sessionId != null)));
    if (!quickPanelOn && _quickPanel.value > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _quickPanel.value = 0;
      });
    }
    final chat = widget.chatBuilder?.call(_onMenu) ?? ChatScreen(onOpenDrawer: _onMenu, backdrop: false);
    // The floating pet outside the app hears every pet state.
    ref.listen<void>(petOverlayBridgeProvider, (_, _) {});
    return SafeModeNoticeListener(
      child: PhoneStopWatcher(
        child: PopScope(
          canPop: !_open && !_quickPanelOpen && !(selecting && sidebar),
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            final selection = ref.read(drawerSelectionProvider.notifier);
            if (_quickPanelOpen) {
              _closeQuickPanel();
            } else if (selection.active) {
              selection.end();
            } else {
              _closeDrawer();
            }
          },
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: dshSystemOverlay(Theme.of(context).brightness),
            // 首页 / 对话 and the drawer: the custom wallpaper when one is in use.
            child: WallpaperBackdrop(
              child: _DrawerNoticeTheme(
                drawer: _drawer,
                identityBar: _identityBar,
                width: width,
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  // The chat screen handles the keyboard itself.
                  resizeToAvoidBottomInset: false,
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Notifications: routes taps, raises the in-app banner (draws nothing here).
                      ChatAlertHost(onReveal: _revealChat),
                      // Background running cut off by the phone, or on HarmonyOS suspended with the app:
                      // one line under the header (draws nothing here).
                      if (ref.watch(androidSystemFeaturesProvider))
                        const BackgroundNetHost()
                      else ...[
                        const BackgroundPauseHost(),
                        if (ref.watch(operatingSystemProvider) == 'ohos') ...[
                          // 系统操作: its session and a handoff's prompt (draws nothing here).
                          const SystemActionsHost(),
                          // How a reset asked for before the app reopened came out (draws nothing).
                          const ResetReceiptHost(),
                        ],
                      ],
                      // Daily update check + install resume (draws nothing).
                      const UpdateLaunchCheck(),
                      // The voice model chosen during setup: download, resume, ready / failed notices (draws nothing).
                      const VoiceModelHost(),
                      // 公测版: once in a while, an invitation to star the project (draws nothing).
                      StarPromptHost(drawer: _drawer, quickPanel: _quickPanel),
                      // App links / shared files: routes them to their feature (draws nothing).
                      const LinkHost(),
                      // Share codes (分享码): registers its links and files with the router.
                      const ShareCodeHost(),
                      // Character cards opened with the app: into 酒馆.
                      const TavernIntakeHost(),
                      // Share sheet, launcher shortcuts, the tile: into the chat (draws nothing).
                      SystemEntryHost(onReveal: _revealChat),
                      // Forum links (sign-in return, topics): registers them with the router.
                      const ForumLinkHost(),
                      // DS Bot: keeps its feed and notifications alive with the shell.
                      const BotAlertsHost(),
                      ExcludeSemantics(
                        excluding: _open || _quickPanelOpen,
                        child: _SideParallax(
                          drawer: _drawer,
                          drawerWidth: width,
                          quickPanel: _quickPanel,
                          quickPanelWidth: _quickPanelWidth(context),
                          child: AdaptiveScaffold(
                            layout: layout,
                            // Stored choices arriving at launch snap into place.
                            animate: prefs.loaded,
                            body: RawGestureDetector(
                              // translucent: join the hit chain without swallowing taps
                              // meant for the chat; wraps the whole chat column so empty
                              // areas still drag. Not 对话详情 beside it: its tabs swipe.
                              // No drawer to pull while the sidebar shows.
                              behavior: HitTestBehavior.translucent,
                              gestures: {if (!sidebar) ..._drawerGestures, if (quickPanelOn) ..._quickPanelGestures},
                              child: chat,
                            ),
                            sidebar: SessionsDrawer(
                              key: const ValueKey('persistent-sidebar'),
                              // It stays: picking a conversation just shows it.
                              onClose: () {},
                              onOpen: _openDestination,
                            ),
                            rail: AdaptiveRail(
                              onMenu: _onMenu,
                              menuTooltip: AdaptiveChrome.menuTooltipFor(layout),
                              onSearch: _search,
                              onHost: () =>
                                  showHostSheet(context, onManage: () => _openDestination(DrawerDestination.remote)),
                              onWeb: () => _openDestination(DrawerDestination.web),
                              onSettings: () => _openDestination(DrawerDestination.settings),
                            ),
                            panel: layout.panelAvailable && sessionId != null
                                ? SessionDetailPage.panel(key: ValueKey(sessionId), sessionId: sessionId)
                                : null,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        // The open drawer and its scrim take the swipe that pushes it
                        // back; closed, nothing here is hit.
                        child: RawGestureDetector(
                          behavior: HitTestBehavior.deferToChild,
                          gestures: _drawerGestures,
                          child: _DrawerOverlay(
                            animation: _drawer,
                            width: width,
                            drawer: SessionsDrawer(
                              onClose: _closeDrawer,
                              onOpen: _openDestination,
                              identityBarHeight: _identityBar,
                              drawerMotion: _drawer,
                            ),
                            onClose: _closeDrawer,
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: RawGestureDetector(
                          behavior: HitTestBehavior.deferToChild,
                          gestures: quickPanelOn ? _quickPanelGestures : const {},
                          child: _DrawerOverlay(
                            animation: _quickPanel,
                            width: _quickPanelWidth(context),
                            fromRight: true,
                            drawer: QuickPanel(
                              motion: _quickPanel,
                              onOpen: _openDestination,
                              sessionId: _quickPanelOpen ? sessionId : null,
                            ),
                            onClose: _closeQuickPanel,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// While the drawer is pulled over, notices (floating SnackBars without a
/// margin of their own) stand inside it: [SessionsDrawer.contentEdge] in from
/// either side of its content and [composerToastGap] above its identity bar,
/// clear of every key. Closed, the theme's placement is untouched; in
/// between they follow the drawer. Only SnackBars depend on this, so the
/// chat underneath still never rebuilds while the drawer moves.
class _DrawerNoticeTheme extends StatelessWidget {
  const _DrawerNoticeTheme({required this.drawer, required this.identityBar, required this.width, required this.child});

  final Animation<double> drawer;
  final ValueListenable<double> identityBar;

  /// The drawer's width, its content starting after the left inset.
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = SnackBarTheme.of(context);
    final closed = base.insetPadding;
    final screen = MediaQuery.sizeOf(context).width;
    final padding = MediaQuery.paddingOf(context);
    return AnimatedBuilder(
      animation: Listenable.merge([drawer, identityBar]),
      child: child,
      builder: (context, child) {
        final progress = drawer.value;
        var data = base;
        if (closed != null && progress > 0 && identityBar.value > 0) {
          // A floating SnackBar's margin lies inside the side insets (its
          // SafeArea) and stands on the bottom one, as the drawer's content does.
          final open = EdgeInsets.fromLTRB(
            SessionsDrawer.contentEdge,
            closed.top,
            math.max(0.0, screen - padding.right - width + SessionsDrawer.contentEdge),
            identityBar.value + composerToastGap,
          );
          data = base.copyWith(insetPadding: EdgeInsets.lerp(closed, open, progress));
        }
        return SnackBarTheme(data: data, child: child!);
      },
    );
  }
}

/// Scrim + drawer panel; the only part that rebuilds while the drawer moves. The
/// panel keeps its state when closed, while Visibility suppresses painting,
/// semantics and tickers until the first drag frame reveals it. [QuickPanel]
/// comes the same way, [fromRight].
/// The fluid tier: as a side panel slides over, the page below drifts a little the
/// same way. Only a translation: scaling would make its glass re-sample at a new size.
class _SideParallax extends StatelessWidget {
  const _SideParallax({
    required this.drawer,
    required this.drawerWidth,
    required this.quickPanel,
    required this.quickPanelWidth,
    required this.child,
  });

  final Animation<double> drawer;
  final double drawerWidth;
  final Animation<double> quickPanel;
  final double quickPanelWidth;
  final Widget child;

  static const _share = 0.14;

  @override
  Widget build(BuildContext context) {
    final fluid = AppMotion.fluid(context);
    return AnimatedBuilder(
      animation: Listenable.merge([drawer, quickPanel]),
      child: child,
      builder: (context, child) => Transform.translate(
        offset: Offset(fluid ? _share * (drawer.value * drawerWidth - quickPanel.value * quickPanelWidth) : 0, 0),
        child: child,
      ),
    );
  }
}

class _DrawerOverlay extends StatelessWidget {
  const _DrawerOverlay({
    required this.animation,
    required this.width,
    required this.drawer,
    required this.onClose,
    this.fromRight = false,
  });

  final Animation<double> animation;
  final double width;
  final Widget drawer;
  final VoidCallback onClose;
  final bool fromRight;

  @override
  Widget build(BuildContext context) {
    final scrim = DshSurfaces.of(context).scrim;
    return AnimatedBuilder(
      animation: animation,
      child: RepaintBoundary(child: drawer),
      builder: (context, drawer) {
        final progress = animation.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                ignoring: progress == 0,
                child: GestureDetector(
                  onTap: onClose,
                  child: ColoredBox(color: scrim.withValues(alpha: scrim.a * progress)),
                ),
              ),
            ),
            // 面板位置用 Transform 走(paint-only):每帧改 Positioned.left 会让
            // Stack 和整块抽屉重新布局,拖动时白白多一层成本。
            Positioned(
              left: fromRight ? null : 0,
              right: fromRight ? 0 : null,
              top: 0,
              bottom: 0,
              width: width,
              child: Visibility(
                visible: progress > 0,
                maintainState: true,
                child: Transform.translate(
                  offset: Offset((progress - 1) * (width + 24) * (fromRight ? -1 : 1), 0),
                  child: drawer!,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
