part of 'engine.dart';

// Complete, detached inputs for a fresh temporary root. Runtime preview
// projections cannot reconstruct archived source text, IDs or diagnostics.
final class _AuthoringSimulationSeed {
  const _AuthoringSimulationSeed({
    required this.resources,
    required this.candidates,
    required this.sources,
    required this.settingsDocument,
    required this.global,
    required this.personas,
    required this.presetRows,
    required this.defaultPresetId,
    required this.presetWorking,
    required this.chat,
    required this.history,
    required this.state,
    required this.gameplay,
  });

  final Map<String, _AuthoringCapturedResource> resources;
  final Map<String, Map<String, Object?>> candidates, sources;
  final Map<String, Object?> settingsDocument, global, personas, state;
  final Map<String, Map<String, Object?>?> presetRows;
  final String? defaultPresetId;
  final _PresetWorkingCapture presetWorking;
  final StoredChat chat;
  final List<StoredNode> history;
  final StoredGameplaySimulationData gameplay;
}

String? _authoringSimulationText(_AuthoringSimulationSeed seed, _AuthoringCapturedResource resource) {
  final id = resource.target.physicalResourceId;
  final candidate = seed.candidates[id];
  if (candidate == null) {
    return resource.snapshot.rawText;
  }
  final source = seed.sources[id]!;
  if (_stateJsonEqual(source['base'], candidate)) {
    final raw = source['rawText'] as String?;
    if (raw != null) {
      return raw;
    }
    if (source['present'] == false && source['origin'] != 'seed') {
      return null;
    }
  }
  return jsonEncode(candidate);
}

Future<void> _writeAuthoringSimulationSeed(
  Directory root,
  _AuthoringSimulationSeed seed,
  DateTime at,
  ModelCancellation cancellation,
) async {
  Future<void> write(String relative, List<int> bytes) async {
    cancellation.check();
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    cancellation.check();
    await file.writeAsBytes(bytes, flush: true);
    cancellation.check();
  }

  await write(
    'settings.json',
    utf8.encode(jsonEncode({...seed.settingsDocument, 'globalVariables': _jsonCompatible(seed.global)})),
  );
  await write('personas/index.json', utf8.encode(jsonEncode(seed.personas)));
  for (final resource in seed.resources.values) {
    final text = _authoringSimulationText(seed, resource);
    if (text == null) {
      continue;
    }
    final target = resource.target;
    switch (target.kind) {
      case TavernAuthoringTargetKind.character:
        final format = resource.sourceFormat!;
        var identity = resource.snapshot.identityText;
        if (resource.seedDraftId != null) {
          if (!resource.media.containsKey('original.$format') ||
              resource.mediaRefs.any((path) => !resource.media.containsKey('resources/$path'))) {
            throw const TavernImportError('The character seed is missing captured media.');
          }
          identity = jsonEncode({
            'version': 1,
            'importedAt': at.toIso8601String(),
            'sourceFormat': format,
            'sourceFileName': seed.sources[target.physicalResourceId]!['fileName'],
            'hasPng': format == 'png',
            'hasPortrait': false,
            'resources': resource.mediaRefs,
          });
        }
        if (identity == null) {
          throw const TavernImportError('The captured character has no library identity.');
        }
        final prefix = 'characters/${target.id}';
        await write('$prefix/card.json', utf8.encode(text));
        await write('$prefix/library.json', utf8.encode(identity));
        for (final entry in resource.media.entries) {
          await write('$prefix/${entry.key}', entry.value);
        }
        if (resource.seedDraftId != null && format == 'png') {
          await write('$prefix/source.png', resource.media['original.png']!);
        }
      case TavernAuthoringTargetKind.lorebook:
        await write('lorebooks/${target.id}.json', utf8.encode(text));
      case TavernAuthoringTargetKind.regexLibrary:
        // Fresh-open uses the complete saved record, including its original
        // compatibility decision. Import/recheck would change that evidence.
        await write('regex-library.json', utf8.encode(text));
      case TavernAuthoringTargetKind.preset:
        break;
    }
  }
}

Map<String, Object?> _authoringSimulationPresetRow(String id, Map<String, Object?> candidate) {
  if (candidate['id'] != id) {
    _authoringInvalid('A simulated preset must retain its physical resource ID.', resourceId: 'preset:$id');
  }
  return {
    'id': id,
    'name': candidate['name']! as String,
    'sourceText': candidate['sourceText']! as String,
    'rawJson': jsonEncode(candidate['raw']),
    'envelopeJson': candidate['envelope'] == null ? null : jsonEncode(candidate['envelope']),
    'importReportJson': candidate['importReport'] == null ? null : jsonEncode(candidate['importReport']),
    'createdAt': candidate['createdAt']! as int,
    'updatedAt': candidate['updatedAt']! as int,
  };
}

String _bootstrapAuthoringSimulationStore(TavernEngine engine, _AuthoringSimulationSeed seed) {
  final presets = <Map<String, Object?>>[];
  for (final entry in seed.presetRows.entries) {
    final candidate = seed.candidates['preset:${entry.key}'];
    final row = candidate == null ? entry.value : _authoringSimulationPresetRow(entry.key, candidate);
    if (row != null) {
      presets.add(row);
    }
  }
  final chatId = engine._store.transaction(() {
    final id = engine._store.bootstrapAuthoringSimulation(
      chat: seed.chat,
      history: seed.history,
      state: seed.state,
      presets: presets,
      defaultPresetId: seed.defaultPresetId,
    );
    engine._store.bootstrapGameplaySimulationData(seed.gameplay);
    return id;
  });
  // File JSON and native runtime values are deliberately distinct. This new
  // base has no live pending writes and uses only the temporary file owner.
  engine._globalVariables.commit(seed.global, engine._globalVariables.revision);
  engine._liveVariables[chatId] = (
    leaf: seed.history.lastOrNull?.message.nodeId,
    values: _runtimeCopy(seed.chat.variables),
  );
  engine._restoreCapturedPresetWorking(seed.presetWorking, chatId);
  return chatId;
}
