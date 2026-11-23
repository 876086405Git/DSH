import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_float.dart' show companionFloatStoreProvider;
import '../../companion/companion_pack.dart';
import '../../state/android_features.dart' show operatingSystemProvider;
import '../companion/companion_stage.dart';

/// Mount once per attempt, with a new key when the source or attempt changes.
/// The platform view needs a laid-out box; do not put this in an Offstage.
/// [onResult] is called once with PNG or null. Unmounting cancels silently.
class WorkshopCompanionAutoCover extends ConsumerStatefulWidget {
  const WorkshopCompanionAutoCover({super.key, this.store, required this.onResult});

  /// Null reads the currently installed companion. A ZIP upload supplies the
  /// store already staged by the file picker, never the live pack's store.
  final CompanionPackStore? store;
  final ValueChanged<Uint8List?> onResult;

  @override
  ConsumerState<WorkshopCompanionAutoCover> createState() => _WorkshopCompanionAutoCoverState();
}

class _WorkshopCompanionAutoCoverState extends ConsumerState<WorkshopCompanionAutoCover> {
  final _controller = CompanionStageController();
  Timer? _timeout;
  CompanionPackStore? _store;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Includes locating and checking the pack as well as the actual render.
      _timeout = Timer(const Duration(seconds: 25), () => _finish(null));
      unawaited(_start());
    });
  }

  Future<void> _start() async {
    final os = ref.read(operatingSystemProvider);
    if (os != 'android' && os != 'ios' && os != 'ohos') {
      _finish(null);
      return;
    }
    try {
      final store = widget.store ?? await ref.read(companionFloatStoreProvider)();
      if (mounted && !_done) setState(() => _store = store);
    } on Object {
      _finish(null);
    }
  }

  void _finish(Uint8List? bytes) {
    if (!mounted || _done) return;
    _timeout?.cancel();
    setState(() => _done = true);
    widget.onResult(bytes);
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    if (_done || store == null) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: IgnorePointer(
        child: SizedBox.square(
          dimension: 16,
          child: CompanionStage(
            store: store,
            controller: _controller,
            events: CompanionStageEvents(
              onCover: _finish,
              onReady: () {},
              onFailed: (_) => _finish(null),
              onTouch: (_, _) {},
              onWake: () {},
              onMood: (_) {},
              onObject: (_) {},
              onActivity: (_) {},
            ),
          ),
        ),
      ),
    );
  }
}
