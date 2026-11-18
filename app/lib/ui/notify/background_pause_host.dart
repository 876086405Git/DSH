// The chat's one quiet line on HarmonyOS about a pause in the background
// (runtime/background_pause.dart decides when), in the place and shape of
// Android's line (background_net_host.dart).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/background_pause.dart';
import '../../runtime/continued_run.dart';
import '../theme/app_icons.dart';
import 'background_net_host.dart';

/// Put it once inside the home route (the home shell does, on HarmonyOS). It
/// keeps the controller alive and shows the line in the root overlay while the
/// chat is the current route. Draws nothing here.
class BackgroundPauseHost extends ConsumerStatefulWidget {
  const BackgroundPauseHost({super.key});

  @override
  ConsumerState<BackgroundPauseHost> createState() => _BackgroundPauseHostState();
}

class _BackgroundPauseHostState extends ConsumerState<BackgroundPauseHost> {
  final _chatOnScreen = ValueNotifier<bool>(true);
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry != null) return;
      _entry = OverlayEntry(builder: (_) => BackgroundPauseLayer(onScreen: _chatOnScreen));
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
    _entry?.remove();
    _entry?.dispose();
    _chatOnScreen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keeps the controller (and what it follows) alive with the shell.
    ref.watch(backgroundPauseProvider.select((_) => null));
    ref.watch(continuedRunProvider);
    return const SizedBox.shrink();
  }
}

/// The line's slot in the root overlay, just under the chat header.
class BackgroundPauseLayer extends ConsumerWidget {
  const BackgroundPauseLayer({super.key, required this.onScreen});

  /// The chat is the current route; the line waits while a page covers it.
  final ValueListenable<bool> onScreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paused = ref.watch(backgroundPauseProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: onScreen,
      builder: (context, current, _) => BackgroundLineSlot(
        child: paused && current
            ? BackgroundLinePill(
                key: const ValueKey('background-pause'),
                icon: AppIcons.paused,
                text: context.l10n.harmonyPausedInBackground,
                onDismiss: ref.read(backgroundPauseProvider.notifier).dismiss,
              )
            : null,
      ),
    );
  }
}
