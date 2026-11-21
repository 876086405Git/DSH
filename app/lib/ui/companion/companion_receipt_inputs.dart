import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/app_dialog.dart';
import '../workspace/directory_picker.dart';
import '../workspace/text_prompt.dart';

/// Four ordered originals and one real output directory. No body upload,
/// ordinary file API, or typed path is used as a persistent file reference.
Future<({List<MemoryRow> inputs, MemoryRow outputDirectory})?> chooseCompanionReceiptInputs(
  BuildContext context, {
  required CompanionMemoryStore store,
  required String hostKey,
  required DshClient? client,
  required CompanionTasksCapability? capability,
  required bool Function() isCurrent,
  void Function(ModalRoute<Object?> route, Route<dynamic>? nextRoute)? onRouteChanged,
  String? originalStoreId,
  List<MemoryRow>? keptInputs,
  MemoryRow? keptOutput,
}) async {
  final l10n = context.l10n;
  var storeId = originalStoreId;
  final inputs = keptInputs == null ? <MemoryRow>[] : List<MemoryRow>.of(keptInputs);
  final saved = client == null ? store.hostTaskInputs(hostKey: hostKey) : const <MemoryRow>[];
  for (var index = inputs.length; index < 4; index++) {
    if (!context.mounted || !isCurrent()) {
      throw const DshClosedException('receipt selection changed before durable acceptance');
    }
    MemoryRow? input;
    if (client == null) {
      final byName = <String, List<MemoryRow>>{};
      for (final candidate in saved) {
        if ((storeId == null || candidate['hostStoreId'] == storeId) &&
            !inputs.any(
              (chosen) =>
                  chosen['sourceRef'] == candidate['sourceRef'] &&
                  chosen['version'] == candidate['version'] &&
                  chosen['hostStoreId'] == candidate['hostStoreId'],
            )) {
          byName.putIfAbsent(candidate['displayName']! as String, () => []).add(candidate);
        }
      }
      if (byName.isEmpty) {
        return null;
      }
      input = await showAppDialog<MemoryRow>(
        context: context,
        onRouteChanged: onRouteChanged,
        builder: (dialog) => SimpleDialog(
          title: Text(l10n.companionReceiptSavedInput('${index + 1}')),
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
      if (capability == null || !capability.receiptsToSheet || (storeId != null && capability.hostStoreId != storeId)) {
        throw const DshRemoteException('companion/task-store-mismatch', 'The original receipt store is unavailable');
      }
      final path = await showDirectoryPicker(
        context,
        title: l10n.companionReceiptChooseDirectory('${index + 1}'),
        onRouteChanged: onRouteChanged,
      );
      if (!context.mounted || !isCurrent()) {
        throw const DshClosedException('receipt selection changed before durable acceptance');
      }
      if (path == null) {
        return null;
      }
      final folder = await client.bindCompanionNotesDirectory(capability, path);
      if (!context.mounted || !isCurrent()) {
        throw const DshClosedException('receipt selection changed before durable acceptance');
      }
      final name = await showTextPrompt(
        context,
        title: l10n.companionReceiptFilename('${index + 1}'),
        onRouteChanged: onRouteChanged,
        caption: l10n.companionReceiptFormats((capability.receiptInputs!['formats']! as List<Object?>).join('/')),
        validate: (value) => value.isEmpty ? l10n.companionCompareFilenameMissing : null,
      );
      if (!context.mounted || !isCurrent()) {
        throw const DshClosedException('receipt selection changed before durable acceptance');
      }
      if (name == null) {
        return null;
      }
      input = await client.bindCompanionReceiptInput(capability, folderRef: folder['folderRef']! as String, name: name);
    }
    if (!context.mounted || !isCurrent()) {
      throw const DshClosedException('receipt selection changed before durable acceptance');
    }
    if (input == null) {
      return null;
    }
    storeId ??= input['hostStoreId']! as String;
    inputs.add(input);
  }
  MemoryRow? output = keptOutput;
  if (output == null && client == null) {
    final byName = <String, List<MemoryRow>>{};
    for (final directory in store.hostTaskDirectories(hostKey: hostKey)) {
      if (directory['hostStoreId'] == storeId) {
        byName.putIfAbsent(directory['displayPath']! as String, () => []).add(directory);
      }
    }
    if (byName.isEmpty) {
      return null;
    }
    if (!context.mounted || !isCurrent()) {
      throw const DshClosedException('receipt selection changed before durable acceptance');
    }
    final selected = await showAppDialog<MemoryRow>(
      context: context,
      onRouteChanged: onRouteChanged,
      builder: (dialog) => SimpleDialog(
        title: Text(l10n.companionReceiptSavedOutput),
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
    // Only the fixed v1 envelope is reconstructed; identity/path remain the
    // actual persisted selection, not a fresh claim about the current folder.
    if (selected != null) {
      output = {'v': 1, ...selected};
    }
  } else if (output == null) {
    if (!context.mounted || !isCurrent()) {
      throw const DshClosedException('receipt selection changed before durable acceptance');
    }
    final path = await showDirectoryPicker(
      context,
      title: l10n.companionNotesChooseOutput,
      onRouteChanged: onRouteChanged,
    );
    if (!context.mounted || !isCurrent()) {
      throw const DshClosedException('receipt selection changed before durable acceptance');
    }
    if (path == null) {
      return null;
    }
    output = await client!.bindCompanionNotesDirectory(capability!, path);
  }
  if (!context.mounted || !isCurrent()) {
    throw const DshClosedException('receipt selection changed before durable acceptance');
  }
  return output == null ? null : (inputs: inputs, outputDirectory: output);
}
