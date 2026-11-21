// When the star prompt comes up (docs/design/star-prompt.md §1): the record
// says it is due (half an hour in front; then 2, 5, 10, 20 hours after 「下次再说」),
// and for three seconds the person has been idle in the chat — the app in
// front, nothing over the chat, the drawer closed, the conversation on screen
// not running, nothing waiting on them, no phone control, no dictation, no
// typing — and nothing else asked for their attention in this launch.
// Otherwise it looks again when any of that changes, or a minute later.
//
// Lives with the home shell, so first run is over. With the release switch
// off this draws nothing and does nothing.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../launch/launch_state.dart' show LaunchController;
import '../../state/notify_state.dart' show launchNoticeShownProvider;
import '../../state/star_prompt.dart';
import 'star_prompt_dialog.dart';

/// Lives with the home shell; draws nothing.
class StarPromptHost extends ConsumerStatefulWidget {
  const StarPromptHost({super.key, this.drawer, this.quickPanel});

  /// The shell's drawer (0: closed). Open, nothing comes up.
  final ValueListenable<double>? drawer;

  /// The shell's 快捷入口 panel, the same.
  final ValueListenable<double>? quickPanel;

  @override
  ConsumerState<StarPromptHost> createState() => _StarPromptHostState();
}

class _StarPromptHostState extends ConsumerState<StarPromptHost> {
  late final bool _on = ref.read(starPromptGateProvider);
  Timer? _settle;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    if (!_on) return;
    // The record changes each minute while time is counted: another look.
    ref.listenManual(starPromptProvider, (_, _) => _check());
    // Held while the switch is on, so what the scene reads keeps listening.
    ref.listenManual(starPromptSceneProvider, (_, _) => _check());
    ref.listenManual(launchNoticeShownProvider, (_, _) => _check());
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  /// Due, nothing else asked in this launch, and the person idle as far as
  /// app state tells.
  bool get _wanted =>
      ref.read(starPromptProvider.notifier).due &&
      !ref.read(launchNoticeShownProvider) &&
      ref.read(starPromptSceneProvider).quietAt(ref.read(starPromptClockProvider)());

  void _check() {
    if (_showing) return;
    if (!_wanted) {
      _settle?.cancel();
      _settle = null;
      return;
    }
    if (_settle != null) return;
    // Decoded by the time it comes up.
    unawaited(precacheImage(const AssetImage(StarPromptDialog.asset), context));
    _settle = Timer(StarPromptRules.settle, _maybeShow);
  }

  void _maybeShow() {
    _settle = null;
    if (!mounted || _showing || !_wanted) return;
    // What only the page knows: the drawer, the keyboard (the window's own
    // inset: a Scaffold above may have taken it out of the MediaQuery), the
    // launch screen still playing. The next look is at most a minute away.
    if ((widget.drawer?.value ?? 0) != 0 ||
        (widget.quickPanel?.value ?? 0) != 0 ||
        View.of(context).viewInsets.bottom > 0 ||
        LaunchController.active.value != null) {
      return;
    }
    _showing = true;
    final record = ref.read(starPromptProvider);
    unawaited(ref.read(starPromptProvider.notifier).shown());
    unawaited(
      showStarPrompt(context, hours: record.used.inHours, ask: record.shows).whenComplete(() => _showing = false),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
