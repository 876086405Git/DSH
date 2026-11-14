part of 'engine.dart';

final class _GameplayExportPlan {
  const _GameplayExportPlan({
    required this.request,
    required this.preview,
    required this.files,
    required this.recheck,
    this.png,
    this.avatar,
  });
  final TavernGameplayExportRequest request;
  final TavernGameplayExportPreview preview;

  /// Card assets, or pack files excluding the generated root pack.json.
  final Map<String, Uint8List> files;
  final Uint8List? png, avatar;
  final Future<void> Function() recheck;
}

extension _GameplayExports on TavernEngine {
  Future<TavernGameplayExportPreview> _previewGameplayExport(TavernGameplayExportRequest input) =>
      _authoringOperation(() async {
        final request = _captureGameplayExportRequest(input);
        final plan = await _captureGameplayExport(request);
        await plan.recheck();
        return plan.preview;
      });

  Future<Uint8List> _exportCharacterWithPacks(TavernGameplayExportRequest input, String expectedPreviewId) =>
      _exportGameplay(input, expectedPreviewId, TavernGameplayExportKind.character);

  Future<Uint8List> _exportGameplayPackFromDraft(TavernGameplayExportRequest input, String expectedPreviewId) =>
      _exportGameplay(input, expectedPreviewId, TavernGameplayExportKind.pack);

  Future<Uint8List> _exportGameplay(
    TavernGameplayExportRequest input,
    String expectedPreviewId,
    TavernGameplayExportKind kind,
  ) => _authoringOperation(() async {
    final request = _captureGameplayExportRequest(input);
    if (request.kind != kind || expectedPreviewId.isEmpty) {
      _invalidGameplayExport('Use the matching export method and a captured preview identity.');
    }
    final plan = await _captureGameplayExport(request);
    if (plan.preview.previewId != expectedPreviewId) {
      throw const TavernGameplayException(
        code: 'export_preview_conflict',
        message: 'The export request or one of its captured sources changed.',
      );
    }
    if (plan.preview.issues.any((issue) => issue['blocking'] == true)) {
      throw TavernGameplayException(
        code: 'export_conflict',
        message: 'The captured export plan has unresolved conflicts.',
        details: {'issues': plan.preview.issues},
      );
    }
    await plan.recheck();
    final bytes = await _encodeGameplayExport(
      request.kind,
      plan.preview.mergedRaw,
      plan.files,
      plan.png,
      plan.avatar,
      request.format,
      request.at,
    );
    await plan.recheck();
    return bytes;
  });

  Future<_GameplayExportPlan> _captureGameplayExport(TavernGameplayExportRequest request) =>
      request.kind == TavernGameplayExportKind.character
      ? _captureGameplayCharacterExport(request)
      : _captureGameplayDraftExport(request);
}

/// CPU work receives owned data only. No live engine, SQL connection, source
/// resolver or recheck closure is captured into this worker.
Future<Uint8List> _encodeGameplayExport(
  TavernGameplayExportKind kind,
  Map<String, Object?> raw,
  Map<String, Uint8List> files,
  Uint8List? png,
  Uint8List? avatar,
  TavernCardFormat? format,
  DateTime at,
) => Isolate.run(() {
  if (kind == TavernGameplayExportKind.character) {
    return const CardCodec().encode(
      TavernCard(json: raw, assets: files, png: png, avatar: avatar),
      format: format!,
      modifiedAt: at,
    );
  }
  return encodeGameplayPack(raw, files, at: at);
});

TavernGameplayExportPreview _gameplayExportPreview({
  required TavernGameplayExportRequest request,
  required List<Map<String, Object?>> sources,
  required Map<String, Object?> mergedRaw,
  required List<Map<String, Object?>> idMappings,
  required List<Map<String, Object?>> resourceMappings,
  required List<Map<String, Object?>> issues,
  required Map<String, Uint8List> files,
  Uint8List? png,
  Uint8List? avatar,
  Map<String, Object?> facts = const {},
}) {
  final paths = files.keys.toList()..sort();
  final identity = _directorHash({
    'v': 1,
    'request': request.toJson(),
    'sources': sources,
    'facts': facts,
    'mergedRaw': mergedRaw,
    'idMappings': idMappings,
    'resourceMappings': resourceMappings,
    'issues': issues,
    'files': [
      for (final path in paths)
        {'path': path, 'length': files[path]!.length, 'sha256': crypto.sha256.convert(files[path]!).toString()},
    ],
    if (png != null) 'png': {'length': png.length, 'sha256': crypto.sha256.convert(png).toString()},
    if (avatar != null) 'avatar': {'length': avatar.length, 'sha256': crypto.sha256.convert(avatar).toString()},
  });
  return TavernGameplayExportPreview(
    previewId: identity,
    sources: sources,
    mergedRaw: mergedRaw,
    idMappings: idMappings,
    resourceMappings: resourceMappings,
    issues: issues,
  );
}

Map<String, Object?> _gameplayExportIssue(
  String code,
  String message, {
  bool blocking = true,
  Map<String, Object?>? source,
  String? path,
}) => {'code': code, 'message': message, 'blocking': blocking, 'source': ?source, 'path': ?path};

TavernGameplayExportRequest _captureGameplayExportRequest(TavernGameplayExportRequest input) {
  final Map<String, Object?> json;
  try {
    json = jsonDecode(jsonEncode(input.toJson())) as Map<String, Object?>;
  } on JsonUnsupportedObjectError {
    _invalidGameplayExport('Export parameters must contain only finite JSON values.');
  }
  final at = DateTime.parse(json['at']! as String);
  if (input.kind == TavernGameplayExportKind.character) {
    final context = json['context']! as Map<String, Object?>;
    final seen = <(String, String)>{};
    final resources = <TavernGameplayPackResourceRef>[];
    for (final value in json['packResources']! as List<Object?>) {
      final row = value! as Map<String, Object?>;
      final binding = row['bindingId']! as String, local = row['localId']! as String;
      if (binding.isEmpty || local.isEmpty || !seen.add((binding, local))) {
        _invalidGameplayExport('Select distinct explicit binding/resource identities.');
      }
      resources.add(TavernGameplayPackResourceRef(bindingId: binding, localId: local));
    }
    return TavernGameplayExportRequest.character(
      context: TavernGameplayContext(
        characterId: context['characterId']! as String,
        chatId: context['chatId'] as String?,
      ),
      format: TavernCardFormat.values.byName(json['format']! as String),
      at: at,
      packResources: resources,
      copyCardMedia: json['copyCardMedia']! as bool,
    );
  }
  final changes = (json['changeIds']! as List<Object?>).cast<String>().toList()..sort();
  if ((json['draftId']! as String).isEmpty ||
      (json['draftRevision']! as int) < 1 ||
      (json['physicalResourceId']! as String).isEmpty ||
      (json['packId']! as String).isEmpty ||
      (json['packVersion']! as String).isEmpty ||
      changes.toSet().length != changes.length ||
      changes.any((id) => id.isEmpty)) {
    _invalidGameplayExport('Use a complete draft revision, resource, version and distinct change selection.');
  }
  final resources = <TavernGameplayDraftResource>[];
  for (final value in json['resources']! as List<Object?>) {
    final row = value! as Map<String, Object?>;
    if (row.containsKey('pointer')) {
      resources.add(
        TavernGameplayDraftResource.json(
          physicalResourceId: row['physicalResourceId']! as String,
          pointer: row['pointer']! as String,
          localId: row['localId']! as String,
          kind: row['kind']! as String,
          path: row['path']! as String,
          entries: [
            for (final entry in (row['entries']! as List<Object?>).cast<Map<String, Object?>>())
              TavernGameplayExportEntry(localId: entry['localId']! as String, pointer: entry['pointer']! as String),
          ],
        ),
      );
    } else {
      resources.add(
        TavernGameplayDraftResource.asset(
          physicalResourceId: row['physicalResourceId']! as String,
          assetUri: row['assetUri']! as String,
          localId: row['localId']! as String,
          kind: row['kind']! as String,
          path: row['path']! as String,
          media: TavernAuthoringMediaSelection.values.byName(row['media']! as String),
        ),
      );
    }
  }
  return TavernGameplayExportRequest.packFromDraft(
    draftId: json['draftId']! as String,
    draftRevision: json['draftRevision']! as int,
    physicalResourceId: json['physicalResourceId']! as String,
    changeIds: changes,
    packId: json['packId']! as String,
    packVersion: json['packVersion']! as String,
    schemaRoots: (json['schemaRoots']! as List<Object?>).cast<String>().toList(),
    draftResources: resources,
    at: at,
    references: (json['references']! as List<Object?>).cast<Map<String, Object?>>().toList(),
    manifestFields: json['manifestFields']! as Map<String, Object?>,
  );
}

Never _invalidGameplayExport(String message) =>
    throw TavernGameplayException(code: 'invalid_export_request', message: message);
