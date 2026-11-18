part of 'engine.dart';

extension _GameplayCharacterExports on TavernEngine {
  Future<_GameplayExportPlan> _captureGameplayCharacterExport(TavernGameplayExportRequest request) async {
    final context = request.context!;
    final selectedKeys = {for (final value in request.packResources) (value.bindingId, value.localId)};
    final captured = await _captureGameplayResolution(context, extraResources: selectedKeys);
    final resolution = captured.resolution;
    final card = captured.cards[context.characterId]!;
    final raw = _authoringCopy(card.document)! as Map<String, Object?>;
    final data = raw['data']! as Map<String, Object?>;
    final issues = <Map<String, Object?>>[
      for (final conflict in resolution.conflicts) {...conflict, 'blocking': conflict['code'] != 'not_composed'},
    ];
    final mappings = <Map<String, Object?>>[];
    final projection = _GameplayExportProjection(resolution, issues);
    _reserveGameplayExportLegacyIds(projection, data);
    for (final definition in resolution.definitions) {
      if (definition['present'] == true && definition['compositionEligible'] == false) {
        issues.add(
          _gameplayExportIssue(
            'export_definition_ineligible',
            'A disabled composition cannot be exported as an ordinary executable card.',
            path: definition['path']! as String,
          ),
        );
      }
    }
    final extensions = data['extensions'];
    Map<String, Object?>? dshgo;
    final hasDeclaration =
        resolution.rawPresent ||
        resolution.sources.any(
          (source) =>
              source['kind'] == 'pack' &&
              source['enabled'] == true &&
              source['available'] == true &&
              source['removed'] != true &&
              source['rawPresent'] == true &&
              (source['roles']! as List<Object?>).contains('definition'),
        );
    if (hasDeclaration && resolution.effective is Map<String, Object?>) {
      dshgo = projection.definitions();
      if (extensions == null && !data.containsKey('extensions')) {
        data['extensions'] = <String, Object?>{'dshgo': dshgo};
      } else if (extensions is Map<String, Object?>) {
        extensions['dshgo'] = dshgo;
      } else {
        issues.add(
          _gameplayExportIssue(
            'export_extensions_shape',
            'The actual character extensions cannot hold the composed declaration.',
            path: '/data/extensions',
          ),
        );
      }
    }
    final selected = <Map<String, Object?>>[];
    final found = <(String, String)>{};
    for (final row in resolution.resources) {
      final source = row['source']! as Map<String, Object?>;
      final resource = row['resource']! as Map<String, Object?>;
      final key = (source['bindingId'] as String?, resource['localId'] as String?);
      if (source['kind'] == 'pack' && selectedKeys.contains(key)) {
        found.add((key.$1!, key.$2!));
        selected.add(row);
      }
    }
    for (final key in selectedKeys.difference(found)) {
      issues.add(
        _gameplayExportIssue(
          'export_resource_unavailable',
          'The selected binding/resource is not available in this actual context.',
          source: {'kind': 'pack', 'bindingId': key.$1},
          path: key.$2,
        ),
      );
    }
    final files = <String, Uint8List>{
      if (request.copyCardMedia)
        for (final entry in card.character!.card.assets.entries) entry.key: Uint8List.fromList(entry.value),
    };
    final png = request.copyCardMedia && card.character!.card.png != null
        ? Uint8List.fromList(card.character!.card.png!)
        : null;
    final avatar = request.copyCardMedia && card.character!.card.avatar != null
        ? Uint8List.fromList(card.character!.card.avatar!)
        : null;
    final usedPaths = <String>{...card.character!.card.assets.keys, 'card.json'};
    void reserveUris(Object? value) {
      if (value is List<Object?>) {
        for (final row in value.whereType<Map<String, Object?>>()) {
          final uri = row['uri'];
          if (uri is String) {
            final path = embeddedCardAssetPath(uri);
            if (path != null) {
              usedPaths.add(path);
            }
          }
        }
      }
    }

    reserveUris(data['assets']);
    String allocatePath(String namespace, String identity, String original) {
      final prefix = 'dshgo-$namespace/${_directorHash(identity).substring(0, 20)}';
      var path = '$prefix/$original';
      var suffix = 1;
      while (!usedPaths.add(path)) {
        path = '$prefix-${suffix++}/$original';
      }
      return path;
    }

    final assetUris = <(String, String), String>{};
    for (final row in selected.where((row) => row['kind'] == 'asset')) {
      final source = row['source']! as Map<String, Object?>;
      final resource = row['resource']! as Map<String, Object?>;
      final ref = source['packRef']! as Map<String, Object?>;
      final original = resource['path']! as String;
      final localId = resource['localId']! as String;
      final bindingId = source['bindingId']! as String;
      final bytes =
          captured.snapshot.packs[(ref['installedPackId']! as String, ref['packVersion']! as String)]?.files[original];
      if (bytes == null) {
        issues.add(
          _gameplayExportIssue(
            'export_media_missing',
            'The selected asset bytes are absent from the captured catalog version.',
            source: source,
            path: original,
          ),
        );
        continue;
      }
      if (!isSafeCardAssetPath(original)) {
        issues.add(
          _gameplayExportIssue(
            'export_resource_path',
            'This new archive path cannot be preserved exactly by the existing codec.',
            source: source,
            path: original,
          ),
        );
        continue;
      }
      final path = allocatePath('packs', bindingId, original);
      files[path] = Uint8List.fromList(bytes);
      final uri = request.format == TavernCardFormat.charx ? 'embeded://$path' : cardAssetDataUri(original, bytes);
      assetUris[(bindingId, localId)] = uri;
      mappings.add({
        'kind': 'asset',
        'source': source,
        'localId': localId,
        'originalPath': original,
        'exportedPath': path,
        'uri': uri,
      });
    }
    final rewrittenAssets = <String>{};
    if (dshgo != null) {
      for (final ref in projection.assetReferences) {
        final source = ref['source']! as Map<String, Object?>;
        final path = projection.destination(source, ref['pointer']! as String);
        if (path == null) {
          continue;
        }
        String? uri;
        if (ref['resolved'] == true) {
          final target = ref['target']! as Map<String, Object?>;
          uri = assetUris[(target['bindingId']! as String, ref['localId']! as String)];
        }
        if (ref['resolved'] != true || uri == null) {
          issues.add(
            _gameplayExportIssue(
              'export_asset_selection_required',
              'Select the actual asset resource referenced by this exported declaration.',
              source: source,
              path: ref['pointer']! as String,
            ),
          );
          continue;
        }
        _putGameplayExportReference(dshgo, path, uri, issues, source: source);
        rewrittenAssets.add(path);
      }
    }

    final copiedCardUris = <(String, String), String>{};
    String? cardUri(Map<String, Object?> source, String uri, String pointer) {
      final original = embeddedCardAssetPath(uri);
      if (original == null && uri != 'ccdefault:') {
        if (uri.startsWith('embeded://') || uri.startsWith('embedded://') || uri.startsWith('__asset:')) {
          issues.add(
            _gameplayExportIssue(
              'export_media_uri',
              'The original local asset URI has no safe relative path.',
              source: source,
              path: pointer,
            ),
          );
        }
        return null;
      }
      if (source['kind'] != 'card') {
        issues.add(
          _gameplayExportIssue(
            'export_asset_reference_required',
            'A local pack asset requires an explicit supported source/localId reference.',
            source: source,
            path: pointer,
          ),
        );
        return null;
      }
      final characterId = source['characterId']! as String;
      final holder = captured.cards[characterId];
      final bytes = original == null ? holder?.character?.card.png : holder?.character?.card.assets[original];
      if (!request.copyCardMedia || bytes == null) {
        issues.add(
          _gameplayExportIssue(
            'export_media_missing',
            'Enable card media copying and retain the actual referenced local bytes.',
            source: source,
            path: pointer,
          ),
        );
        return null;
      }
      final key = (characterId, uri);
      final known = copiedCardUris[key];
      if (known != null) {
        return known;
      }
      final String output;
      if (request.format != TavernCardFormat.charx) {
        output = cardAssetDataUri(original ?? 'portrait.png', bytes);
      } else if (characterId == context.characterId && original != null) {
        output = uri;
      } else {
        final path = allocatePath('cards', characterId, original ?? 'portrait.png');
        files[path] = Uint8List.fromList(bytes);
        output = 'embeded://$path';
        mappings.add({
          'kind': 'cardAsset',
          'source': source,
          'originalPath': original,
          'exportedPath': path,
          'uri': output,
        });
      }
      copiedCardUris[key] = output;
      return output;
    }

    final baseSource = <String, Object?>{'kind': 'card', 'characterId': context.characterId};
    final assets = data['assets'];
    if (assets is List<Object?>) {
      for (final (index, asset) in assets.indexed) {
        if (asset is! Map<String, Object?> || asset['uri'] is! String) {
          continue;
        }
        final uri = asset['uri']! as String;
        // A base PNG icon keeps the existing codec's ccdefault portrait route.
        if (uri == 'ccdefault:' && asset['type'] == 'icon' && png != null) {
          continue;
        }
        final replacement = cardUri(baseSource, uri, '/data/assets/$index/uri');
        if (replacement != null) {
          asset['uri'] = replacement;
        }
      }
    }
    if (dshgo != null) {
      for (final path in _gameplayExportAssetPointers(dshgo)) {
        if (rewrittenAssets.contains(path)) {
          continue;
        }
        final value = _authoringLookup(dshgo, _gameplayCompositionPointer(path)!).value;
        if (value is! String) {
          continue;
        }
        final source = projection.sourceAt(path) ?? projection.host;
        final replacement = cardUri(source, value, path);
        if (replacement != null) {
          _putGameplayExportReference(dshgo, path, replacement, issues, source: source);
        }
      }
    }
    _appendGameplayExportBooks(selected, data, projection, mappings, issues);
    _appendGameplayExportRegex(selected, data, projection, mappings, issues);
    for (final row in selected.where(
      (row) => row['kind'] != 'asset' && row['kind'] != 'lorebook' && row['kind'] != 'regex',
    )) {
      issues.add(
        _gameplayExportIssue(
          'export_resource_kind',
          'This resource has no defined merged-character consumer; use cast import or original pack export.',
          source: row['source']! as Map<String, Object?>,
          path: (row['resource']! as Map<String, Object?>)['localId']! as String,
        ),
      );
    }
    for (final path in files.keys) {
      if (!isSafeCardAssetPath(path) ||
          path == 'card.json' ||
          request.format == TavernCardFormat.charx && path.startsWith('\uFEFF')) {
        issues.add(
          _gameplayExportIssue(
            'export_resource_path',
            'The captured card file cannot be written without changing its path.',
            source: baseSource,
            path: path,
          ),
        );
      }
    }
    var provenanceKey = 'dshgo_export_sources';
    var suffix = 1;
    while (raw.containsKey(provenanceKey)) {
      provenanceKey = 'dshgo_export_sources_${suffix++}';
    }
    raw[provenanceKey] = {
      'v': 1,
      'sources': _authoringCopy(resolution.sources),
      'packs': [
        for (final pack in captured.snapshot.packs.values)
          if (pack.version case final version?)
            {
              'packRef': version.ref.toJson(),
              'manifestRaw': version.manifestRaw,
              'manifest': _authoringCopy(version.manifest),
            },
      ],
      'resources': _authoringCopy(selected),
      'idMappings': projection.idMappings,
      'resourceMappings': mappings,
      'card': {'characterId': context.characterId, 'raw': _authoringCopy(card.document)},
    };
    data['modification_date'] = request.at.toUtc().millisecondsSinceEpoch ~/ 1000;
    final avatarAssets = data['assets'];
    if (avatar != null && avatarAssets != null && avatarAssets is! List<Object?>) {
      issues.add(
        _gameplayExportIssue(
          'export_avatar_assets_shape',
          'The selected avatar requires an array of character assets.',
          path: '/data/assets',
        ),
      );
    }
    try {
      const CardCodec().validateAuthority(raw);
    } on FormatException catch (error) {
      issues.add(_gameplayExportIssue('export_card_structure', error.message.toString()));
    } on TavernImportError catch (error) {
      issues.add(_gameplayExportIssue('export_card_structure', error.toString()));
    }
    final sources = <Map<String, Object?>>[
      ...resolution.sources,
      for (final resource in selected)
        {
          'kind': 'packResource',
          'source': resource['source'],
          'resource': resource['resource'],
          'raw': resource['raw'],
          'entries': resource['entries'],
          'inspection': resource['inspection'],
        },
      {
        'kind': 'exportCard',
        'characterId': context.characterId,
        'definitionHostCharacterId': resolution.hostCharacterId,
        'sourceFormat': card.sourceFormat,
        'snapshot': card.snapshot.toJson(),
        'provenanceKey': provenanceKey,
      },
    ];
    Future<void> recheck() => _recheckCapturedAuthoringResources(captured.resources.values, check: captured.check);
    final preview = _gameplayExportPreview(
      request: request,
      sources: sources,
      mergedRaw: raw,
      idMappings: projection.idMappings,
      resourceMappings: mappings,
      issues: issues,
      files: files,
      png: png,
      avatar: avatar,
      facts: {
        'effectiveConfigId': resolution.effectiveConfigId,
        'bindings': _gameplayBindingIdentity(captured.snapshot),
        'resourcePlan': resolution.resources,
        'capturedResources': [
          for (final resource in captured.resources.values)
            {
              'physicalResourceId': resource.target.physicalResourceId,
              'snapshot': resource.snapshot.toJson(),
              'media': {
                for (final entry in resource.media.entries) entry.key: crypto.sha256.convert(entry.value).toString(),
              },
            },
        ],
      },
    );
    return _GameplayExportPlan(
      request: request,
      preview: preview,
      files: files,
      png: png,
      avatar: avatar,
      recheck: recheck,
    );
  }
}

void _reserveGameplayExportLegacyIds(_GameplayExportProjection projection, Map<String, Object?> data) {
  projection.reserveDeclaration(_map(data['extensions'])['dshgo']);
  final entries = _map(data['character_book'])['entries'];
  if (entries is List<Object?>) {
    for (final (index, row) in entries.indexed) {
      if (row is Map<String, Object?>) {
        projection.reserve('worldInfo', (row['id'] ?? index).toString());
      }
    }
  } else if (entries is Map<String, Object?>) {
    for (final row in entries.entries) {
      projection.reserve('worldInfo', row.key);
      if (row.value is Map<String, Object?>) {
        projection.reserve('worldInfo', ((row.value! as Map<String, Object?>)['uid'] ?? row.key).toString());
      }
    }
  }
  final scripts = _map(data['extensions'])['regex_scripts'];
  if (scripts is List<Object?>) {
    for (final row in scripts.whereType<Map<String, Object?>>()) {
      projection.reserve('regex', RegexScript.fromJson(row).id);
      projection.reserve('regex', row['id']);
    }
  }
}

Iterable<String> _gameplayExportAssetPointers(Map<String, Object?> raw) sync* {
  final theme = raw['theme'];
  if (theme is Map<String, Object?>) {
    if (theme.containsKey('background')) {
      yield '/theme/background';
    }
    final fonts = theme['fonts'];
    if (fonts is Map<String, Object?>) {
      for (final key in fonts.keys) {
        yield '/theme/fonts/${_gameplayPointerToken(key)}';
      }
    }
  }
  final cast = raw['cast'];
  if (cast is List<Object?>) {
    for (final (index, member) in cast.indexed) {
      if (member is! Map<String, Object?>) {
        continue;
      }
      if (member.containsKey('sprites')) {
        yield '/cast/$index/sprites';
      }
      final assets = _map(member['card'])['assets'];
      if (assets is List<Object?>) {
        for (final (assetIndex, asset) in assets.indexed) {
          if (asset is Map<String, Object?> && asset.containsKey('uri')) {
            yield '/cast/$index/card/assets/$assetIndex/uri';
          }
        }
      }
    }
  }
}

void _appendGameplayExportBooks(
  List<Map<String, Object?>> selected,
  Map<String, Object?> data,
  _GameplayExportProjection projection,
  List<Map<String, Object?>> mappings,
  List<Map<String, Object?>> issues,
) {
  final books = selected.where((row) => row['kind'] == 'lorebook').toList();
  if (books.isEmpty) {
    return;
  }
  final original = data['character_book'];
  final Map<String, Object?> book;
  if (!data.containsKey('character_book')) {
    book = <String, Object?>{'entries': <Object?>[]};
    data['character_book'] = book;
  } else if (original is Map<String, Object?> &&
      (original['entries'] is List<Object?> || original['entries'] is Map<String, Object?>)) {
    book = original;
  } else {
    issues.add(
      _gameplayExportIssue(
        'export_world_info_container',
        'Selected books cannot replace an invalid or explicit-null original character book.',
        path: '/data/character_book',
      ),
    );
    return;
  }
  final values = book['entries']!;
  final characterBook = values is List<Object?>;
  for (final row in books) {
    final source = row['source']! as Map<String, Object?>;
    final resource = row['resource']! as Map<String, Object?>;
    final localId = resource['localId']! as String;
    final originalBook = WorldInfoBook.fromJson(
      id: localId,
      source: WorldInfoSource.values.byName(row['bucket']! as String),
      json: row['raw']! as Map<String, Object?>,
    );
    final declared = {
      for (final entry in (row['entries']! as List<Object?>).cast<Map<String, Object?>>())
        entry['pointer']! as String: entry['localId']! as String,
    };
    final entries = <Map<String, Object?>>[];
    for (final entry in originalBook.entries) {
      final entryLocalId = declared[entry.sourcePointer]!;
      final id = projection.id('worldInfo', source, entryLocalId, resourceLocalId: localId);
      final path = values is List<Object?>
          ? '/data/character_book/entries/${values.length}'
          : '/data/character_book/entries/${_gameplayPointerToken(id)}';
      try {
        final converted = exportGameplayWorldInfoEntry(entry, id: id, characterBook: characterBook);
        if (values is List<Object?>) {
          values.add(converted);
        } else {
          (values as Map<String, Object?>)[id] = converted;
        }
        entries.add({
          'localId': entryLocalId,
          'originalPointer': entry.sourcePointer,
          'exportedId': id,
          'exportedPointer': path,
        });
      } on FormatException catch (error) {
        issues.add(
          _gameplayExportIssue(
            'export_world_info_conversion',
            error.message.toString(),
            source: source,
            path: entry.sourcePointer,
          ),
        );
      }
    }
    mappings.add({
      'kind': 'lorebook',
      'source': source,
      'localId': localId,
      'originalBucket': row['bucket'],
      'entries': entries,
    });
    issues.add(
      _gameplayExportIssue(
        'export_resource_scope_flattened',
        'World-info entries move into one embedded character book; source buckets, cross-book selection and runtime timers are not portable.',
        blocking: false,
        source: source,
        path: localId,
      ),
    );
  }
}

void _appendGameplayExportRegex(
  List<Map<String, Object?>> selected,
  Map<String, Object?> data,
  _GameplayExportProjection projection,
  List<Map<String, Object?>> mappings,
  List<Map<String, Object?>> issues,
) {
  final scripts = selected.where((row) => row['kind'] == 'regex').toList();
  if (scripts.isEmpty) {
    return;
  }
  final rawExtensions = data['extensions'];
  final Map<String, Object?> extensions;
  if (!data.containsKey('extensions')) {
    extensions = <String, Object?>{};
    data['extensions'] = extensions;
  } else if (rawExtensions is Map<String, Object?>) {
    extensions = rawExtensions;
  } else {
    issues.add(
      _gameplayExportIssue(
        'export_regex_container',
        'Selected regex cannot replace the actual non-object extensions.',
        path: '/data/extensions',
      ),
    );
    return;
  }
  final old = extensions['regex_scripts'];
  if (extensions.containsKey('regex_scripts') && old is! List<Object?>) {
    issues.add(
      _gameplayExportIssue(
        'export_regex_container',
        'Selected regex cannot replace the actual non-array original scripts.',
        path: '/data/extensions/regex_scripts',
      ),
    );
    return;
  }
  final before = <Object?>[], after = <Object?>[];
  for (final row in scripts) {
    final source = row['source']! as Map<String, Object?>;
    final resource = row['resource']! as Map<String, Object?>;
    final localId = resource['localId']! as String;
    final output = row['bucket'] == 'global' ? before : after;
    final entries = <Map<String, Object?>>[];
    for (final entry in (row['entries']! as List<Object?>).cast<Map<String, Object?>>()) {
      final value = _authoringCopy(entry['raw'])! as Map<String, Object?>;
      final id = projection.id('regex', source, entry['localId']! as String, resourceLocalId: localId);
      value['id'] = id;
      // Keep the saved native intake veto even when its original raw row was
      // enabled. Current scope/global switches are shown below, not persisted
      // as an invented card-local setting.
      if (entry['disabled'] == true) {
        value['disabled'] = true;
      }
      output.add(value);
      entries.add({
        'localId': entry['localId'],
        'originalPointer': entry['pointer'],
        'exportedId': id,
        'disabled': entry['disabled'],
        'currentEffective': entry['effective'],
      });
    }
    mappings.add({
      'kind': 'regex',
      'source': source,
      'localId': localId,
      'originalBucket': row['bucket'],
      'currentEnabled': resource['enabled'],
      'entries': entries,
    });
    issues.add(
      _gameplayExportIssue(
        'export_resource_scope_flattened',
        'Selected regex becomes card-local; current global/preset/character switches and ambient scripts are not exported.',
        blocking: false,
        source: source,
        path: localId,
      ),
    );
  }
  extensions['regex_scripts'] = [...before, if (old is List<Object?>) ...old, ...after];
}
