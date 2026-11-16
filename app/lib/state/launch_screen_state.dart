// 设置 › 主题 › 启动画面: the user's own launch screen (lib/launch/custom_launch.dart), and
// whether it is the one in use.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../launch/custom_launch.dart';
import '../launch/launch_import.dart';

final launchImportProvider = Provider<LaunchImport>((ref) => LaunchImport());

/// The stored custom launch screen (null: none chosen yet).
final customLaunchProvider = AsyncNotifierProvider<CustomLaunchController, CustomLaunch?>(CustomLaunchController.new);

class CustomLaunchController extends AsyncNotifier<CustomLaunch?> {
  @override
  Future<CustomLaunch?> build() => CustomLaunch.load();

  /// The system picker; the pick becomes the launch screen in use. Null when it did, else why not
  /// ([LaunchImportProblem.cancelled] included).
  Future<LaunchImportProblem?> choose() async {
    final previous = state.value;
    final (custom, problem) = await ref.read(launchImportProvider).pick(previous: previous);
    if (custom == null) return problem ?? LaunchImportProblem.unreadable;
    await _store(custom);
    // Only now: until the new choice is saved, the old files are the one the next launch reads.
    await LaunchImport.removeFiles(previous, except: custom);
    return null;
  }

  /// The custom one in use (true) or the default (false); the file stays either way.
  Future<void> use(bool custom) async {
    final current = state.value;
    if (current == null || current.on == custom) return;
    await _store(current.copyWith(on: custom));
  }

  Future<void> setFit(LaunchFit fit) async {
    final current = state.value;
    if (current == null || current.fit == fit) return;
    await _store(current.copyWith(fit: fit));
  }

  Future<void> setBackdrop(LaunchBackdrop backdrop) async {
    final current = state.value;
    if (current == null || current.backdrop == backdrop) return;
    await _store(current.copyWith(backdrop: backdrop));
  }

  /// Where the screen sits in a [LaunchFit.fill] picture.
  Future<void> frame({required double zoom, required double alignX, required double alignY}) async {
    final current = state.value;
    if (current == null) return;
    await _store(
      current.copyWith(
        zoom: zoom.clamp(1.0, CustomLaunch.maxZoom),
        alignX: alignX.clamp(-1.0, 1.0),
        alignY: alignY.clamp(-1.0, 1.0),
      ),
    );
  }

  Future<void> _store(CustomLaunch custom) async {
    state = AsyncData(custom);
    await CustomLaunch.save(custom);
  }
}
