part of 'companion_pack.dart';

Map<String, Object?> _exportFields(Object? value, Iterable<String> keys) {
  final map = value is Map ? value : const {};
  return {for (final key in keys)
    if (map[key] is String || map[key] is bool || map[key] is num && (map[key] as num).isFinite) key: map[key],
  };
}

Map<String, Object?> _exportNumbers(Object? value, [Set<String>? keys]) => {
  if (value is Map) for (final e in value.entries)
    if (e.key is String && (keys == null || keys.contains(e.key)) && e.value is num && (e.value as num).isFinite)
      e.key as String: e.value,
};

List<String> _exportNames(Object? value) => value is List
    ? value.whereType<String>().where((v) => workshopText(v, 160)).toList() : const [];

/// Known, data-only adaptation fields. Notes and any extra keys are omitted
/// even when the author explicitly opts to include their name or persona.
Map<String, Object?> _exportAdapter(Object? value) {
  final raw = value is Map ? value : const {};
  final out = <String, Object?>{};
  if (raw['adapter'] == 1) out['adapter'] = 1;
  if (workshopHash(raw['moc'])) out['moc'] = raw['moc'];
  if (raw['params'] is Map) {
    out['params'] = {
      for (final e in (raw['params'] as Map).entries)
        if (companionAdaptParams.containsKey(e.key) && e.value is Map) e.key: {
          'id': workshopText((e.value as Map)['id'], 160) ? (e.value as Map)['id'] : _exportNames((e.value as Map)['id']),
          ..._exportNumbers(e.value, {'scale', 'offset'}),
        },
    };
  }
  if (raw['emotions'] is Map) {
    out['emotions'] = {
      for (final e in (raw['emotions'] as Map).entries)
        if ((companionAdaptEmotions.contains(e.key) || e.key == 'dizzy') && e.value is Map) e.key: {
          if (workshopText((e.value as Map)['expression'], 160)) 'expression': (e.value as Map)['expression'],
          if ((e.value as Map)['face'] is Map) 'face': _exportNumbers((e.value as Map)['face'], {...companionAdaptParams.keys, 'eyelid'}),
          if ((e.value as Map)['gaze'] is List && ((e.value as Map)['gaze'] as List).length == 2 &&
              ((e.value as Map)['gaze'] as List).every((v) => v is num && v.isFinite)) 'gaze': (e.value as Map)['gaze'],
        },
    };
  }
  if (raw['actions'] is Map) {
    out['actions'] = {
      for (final e in (raw['actions'] as Map).entries)
        if (companionAdaptActions.contains(e.key) && e.value is Map) e.key: {
          if (workshopText((e.value as Map)['motion'], 160)) 'motion': (e.value as Map)['motion'],
          ..._exportNumbers(e.value, {'ms'}),
          if ((e.value as Map)['tracks'] is Map) 'tracks': {
            for (final track in ((e.value as Map)['tracks'] as Map).entries)
              if (companionAdaptParams.containsKey(track.key) && track.value is List) track.key: [
                for (final point in track.value as List)
                  if (point is List && point.length == 2 && point.every((v) => v is num && v.isFinite)) point,
              ],
          },
        },
    };
  }
  if (raw['zones'] is List) {
    out['zones'] = [
      for (final zone in raw['zones'] as List)
        if (zone is Map && companionAdaptZones.contains(zone['id'])) {
          'id': zone['id'], ..._exportNumbers(zone, {'from', 'to', 'xFrom', 'xTo'}),
        },
    ];
  }
  if (raw['tail'] is List) out['tail'] = _exportNames(raw['tail']);
  if (raw['pose'] is Map) out['pose'] = _exportNumbers(raw['pose']);
  if (raw['framing'] is Map) out['framing'] = _exportNumbers(raw['framing'], {'zoom', 'y'});
  return out;
}

/// Rebuild known Cubism data schemas instead of copying arbitrary JSON keys.
/// UserData, motion events and display names are unnecessary to rendering and
/// deliberately not exported. Model audio is omitted with its Sound references.
Map<String, Object?> _exportModel(Map<String, Object?> raw, Map<String, String> assets, String home) {
  final refs = raw['FileReferences'] as Map;
  void asset(Object? path, String role) {
    _complete(path is String, 'companion_bad_reference');
    final name = '$home$path';
    _complete(!assets.containsKey(name) || assets[name] == role, 'companion_bad_reference');
    assets[name] = role;
  }
  asset(refs['Moc'], 'moc');
  for (final path in refs['Textures'] as List) { asset(path, 'texture'); }
  for (final entry in {'Physics': 'physics', 'Pose': 'pose'}.entries) {
    if (refs[entry.key] != null) asset(refs[entry.key], entry.value);
  }
  final expressions = <Map<String, Object?>>[];
  for (final expression in refs['Expressions'] is List ? refs['Expressions'] as List : const []) {
    asset((expression as Map)['File'], 'expression');
    expressions.add(_exportFields(expression, ['Name', 'File', 'FadeInTime', 'FadeOutTime']));
  }
  final motions = <String, Object?>{};
  if (refs['Motions'] is Map) {
    for (final group in (refs['Motions'] as Map).entries) {
      motions[group.key as String] = [for (final motion in group.value as List) _exportFields(motion, ['File', 'FadeInTime', 'FadeOutTime'])];
      for (final motion in group.value as List) { asset((motion as Map)['File'], 'motion'); }
    }
  }
  return {
    'Version': 3,
    'FileReferences': {
      ..._exportFields(refs, ['Moc', 'Physics', 'Pose']),
      'Textures': List<String>.from(refs['Textures'] as List),
      if (expressions.isNotEmpty) 'Expressions': expressions,
      if (motions.isNotEmpty) 'Motions': motions,
    },
    if (raw['Groups'] is List) 'Groups': [
      for (final group in raw['Groups'] as List) {..._exportFields(group, ['Target', 'Name']), 'Ids': _exportNames((group as Map)['Ids'])},
    ],
    if (raw['HitAreas'] is List) 'HitAreas': [for (final area in raw['HitAreas'] as List) _exportFields(area, ['Id', 'Name'])],
    if (raw['Layout'] is Map) 'Layout': _exportNumbers(raw['Layout']),
  };
}

Map<String, Object?> _exportModelAsset(Map<String, Object?> raw, String role) {
  switch (role) {
    case 'expression':
      return {
        ..._exportFields(raw, ['Type', 'FadeInTime', 'FadeOutTime']),
        'Parameters': [for (final p in raw['Parameters'] is List ? raw['Parameters'] as List : const []) _exportFields(p, ['Id', 'Value', 'Blend'])],
      };
    case 'motion':
      return {
        ..._exportFields(raw, ['Version', 'FadeInTime', 'FadeOutTime']),
        'Meta': {
          ..._exportFields(raw['Meta'], ['Duration', 'Fps', 'Loop', 'AreBeziersRestricted', 'CurveCount', 'TotalSegmentCount', 'TotalPointCount', 'FadeInTime', 'FadeOutTime']),
          'UserDataCount': 0, 'TotalUserDataSize': 0,
        },
        'Curves': [for (final curve in raw['Curves'] is List ? raw['Curves'] as List : const []) {
          ..._exportFields(curve, ['Target', 'Id', 'FadeInTime', 'FadeOutTime']),
          'Segments': [if (curve is Map && curve['Segments'] is List) for (final n in curve['Segments'] as List) if (n is num && n.isFinite) n],
        }],
      };
    case 'pose':
      return {
        ..._exportFields(raw, ['Type', 'FadeInTime']),
        'Groups': [for (final group in raw['Groups'] is List ? raw['Groups'] as List : const [])
          if (group is List) [for (final part in group) {
            ..._exportFields(part, ['Id']),
            if (part is Map && part['Link'] is List) 'Link': _exportNames(part['Link']),
          }],
        ],
      };
    case 'physics':
      final meta = raw['Meta'] is Map ? raw['Meta'] as Map : const {};
      final forces = meta['EffectiveForces'] is Map ? meta['EffectiveForces'] as Map : const {};
      return {
        ..._exportFields(raw, ['Version']),
        'Meta': {
          ..._exportFields(meta, ['PhysicsSettingCount', 'TotalInputCount', 'TotalOutputCount', 'VertexCount', 'Fps']),
          'EffectiveForces': {for (final key in ['Gravity', 'Wind']) key: _exportNumbers(forces[key], {'X', 'Y'})},
        },
        'PhysicsSettings': [for (final setting in raw['PhysicsSettings'] is List ? raw['PhysicsSettings'] as List : const [])
          if (setting is Map) {
            ..._exportFields(setting, ['Id']),
            'Input': [for (final item in setting['Input'] is List ? setting['Input'] as List : const []) {
              ..._exportFields(item, ['Weight', 'Type', 'Reflect']),
              'Source': _exportFields((item as Map)['Source'], ['Target', 'Id']),
            }],
            'Output': [for (final item in setting['Output'] is List ? setting['Output'] as List : const []) {
              ..._exportFields(item, ['VertexIndex', 'Scale', 'Weight', 'Type', 'Reflect']),
              'Destination': _exportFields((item as Map)['Destination'], ['Target', 'Id']),
            }],
            'Vertices': [for (final vertex in setting['Vertices'] is List ? setting['Vertices'] as List : const []) {
              ..._exportFields(vertex, ['Mobility', 'Delay', 'Acceleration', 'Radius']),
              'Position': _exportNumbers((vertex as Map)['Position'], {'X', 'Y'}),
            }],
            'Normalization': {for (final key in ['Position', 'Angle']) key: _exportNumbers(
              setting['Normalization'] is Map ? (setting['Normalization'] as Map)[key] : null, {'Minimum', 'Default', 'Maximum'})},
          },
        ],
      };
    default:
      throw const _CompanionIntegrity('companion_bad_reference');
  }
}

Future<void> _exportCompanion((String, String, Map<String, String>) args) async {
  final (pack, destination, overrides) = args;
  final temporary = File('$destination.part-${DateTime.now().microsecondsSinceEpoch}');
  try {
    final inventory = await _characterInventory(Directory('$pack/character'));
    // stage.js falls back to the first model in index order. Sorting here
    // would silently export another character from a multi-model local pack.
    final selected = inventory.character['model'] as String? ?? inventory.models.keys.first;
    _complete(!RegExp(r'[\u0000:%?#]').hasMatch(selected), 'companion_bad_reference');
    final home = selected.substring(0, selected.lastIndexOf('/') + 1);
    final assets = <String, String>{};
    final model = _exportModel(inventory.models[selected]!, assets, home);
    // The stage also loads unlisted exp3/motion3 resources by filename.
    for (final name in inventory.index) {
      if (name.toLowerCase().endsWith('.exp3.json')) assets.putIfAbsent(name, () => 'expression');
      if (name.toLowerCase().endsWith('.motion3.json')) assets.putIfAbsent(name, () => 'motion');
    }
    final character = {
      'schema': 1, 'model': selected, 'name': overrides['name'] ?? 'Companion',
      for (final key in ['author', 'license', 'source'])
        if (overrides[key] ?? inventory.character[key] case final String value) key: value,
      if (overrides['persona'] case final String persona) 'persona': persona,
      ...(_exportAdapter(inventory.character)..remove('moc')..remove('adapter')),
    };
    _complete(workshopText(character['name'], 160), 'companion_bad_metadata');
    _complete(overrides['persona'] == null || overrides['persona']!.runes.length <= 6000 &&
      !overrides['persona']!.runes.any((r) => r >= 0xd800 && r <= 0xdfff), 'companion_bad_metadata');
    final archive = Archive();
    var expanded = 0;
    final writtenNames = <String>{};
    void add(String name, List<int> bytes) {
      _complete(isSafePackPath(name) && !name.contains(':'), 'companion_bad_reference');
      _complete(writtenNames.add(petNameAlias(name)), 'companion_bad_reference');
      expanded += bytes.length;
      _complete(expanded <= workshopExpandedBytes && bytes.length <= companionMemberCap && archive.files.length < 1000, 'companion_too_large');
      _complete(bytes.isNotEmpty, 'companion_empty_file');
      if (_extension(name) == '.json') _complete(bytes.length <= companionJsonCap, 'companion_too_large');
      if (_extension(name) == '.png') {
        final size = pngSize(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
        _complete(size != null && size.$1 <= companionTextureSide && size.$2 <= companionTextureSide, 'companion_bad_png');
      }
      archive.add(ArchiveFile.bytes('character/$name', bytes));
    }
    add('character.json', utf8.encode(jsonEncode(character)));
    add(selected, utf8.encode(jsonEncode(model)));
    for (final entry in assets.entries) {
      final file = inventory.files[entry.key];
      _complete(file != null, 'companion_missing_reference');
      if (entry.value == 'moc' || entry.value == 'texture') {
        add(entry.key, await _companionBytes(file!, companionMemberCap));
      } else {
        final raw = await _companionJson(file!);
        _complete(raw is Map<String, Object?>, 'companion_bad_json');
        add(entry.key, utf8.encode(jsonEncode(_exportModelAsset(raw as Map<String, Object?>, entry.value))));
      }
    }
    if (inventory.files['adapter.json'] case final File adapter) {
      final raw = await _companionJson(adapter);
      add('adapter.json', utf8.encode(jsonEncode(_exportAdapter(raw))));
    }
    // Preserve explicit licence/notice files, never arbitrary notes/readmes.
    final licenseName = RegExp(r'^(?:license|copying|notice)\.(?:txt|md)$', caseSensitive: false);
    for (final entry in inventory.files.entries) {
      if (licenseName.hasMatch(entry.key.split('/').last)) {
        final text = await _companionBytes(entry.value, 64 * 1024);
        if (text.isNotEmpty) add(entry.key, text);
      }
    }
    final bytes = ZipEncoder().encode(archive);
    _complete(bytes.length <= workshopArchiveBytes, 'companion_too_large');
    final target = File(destination);
    _complete(!await target.exists(), 'companion_export_exists');
    await target.parent.create(recursive: true);
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(destination);
  } on _CompanionIntegrity catch (error) {
    throw CompanionPackException(error.code == 'companion_too_large' ? CompanionPackProblem.tooLarge : CompanionPackProblem.notAPack, error.code);
  } on FileSystemException catch (error) {
    throw CompanionPackException(CompanionPackProblem.storage, null, error.osError?.errorCode);
  } on TypeError {
    throw const CompanionPackException(CompanionPackProblem.notAPack, 'companion_bad_json');
  } finally {
    try { if (await temporary.exists()) await temporary.delete(); } on FileSystemException { /* A later cache cleanup can remove it. */ }
  }
}
