import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/app_dialog.dart';
import '../workspace/directory_picker.dart';
import '../workspace/text_prompt.dart';

/// Select the two original versions. The Host binds a leaf name inside a real
/// folder reference; the phone never constructs a path or reads either body.
Future<MemoryRow?> chooseCompanionDraftInputs(
  BuildContext context, {
  required CompanionMemoryStore store,
  required String hostKey,
  required DshClient? client,
  required CompanionTasksCapability? capability,
  required bool Function() isCurrent,
  void Function(ModalRoute<Object?> route, Route<dynamic>? nextRoute)? onRouteChanged,
  String? originalStoreId,
}) async {
  final l10n = context.l10n;
  final inputs = <String, Object?>{};
  var storeId = originalStoreId;
  final saved = client == null
      ? store
            .hostTaskInputs(hostKey: hostKey)
            .where(
              (row) =>
                  const ['text/plain', 'text/markdown'].contains(row['mediaType']) && (row['size']! as int) <= 65536,
            )
            .toList()
      : const <MemoryRow>[];
  for (final side in ['a', 'b']) {
    if (!context.mounted || !isCurrent()) {
      throw const DshClosedException('task selection changed before choosing the original draft');
    }
    final label = side == 'a' ? l10n.companionCompareA : l10n.companionCompareB;
    MemoryRow? input;
    if (client == null) {
      final candidates = saved.where((row) => storeId == null || row['hostStoreId'] == storeId).toList();
      if (candidates.isEmpty) {
        return null;
      }
      final byName = <String, List<MemoryRow>>{};
      for (final candidate in candidates) {
        byName.putIfAbsent(candidate['displayName']! as String, () => []).add(candidate);
      }
      input = await showAppDialog<MemoryRow>(
        context: context,
        onRouteChanged: onRouteChanged,
        builder: (dialog) => SimpleDialog(
          title: Text(l10n.companionCompareSaved(label)),
          children: [
            for (final entry in byName.entries)
              SimpleDialogOption(
                onPressed: entry.value.length == 1 ? () => Navigator.pop(dialog, entry.value.single) : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text(entry.key), if (entry.value.length != 1) Text(l10n.companionCompareAmbiguousFile)],
                ),
              ),
            SimpleDialogOption(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonCancel)),
          ],
        ),
      );
    } else {
      if (capability == null || !capability.compareDrafts || (storeId != null && capability.hostStoreId != storeId)) {
        throw const DshRemoteException('companion/task-store-mismatch', 'The original input store is unavailable');
      }
      final path = await showDirectoryPicker(
        context,
        title: l10n.companionCompareChooseDirectory(label),
        onRouteChanged: onRouteChanged,
      );
      if (!context.mounted || !isCurrent()) {
        throw const DshClosedException('task selection changed during directory selection');
      }
      if (path == null) {
        return null;
      }
      final folder = await client.bindCompanionNotesDirectory(capability, path);
      if (!context.mounted || !isCurrent()) {
        throw const DshClosedException('task selection changed during directory binding');
      }
      final name = await showTextPrompt(
        context,
        title: l10n.companionCompareFilename(label),
        onRouteChanged: onRouteChanged,
        caption: l10n.companionCompareFileLimit,
        hint: side == 'a' ? 'A.md' : 'B.md',
        validate: (value) => value.isEmpty ? l10n.companionCompareFilenameMissing : null,
      );
      if (!context.mounted || !isCurrent()) {
        throw const DshClosedException('task selection changed before binding the original draft');
      }
      if (name == null) {
        return null;
      }
      input = await client.bindCompanionDraftInput(capability, folderRef: folder['folderRef']! as String, name: name);
    }
    if (!context.mounted || !isCurrent()) {
      throw const DshClosedException('task selection changed before saving both original drafts');
    }
    if (input == null) {
      return null;
    }
    storeId ??= input['hostStoreId']! as String;
    inputs[side] = input;
  }
  return inputs;
}
