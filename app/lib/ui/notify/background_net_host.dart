// The chat's one quiet line about background running
// (runtime/background_net.dart decides when): a glass capsule under the chat
// header, 「后台联网被系统限制」 + 「去放行」, gone with a tap.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/background_net.dart';
import '../chat/chat_header.dart';
import '../settings/background_guide_page.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Put it once inside the home route (the home shell does). It tells the controller when the
/// app leaves the screen and comes back, and shows the line in the root overlay while the chat
/// is the current route. Draws nothing here.
class BackgroundNetHost extends ConsumerStatefulWidget {
  const BackgroundNetHost({super.key});

  @override
  ConsumerState<BackgroundNetHost> createState() => _BackgroundNetHostState();
}

class _BackgroundNetHostState extends ConsumerState<BackgroundNetHost> {
  late final AppLifecycleListener _lifecycle;
  final _chatOnScreen = ValueNotifier<bool>(true);
  OverlayEntry? _entry;

  BackgroundNetController get _controller => ref.read(backgroundNetProvider.notifier);

  @override
  void initState() {
    super.initState();
    // hidden ⇄ shown: Home, the recents switcher, another app on top. Not the notification shade.
    _lifecycle = AppLifecycleListener(
      onHide: () => _controller.setVisible(false),
      onShow: () => _controller.setVisible(true),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry != null) return;
      _entry = OverlayEntry(builder: (_) => BackgroundNetLayer(onScreen: _chatOnScreen));
      Overlay.of(context, rootOverlay: true).insert(_entry!);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Rebuilt by the route whenever a page is pushed over the chat or popped.
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _chatOnScreen.value = current;
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _entry?.remove();
    _entry?.dispose();
    _chatOnScreen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keeps the controller (and its turn-end subscription) alive with the shell.
    ref.watch(backgroundNetProvider.select((_) => null));
    return const SizedBox.shrink();
  }
}

/// The line's slot in the root overlay, just under the chat header.
class BackgroundNetLayer extends ConsumerWidget {
  const BackgroundNetLayer({super.key, required this.onScreen});

  /// The chat is the current route; the line waits while a page covers it.
  final ValueListenable<bool> onScreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reason = ref.watch(backgroundNetProvider);
    final controller = ref.read(backgroundNetProvider.notifier);
    return ValueListenableBuilder<bool>(
      valueListenable: onScreen,
      builder: (context, current, _) {
        final shown = current ? reason : null;
        return BackgroundLineSlot(
          child: shown == null
              ? null
              : BackgroundNetPill(
                  key: ValueKey(shown),
                  reason: shown,
                  onDismiss: controller.dismiss,
                  onOpen: () {
                    controller.dismiss();
                    Navigator.of(
                      context,
                      rootNavigator: true,
                    ).push(MaterialPageRoute<void>(builder: (_) => const BackgroundGuidePage()));
                  },
                ),
        );
      },
    );
  }
}

/// Where such a line sits in the root overlay, and how it comes and goes.
class BackgroundLineSlot extends StatelessWidget {
  const BackgroundLineSlot({super.key, required this.child});

  /// The line; null: none.
  final Widget? child;

  @override
  Widget build(BuildContext context) => Positioned(
    top: ChatHeader.heightOf(context),
    left: AppSpace.md,
    right: AppSpace.md,
    child: Align(
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: AppMotion.of(context, AppMotion.standard),
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.exit,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, -0.25), end: Offset.zero).animate(animation),
            child: child,
          ),
        ),
        child: child ?? const SizedBox(key: ValueKey('none')),
      ),
    ),
  );
}

/// Android's line: why the network was cut, and 「去放行」.
class BackgroundNetPill extends StatelessWidget {
  const BackgroundNetPill({super.key, required this.reason, required this.onDismiss, required this.onOpen});

  final BackgroundNetReason reason;
  final VoidCallback onDismiss;
  final VoidCallback onOpen;

  static const minHeight = BackgroundLinePill.minHeight;

  @override
  Widget build(BuildContext context) => BackgroundLinePill(
    icon: reason == BackgroundNetReason.intro ? AppIcons.keepAlive : AppIcons.offline,
    text: reason.text,
    onDismiss: onDismiss,
    action: context.l10n.phoneBackgroundAllow,
    onAction: onOpen,
  );
}

/// One line in a glass capsule: glyph, what happened, maybe an action. A tap anywhere else dismisses.
class BackgroundLinePill extends StatelessWidget {
  const BackgroundLinePill({
    super.key,
    required this.icon,
    required this.text,
    required this.onDismiss,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final VoidCallback onDismiss;
  final String? action;
  final VoidCallback? onAction;

  /// Glyph and label sit this far from their ends of the capsule.
  static const inset = 12.0;

  /// The action's own horizontal padding (part of the [inset] on its side).
  static const actionPad = 8.0;

  static const minHeight = 40.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(height: 1.3);
    return Semantics(
      container: true,
      liveRegion: true,
      onDismiss: onDismiss,
      child: GlassSurface(
        tier: GlassTier.chrome,
        stadium: true,
        onTap: onDismiss,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: minHeight),
          child: Padding(
            padding: EdgeInsets.only(left: inset, right: action == null ? inset : inset - actionPad),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  key: const ValueKey('background-net-glyph'),
                  icon,
                  size: 16,
                  color: colors.textTertiary,
                ),
                const SizedBox(width: AppSpace.sm),
                Flexible(
                  child: Semantics(
                    onTapHint: l10n.commonClose,
                    child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                  ),
                ),
                if (action case final action?) ...[
                  const SizedBox(width: AppSpace.xs),
                  Semantics(
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onAction,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: actionPad, vertical: 10),
                        child: Text(
                          action,
                          key: const ValueKey('background-net-action'),
                          style: style?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
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
