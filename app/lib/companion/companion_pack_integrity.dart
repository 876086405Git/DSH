part of 'companion_pack.dart';

/// Core enum upper bound recorded for the pinned runtime in the source
/// snapshot's companion tests; version compatibility is not Moc consistency.
const companionMaxMocVersion = 6;

/// One JSON file of a character; large motions run past 1 MiB.
const companionJsonCap = 8 * 1024 * 1024;

/// One file of a character on export; an 8192-wide PNG can pass 16 MiB.
const companionMemberCap = 32 * 1024 * 1024;

/// A texture's longest side. The WebView decodes it, so a texture is only
/// checked for being a PNG of at most this size (Live2D uses 4096 and up).
const companionTextureSide = 8192;

class _CompanionIntegrity implements Exception {
  const _CompanionIntegrity(this.code);
  final String code;
}

void _complete(bool value, String code) {
  if (!value) throw _CompanionIntegrity(code);
}

Future<Uint8List> _companionBytes(File file, int cap) async {
  _complete(await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.file, 'companion_missing_file');
  final handle = await file.open();
  try {
    final size = await handle.length();
    _complete(size <= cap, 'companion_too_large');
    final bytes = BytesBuilder(copy: false);
    while (bytes.length <= size) {
      final remaining = size + 1 - bytes.length;
      final chunk = await handle.read(remaining < 65536 ? remaining : 65536);
      if (chunk.isEmpty) break;
      bytes.add(chunk);
    }
    _complete(bytes.length == size, 'companion_changed');
    return bytes.takeBytes();
  } finally {
    await handle.close();
  }
}

Future<Object?> _companionJson(File file) async {
  try {
    var bytes = await _companionBytes(file, companionJsonCap);
    // Some editors save a UTF-8 BOM; the JSON under it is still fine.
    if (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) bytes = Uint8List.sublistView(bytes, 3);
    return decodePetJson(bytes, maxBytes: companionJsonCap);
  } on PetValidationException {
    throw const _CompanionIntegrity('companion_bad_json');
  }
}

Future<Map<String, File>> _companionFiles(Directory directory) async {
  _complete(await FileSystemEntity.type(directory.path, followLinks: false) == FileSystemEntityType.directory, 'companion_missing_file');
  final files = <String, File>{}, aliases = <String>{};
  var size = 0;
  await for (final entity in directory.list(recursive: true, followLinks: false)) {
    _complete(entity is! Link, 'companion_unsafe_path');
    if (entity is! File) continue;
    final path = entity.path.substring(directory.path.length + 1).replaceAll(Platform.pathSeparator, '/');
    _complete(isSafePackPath(path) && aliases.add(petNameAlias(path)), 'companion_unsafe_path');
    size += await entity.length();
    _complete(size <= _maxBytes && files.length < _maxFiles, 'companion_too_large');
    files[path] = entity;
  }
  return files;
}

class _CompanionInventory {
  const _CompanionInventory(this.files, this.index, this.character, this.models, this.references);
  final Map<String, File> files;
  final Set<String> index;
  final Map<String, Object?> character;
  final Map<String, Map<String, Object?>> models;
  final Set<String> references;
}

Future<_CompanionInventory> _characterInventory(Directory character) async {
  final files = await _companionFiles(character);
  _complete(files.containsKey('index.json') && files.containsKey('character.json'), 'companion_missing_index');
  final rawIndex = await _companionJson(files['index.json']!);
  _complete(rawIndex is List && rawIndex.isNotEmpty && rawIndex.length <= _maxFiles, 'companion_bad_index');
  final index = <String>{};
  for (final name in rawIndex as List) {
    _complete(name is String && isSafePackPath(name) && files.containsKey(name) && index.add(name), 'companion_bad_index');
  }
  _complete(index.contains('character.json'), 'companion_bad_index');
  final config = await _companionJson(files['character.json']!);
  _complete(config is Map<String, Object?>, 'companion_bad_json');
  final characterJson = config as Map<String, Object?>;
  final models = <String, Map<String, Object?>>{}, refs = <String>{};
  final modelNames = index.where((n) => n.toLowerCase().endsWith('.model3.json')).toList();
  _complete(modelNames.isNotEmpty, 'companion_no_model');
  final selected = characterJson['model'];
  _complete(selected == null || selected is String && modelNames.contains(selected), 'companion_missing_model');

  String reference(String home, Object? value, Set<String> extensions) {
    _complete(value is String && isSafePackPath(value) && !RegExp(r'[\u0000:%?#]').hasMatch(value), 'companion_bad_reference');
    final path = '$home$value';
    _complete(index.contains(path) && files.containsKey(path) && extensions.contains(_extension(path)), 'companion_missing_reference');
    refs.add(path);
    return path;
  }

  for (final name in modelNames) {
    final model = await _companionJson(files[name]!);
    _complete(model is Map<String, Object?> && model['Version'] == 3 && model['FileReferences'] is Map<String, Object?>, 'companion_bad_model');
    final json = model as Map<String, Object?>, fileRefs = json['FileReferences'] as Map<String, Object?>;
    final home = name.substring(0, name.lastIndexOf('/') + 1);
    final moc = reference(home, fileRefs['Moc'], {'.moc3'});
    final handle = await files[moc]!.open();
    try {
      final head = await handle.read(5);
      _complete(head.length == 5 && ascii.decode(head.sublist(0, 4), allowInvalid: true) == 'MOC3', 'companion_bad_moc');
      _complete(head[4] >= 1 && head[4] <= companionMaxMocVersion, 'companion_moc_version');
    } finally { await handle.close(); }
    final textures = fileRefs['Textures'];
    _complete(textures is List && textures.isNotEmpty && textures.length <= 64, 'companion_missing_texture');
    for (final texture in textures as List) {
      final path = reference(home, texture, {'.png', '.jpg', '.jpeg', '.webp'});
      _complete(await files[path]!.length() > 0, 'companion_missing_texture');
    }
    for (final field in ['Physics', 'Pose', 'UserData', 'DisplayInfo']) {
      if (fileRefs[field] != null) reference(home, fileRefs[field], {'.json'});
    }
    final expressions = fileRefs['Expressions'];
    _complete(expressions == null || expressions is List, 'companion_bad_reference');
    for (final exp in expressions is List ? expressions : const []) {
      _complete(exp is Map && exp['Name'] is String, 'companion_bad_reference');
      reference(home, (exp as Map)['File'], {'.json'});
    }
    final motions = fileRefs['Motions'];
    _complete(motions == null || motions is Map, 'companion_bad_reference');
    for (final group in motions is Map ? motions.values : const []) {
      _complete(group is List, 'companion_bad_reference');
      for (final motion in group as List) {
        _complete(motion is Map, 'companion_bad_reference');
        reference(home, (motion as Map)['File'], {'.json'});
        if (motion['Sound'] != null && motion['Sound'] != '') reference(home, motion['Sound'], {'.wav', '.mp3'});
      }
    }
    models[name] = json;
    refs.add(name);
  }
  for (final name in refs.where((p) => _extension(p) == '.json')) {
    _complete(await _companionJson(files[name]!) is Map<String, Object?>, 'companion_bad_json');
  }
  return _CompanionInventory(files, index, characterJson, models, refs);
}

Future<String?> _packUnavailable((String, String) args) async {
  final (pack, expectedRuntime) = args;
  try {
    final runtime = Directory('$pack/runtime');
    if (!await runtime.exists()) return 'companion_runtime_missing';
    final files = await _companionFiles(runtime);
    _complete(files.containsKey('live2dcubismcore.min.js') && files.containsKey('cubism-framework.js') &&
        files.keys.any((name) => name.startsWith('shaders/')), 'companion_runtime_incomplete');
    final hashes = <String, String>{};
    for (final file in files.entries) {
      hashes['runtime/${file.key}'] = (await sha256.bind(file.value.openRead()).first).toString();
    }
    _complete(runtimeDigest(hashes) == expectedRuntime, 'companion_runtime_mismatch');
    await _characterInventory(Directory('$pack/character'));
    return null;
  } on _CompanionIntegrity catch (error) {
    return error.code;
  } on FileSystemException {
    return 'companion_storage';
  } on FormatException {
    return 'companion_bad_json';
  }
}
