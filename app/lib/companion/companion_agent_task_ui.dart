import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';

import 'companion_host_tasks.dart';
import 'companion_maps.dart';

typedef CompanionAgentSelectionRoute = void Function(ModalRoute<Object?> route, Route<dynamic>? nextRoute);

/// One captured real full-mode connection, not a selected but disconnected Host.
class CompanionAgentTaskHost {
  const CompanionAgentTaskHost({
    required this.key,
    required this.client,
    required this.isCurrent,
    required this.ensureSession,
    this.sessionId,
  });

  final String key;
  final DshClient client;
  final bool Function() isCurrent;
  final Future<String> Function() ensureSession;
  final String? sessionId;
}

/// The Page owns these original pickers and the exact route callback object.
/// The adapter never keeps a BuildContext or constructs a directory/file ref.
abstract interface class CompanionAgentTaskUi {
  /// The captured visit's opportunity. Once retired it must not revive after
  /// returning from an unrelated route, resuming, or changing Host and back.
  bool get isCurrent;
  bool get mapIsCurrent;
  CompanionAgentSelectionRoute? get onSelectionRoute;

  Future<String?> chooseDeadline(
    List<String> choices, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  });

  Future<String?> chooseDirectory({
    required String kind,
    String? directoryHint,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  });

  Future<MemoryRow?> chooseSavedDirectory(
    List<MemoryRow> directories, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  });

  Future<MemoryRow?> chooseDrafts({
    required CompanionMemoryStore store,
    required String hostKey,
    required DshClient? client,
    required CompanionTasksCapability? capability,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
    String? originalStoreId,
  });

  Future<({List<MemoryRow> inputs, MemoryRow outputDirectory})?> chooseReceipts({
    required CompanionMemoryStore store,
    required String hostKey,
    required DshClient? client,
    required CompanionTasksCapability? capability,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
    String? originalStoreId,
    List<MemoryRow>? keptInputs,
    MemoryRow? keptOutput,
  });

  Future<CompanionMapSpec?> chooseMap(
    CompanionMaps maps,
    String address, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  });

  /// Reflect a real persisted task/receipt in the current room, if still shown.
  void accepted(MemoryRow task);

  /// Starts the Page-owned handoff of fresh, fixed revisions. The Page may
  /// await its current frame before rechecking and pushing the existing detail;
  /// this call does not await leaving that route or transfer an active scope.
  void startForeground(List<CompanionNotesForegroundCapture> captures, {required bool Function() isCurrent});
}
