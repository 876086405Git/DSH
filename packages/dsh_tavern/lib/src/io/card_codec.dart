// PNG metadata precedence follows SillyTavern 1.19.0, src/character-card-parser.js
// (AGPL-3.0), commit 7e8663cd9c184a550b37238218bdd32c6efc68e9.
// V1 field migration follows src/endpoints/characters.js at the same commit.
// Container handling and lossless unknown-field storage are implemented here.
// CCv3: https://github.com/kwaroran/character-card-spec-v3/blob/main/SPEC_V3.md

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;

import '../api.dart';
import '../regex_library.dart';
import 'authoring_text.dart';

/// Internal container result. Its JSON has not acquired runtime defaults or
/// a format upgrade and may still need an author's explicit correction.
final class DecodedCardSeed {
  const DecodedCardSeed({
    required this.json,
    required this.rawText,
    required this.originalBytes,
    required this.sourceFormat,
    this.assets = const {},
    this.png,
  });

  final Map<String, Object?> json;
  final String rawText;
  final Uint8List originalBytes;
  final TavernCardFormat sourceFormat;
  final Map<String, Uint8List> assets;
  final Uint8List? png;
}

/// A card's complete JSON, plus the bytes its container carried.
///
/// Unknown fields are deliberately kept in [json], not projected into a smaller
/// model. [originalBytes] retains the imported file's exact representation.
class TavernCard {
  TavernCard({
    required this.json,
    this.assets = const {},
    this.png,
    this.avatar,
    this.originalBytes,
    this.sourceFormat = TavernCardFormat.json,
  });

  final Map<String, Object?> json;

  /// Paths from the CHARX or legacy PNG asset chunks, with exact file contents.
  final Map<String, Uint8List> assets;

  /// The original PNG/APNG, including its non-card chunks and animation.
  final Uint8List? png;

  /// The library's current PNG avatar, separate from the original container.
  /// Explicit resource URIs continue to resolve the original [png]/[assets].
  final Uint8List? avatar;
  final Uint8List? originalBytes;
  final TavernCardFormat sourceFormat;

  Map<String, Object?> get data => json['data'] as Map<String, Object?>;

  String get name => data['name'] as String;
  String get promptName {
    final nickname = data['nickname'];
    return nickname is String && nickname.isNotEmpty ? nickname : name;
  }

  String creatorNotes({String? language}) {
    final notes = data['creator_notes_multilingual'];
    if (notes is Map<String, Object?>) {
      final code = language?.replaceAll('_', '-').split('-').first.toLowerCase();
      final localized = notes[code];
      if (localized is String) return localized;
    }
    return _text(data['creator_notes']);
  }

  /// Resolves local asset URI forms. Remote URLs stay in JSON for the caller.
  Uint8List? assetBytes(String uri) {
    if (uri == 'ccdefault:') return png;
    final path = embeddedCardAssetPath(uri);
    if (path != null) return assets[path];
    if (uri.startsWith('data:')) {
      try {
        return UriData.parse(uri).contentAsBytes();
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  Uint8List? get iconBytes {
    if (avatar != null) {
      return avatar;
    }
    final value = data['assets'];
    if (value is List<Object?>) {
      final icons = value.whereType<Map<String, Object?>>().where((asset) => asset['type'] == 'icon').toList();
      icons.sort((a, b) => (a['name'] == 'main' ? 0 : 1).compareTo(b['name'] == 'main' ? 0 : 1));
      for (final icon in icons) {
        final uri = icon['uri'];
        if (uri is String) {
          final bytes = assetBytes(uri);
          if (bytes != null) return bytes;
        }
      }
    }
    return png;
  }

  int get regexCount {
    final regex = _map(data['extensions'])['regex_scripts'];
    return regex is List<Object?> ? regex.length : 0;
  }

  int get scriptCount {
    final extensions = _map(data['extensions']);
    final helper = _map(extensions['tavern_helper']);
    return _scriptCount(helper['scripts'] ?? extensions['TavernHelper_scripts']);
  }

  /// Projects a detached theme and declared asset objects in their stored order.
  /// The optional library resolver adds paths without changing portable URIs.
  TavernCharacter toCharacter(
    String id, {
    String? avatarPath,
    String? Function(String uri)? resolveAssetPath,
    DateTime? importedAt,
    int chatCount = 0,
    DateTime? lastChatAt,
    String? language,
    List<TavernRegexDiagnostic> regexDiagnostics = const [],
  }) {
    final extensions = _map(data['extensions']);
    final declaredAssets = data['assets'];
    final appearanceAssets = <TavernCharacterAsset>[];
    if (declaredAssets is List<Object?>) {
      for (final asset in declaredAssets.whereType<Map<String, Object?>>()) {
        final uri = _nullableText(asset['uri']);
        appearanceAssets.add(
          TavernCharacterAsset(
            type: _nullableText(asset['type']),
            name: _nullableText(asset['name']),
            uri: uri,
            ext: _nullableText(asset['ext']),
            localPath: uri == null ? null : resolveAssetPath?.call(uri),
          ),
        );
      }
    }
    return TavernCharacter(
      id: id,
      name: name,
      nickname: data['nickname'] is String ? data['nickname'] as String : null,
      creator: data['creator'] is String ? data['creator'] as String : null,
      tags: _strings(data['tags']),
      avatarPath: avatarPath,
      theme: jsonDecode(jsonEncode(_map(extensions['dshgo'])['theme'])),
      assets: appearanceAssets,
      description: _text(data['description']),
      creatorNotes: creatorNotes(language: language),
      greetings: [_text(data['first_mes']), ..._strings(data['alternate_greetings'])],
      regexCount: regexCount,
      scriptCount: scriptCount,
      hasLorebook: data['character_book'] is Map<String, Object?>,
      chatCount: chatCount,
      lastChatAt: lastChatAt,
      importedAt: importedAt,
      regexDiagnostics: regexDiagnostics,
    );
  }
}

/// Pure container codec. Run CPU work off the UI isolate (as CharacterLibrary
/// does); no asset URL is fetched and no card content is executed here.
class CardCodec {
  const CardCodec();

  /// Decodes an image directly, without reading or adopting card metadata.
  /// Callers run this CPU work in the existing image isolate boundary.
  static Uint8List avatarPng(Uint8List bytes) {
    try {
      final decoded = image.decodeImage(bytes);
      if (decoded == null) {
        throw const FormatException('The avatar is not a supported image.');
      }
      if (_startsWith(bytes, _pngSignature)) {
        _pngChunks(bytes);
        return Uint8List.fromList(bytes);
      }
      return Uint8List.fromList(image.encodePng(decoded));
    } on image.ImageException catch (error) {
      throw FormatException(error.message);
    }
  }

  /// Internal authoritative library JSON route. Validation uses a detached
  /// runtime projection; it must not adopt `_upgrade` defaults into the stored
  /// V3 data or replace the import container/media retained by the library.
  Map<String, Object?> decodeAuthority(Uint8List bytes) {
    final json = _decodeJson(bytes);
    if (json['spec'] != 'chara_card_v3' || json['spec_version'] is! String || json['data'] is! Map<String, Object?>) {
      throw const FormatException('Stored character authority must be a V3 envelope.');
    }
    _upgrade(json);
    return json;
  }

  /// Validates a proposed authoritative envelope without returning defaults.
  void validateAuthority(Map<String, Object?> json) {
    if (json['spec'] != 'chara_card_v3' || json['spec_version'] is! String || json['data'] is! Map<String, Object?>) {
      throw const FormatException('Stored character authority must be a V3 envelope.');
    }
    _upgrade(json);
  }

  TavernCard decode(Uint8List bytes) {
    try {
      if (_startsWith(bytes, _pngSignature)) return _decodePng(bytes);
      if (_startsWith(bytes, const [0x50, 0x4b, 0x03, 0x04]) || _startsWith(bytes, const [0x50, 0x4b, 0x05, 0x06])) {
        return _decodeCharx(bytes);
      }
      return TavernCard(json: _upgrade(_decodeJson(bytes)), originalBytes: bytes);
    } on TavernImportError {
      rethrow;
    } on FormatException catch (error) {
      throw TavernImportError(error.message);
    } on RangeError {
      throw const TavernImportError('角色卡文件不完整。');
    }
  }

  /// Reads the existing supported containers without adopting `_upgrade` into
  /// the seed base. Container integrity and safe asset paths still apply.
  DecodedCardSeed decodeSeed(Uint8List bytes) {
    try {
      if (_startsWith(bytes, _pngSignature)) {
        return _readPngSeed(bytes);
      }
      if (_startsWith(bytes, const [0x50, 0x4b, 0x03, 0x04]) || _startsWith(bytes, const [0x50, 0x4b, 0x05, 0x06])) {
        return _readCharxSeed(bytes);
      }
      final source = _decodeJsonSource(bytes);
      return DecodedCardSeed(
        json: source.json,
        rawText: source.rawText,
        originalBytes: bytes,
        sourceFormat: TavernCardFormat.json,
      );
    } on TavernImportError {
      rethrow;
    } on FormatException catch (error) {
      throw TavernImportError(error.message);
    } on RangeError {
      throw const TavernImportError('角色卡文件不完整。');
    }
  }

  /// Exports a fresh modification timestamp without mutating the stored card.
  /// PNG and JSON inline referenced embedded assets as standard data URIs.
  /// CHARX preserves all archive files, including unknown application files.
  Uint8List encode(TavernCard card, {TavernCardFormat format = TavernCardFormat.png, DateTime? modifiedAt}) {
    final json = _cloneMap(card.json);
    final data = json['data'] as Map<String, Object?>;
    data['modification_date'] = (modifiedAt ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    final avatar = card.avatar;
    if (avatar != null) {
      _projectAvatar(data, avatar);
    }
    if (format == TavernCardFormat.charx) return _encodeCharx(card, json);
    _inlineAssets(card, data, inlinePortrait: format == TavernCardFormat.json || avatar != null);
    if (format == TavernCardFormat.json) return Uint8List.fromList(utf8.encode(jsonEncode(json)));

    final cover = avatar ?? card.png ?? portraitPng(card) ?? _blankPng();
    final chunks = _pngChunks(cover);
    final output = BytesBuilder(copy: false)..add(_pngSignature);
    for (final chunk in chunks) {
      final keyword = chunk.keyword?.toLowerCase();
      if (keyword == 'chara' || keyword == 'ccv3' || (keyword?.startsWith('chara-ext-asset_:') ?? false)) {
        continue;
      }
      if (chunk.type == 'IEND') {
        output.add(_textChunk('chara', base64Encode(utf8.encode(jsonEncode(_toV2(json))))));
        output.add(_textChunk('ccv3', base64Encode(utf8.encode(jsonEncode(json)))));
      }
      output.add(chunk.bytes);
    }
    return output.takeBytes();
  }

  /// Project only the export copy. Every declared main icon points at the
  /// same new image, so decoding cannot select an older embedded main instead
  /// of the new PNG cover. Existing resource bytes and unknown fields remain.
  void _projectAvatar(Map<String, Object?> data, Uint8List avatar) {
    final original = data['assets'];
    if (original != null && original is! List<Object?>) {
      throw const FormatException('The character assets cannot hold an avatar icon.');
    }
    final assets = original is List<Object?> ? original : <Object?>[];
    final uri = Uri.dataFromBytes(avatar, mimeType: 'image/png').toString();
    var replaced = false;
    for (final value in assets) {
      if (value is Map<String, Object?> && value['type'] == 'icon' && value['name'] == 'main') {
        value['uri'] = uri;
        value['ext'] = 'png';
        replaced = true;
      }
    }
    if (!replaced) {
      assets.add({'type': 'icon', 'name': 'main', 'uri': uri, 'ext': 'png'});
    }
    data['assets'] = assets;
  }

  /// A PNG thumbnail without changing or discarding the source asset.
  /// Unsupported or damaged optional image assets have no thumbnail.
  Uint8List? portraitPng(TavernCard card) {
    final bytes = card.iconBytes;
    if (bytes == null) return null;
    try {
      final decoded = image.decodeImage(bytes);
      if (decoded == null) return null;
      if (_startsWith(bytes, _pngSignature)) {
        _pngChunks(bytes);
        return bytes;
      }
      return Uint8List.fromList(image.encodePng(decoded));
    } on Exception {
      return null;
    }
  }

  TavernCard _decodePng(Uint8List bytes) => _projectSeed(_readPngSeed(bytes));

  DecodedCardSeed _readPngSeed(Uint8List bytes) {
    final chunks = _pngChunks(bytes);
    _PngChunk? v3;
    _PngChunk? v2;
    final assets = <String, Uint8List>{};
    for (final chunk in chunks) {
      final keyword = chunk.keyword;
      if (keyword == null) continue;
      switch (keyword.toLowerCase()) {
        case 'ccv3':
          v3 ??= chunk;
        case 'chara':
          v2 ??= chunk;
        default:
          if (keyword.startsWith('chara-ext-asset_:')) {
            final path = keyword.substring('chara-ext-asset_:'.length);
            _requireAssetPath(path);
            if (assets.containsKey(path)) throw const FormatException('PNG 资源路径重复。');
            assets[path] = base64Decode(chunk.text!);
          }
      }
    }
    final selected = v3 ?? v2;
    if (selected == null) throw const TavernImportError('PNG 中没有 ccv3 或 chara 角色卡。');
    // A present but corrupt ccv3 must not silently downgrade to the stale chara.
    final source = _decodeJsonSource(base64Decode(selected.text!));
    return DecodedCardSeed(
      json: source.json,
      rawText: source.rawText,
      assets: assets,
      png: bytes,
      originalBytes: bytes,
      sourceFormat: TavernCardFormat.png,
    );
  }

  TavernCard _decodeCharx(Uint8List bytes) => _projectSeed(_readCharxSeed(bytes));

  DecodedCardSeed _readCharxSeed(Uint8List bytes) {
    final seen = <String>{};
    final archive = ZipDecoder().decodeBytes(
      bytes,
      verify: true,
      callback: (file) {
        final path = file.isDirectory && file.name.endsWith('/')
            ? file.name.substring(0, file.name.length - 1)
            : file.name;
        _requireAssetPath(path);
        if (file.isSymbolicLink || file.mode & 0xf000 == 0xa000) {
          throw const FormatException('CHARX 不支持符号链接。');
        }
        if (!seen.add(file.name)) throw const FormatException('CHARX 文件名重复。');
      },
    );
    final assets = <String, Uint8List>{};
    ({Map<String, Object?> json, String rawText})? source;
    for (final file in archive) {
      if (!file.isFile) continue;
      final content = file.readBytes();
      if (content == null || content.length != file.size) throw const FormatException('CHARX 文件不完整。');
      if (file.name == 'card.json') {
        source = _decodeJsonSource(content);
      } else {
        assets[file.name] = Uint8List.fromList(content);
      }
    }
    if (source == null) {
      throw const TavernImportError('CHARX 根目录缺少 card.json。');
    }
    return DecodedCardSeed(
      json: source.json,
      rawText: source.rawText,
      assets: assets,
      originalBytes: bytes,
      sourceFormat: TavernCardFormat.charx,
    );
  }

  TavernCard _projectSeed(DecodedCardSeed seed) => TavernCard(
    json: _upgrade(seed.json),
    assets: seed.assets,
    png: seed.png,
    originalBytes: seed.originalBytes,
    sourceFormat: seed.sourceFormat,
  );

  Uint8List _encodeCharx(TavernCard card, Map<String, Object?> json) {
    final assets = {...card.assets};
    final data = json['data'] as Map<String, Object?>;
    // A PNG's implicit portrait needs an explicit file when it leaves the PNG.
    if (card.png != null) {
      var portraitPath = 'assets/icon/images/main.png';
      var suffix = 1;
      while (assets.containsKey(portraitPath)) {
        portraitPath = 'assets/icon/images/main-${suffix++}.png';
      }
      final declared = data['assets'];
      final assetList = declared is List<Object?> ? declared : <Object?>[];
      if (declared == null) {
        assetList.add({'type': 'icon', 'name': 'main', 'ext': 'png', 'uri': 'ccdefault:'});
        data['assets'] = assetList;
      }
      var needsPortrait = false;
      for (final asset in assetList.whereType<Map<String, Object?>>()) {
        if (asset['type'] == 'icon' && asset['uri'] == 'ccdefault:') {
          asset['uri'] = 'embeded://$portraitPath';
          needsPortrait = true;
        }
      }
      if (needsPortrait) assets[portraitPath] = card.png!;
    }
    final archive = Archive()..addFile(ArchiveFile.string('card.json', jsonEncode(json)));
    for (final entry in assets.entries) {
      _requireAssetPath(entry.key);
      if (entry.key == 'card.json') throw const TavernImportError('资源名 card.json 与角色卡冲突。');
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  void _inlineAssets(TavernCard card, Map<String, Object?> data, {required bool inlinePortrait}) {
    if (inlinePortrait && data['assets'] == null && card.png != null) {
      data['assets'] = [
        {'type': 'icon', 'name': 'main', 'ext': 'png', 'uri': 'ccdefault:'},
      ];
    }
    final assets = data['assets'];
    if (assets is! List<Object?>) return;
    for (final asset in assets.whereType<Map<String, Object?>>()) {
      final uri = asset['uri'];
      if (uri is! String) continue;
      if (embeddedCardAssetPath(uri) == null && !(inlinePortrait && uri == 'ccdefault:' && asset['type'] == 'icon')) {
        continue;
      }
      final bytes = card.assetBytes(uri);
      if (bytes != null) asset['uri'] = Uri.dataFromBytes(bytes, mimeType: _assetMime(_text(asset['ext']))).toString();
    }
  }
}

/// URI paths are case-sensitive. The correctly spelled alias is also accepted
/// because ST/Risu CHARX files in the wild use it.
String? embeddedCardAssetPath(String uri) {
  for (final prefix in const ['embeded://', 'embedded://', '__asset:']) {
    if (uri.startsWith(prefix)) {
      final path = uri.substring(prefix.length);
      return isSafeCardAssetPath(path) ? path : null;
    }
  }
  return null;
}

/// The companion pack's relative-path rule, with Windows drive/ADS paths also
/// excluded so a card exported on one platform remains safe on another.
bool isSafeCardAssetPath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains('\\') || path.contains('\u0000')) return false;
  return path.split('/').every((part) => part.isNotEmpty && part != '.' && part != '..' && !part.contains(':'));
}

void _requireAssetPath(String path) {
  if (!isSafeCardAssetPath(path)) throw const FormatException('角色卡资源必须使用目录内的相对路径。');
}

Map<String, Object?> _decodeJson(List<int> bytes) => _decodeJsonSource(bytes).json;

({Map<String, Object?> json, String rawText}) _decodeJsonSource(List<int> bytes) {
  final source = decodeAuthoringText(bytes);
  var text = source.text;
  if (text.startsWith('\ufeff')) text = text.substring(1);
  final value = jsonDecode(text);
  if (value is! Map<String, Object?>) throw const FormatException('角色卡 JSON 必须是对象。');
  return (json: value, rawText: source.rawText);
}

Map<String, Object?> _upgrade(Map<String, Object?> source) {
  final spec = source['spec'];
  if (spec == 'lorebook_v3' ||
      (spec == null &&
          !source.containsKey('first_mes') &&
          !source.containsKey('personality') &&
          !source.containsKey('mes_example') &&
          (source['entries'] is Map<String, Object?> || source['entries'] is List<Object?>))) {
    throw const TavernImportError('这是世界书，请从世界书入口导入。', isLorebook: true);
  }
  if (spec != null && spec != 'chara_card_v2' && spec != 'chara_card_v3') {
    throw TavernImportError('不支持的角色卡规范：$spec');
  }
  final json = _cloneMap(source);
  final Map<String, Object?> data;
  if (spec == null) {
    data = _cloneMap(source);
    data.putIfAbsent('creator_notes', () => source['creatorcomment'] ?? '');
    final extensions = _map(data['extensions']);
    for (final key in const ['talkativeness', 'fav', 'world']) {
      if (source.containsKey(key)) extensions.putIfAbsent(key, () => source[key]);
    }
    if (source.containsKey('depth_prompt_prompt')) {
      extensions.putIfAbsent(
        'depth_prompt',
        () => {
          'prompt': source['depth_prompt_prompt'],
          'depth': source['depth_prompt_depth'] ?? 4,
          'role': source['depth_prompt_role'] ?? 'system',
        },
      );
    }
    data['extensions'] = extensions;
  } else {
    final value = json['data'];
    if (value is! Map<String, Object?>) throw const FormatException('角色卡缺少 data 对象。');
    data = value;
  }
  if (data['name'] is! String) throw const FormatException('角色卡缺少 name 字符串。');
  for (final key in const [
    'description',
    'personality',
    'scenario',
    'first_mes',
    'mes_example',
    'system_prompt',
    'post_history_instructions',
    'creator_notes',
    'creator',
    'character_version',
  ]) {
    data.putIfAbsent(key, () => '');
  }
  for (final key in const ['tags', 'alternate_greetings', 'group_only_greetings']) {
    data.putIfAbsent(key, () => <Object?>[]);
  }
  data.putIfAbsent('extensions', () => <String, Object?>{});
  data.putIfAbsent('creation_date', () => 0);
  data.putIfAbsent('modification_date', () => 0);
  final book = data['character_book'];
  if (book is Map<String, Object?>) {
    final entries = book['entries'];
    if (entries is List<Object?>) {
      for (final entry in entries.whereType<Map<String, Object?>>()) {
        entry.putIfAbsent('use_regex', () => false);
      }
    }
  }
  json['spec'] = 'chara_card_v3';
  if (spec != 'chara_card_v3') json['spec_version'] = '3.0';
  json.putIfAbsent('spec_version', () => '3.0');
  json['data'] = data;
  return json;
}

Map<String, Object?> _toV2(Map<String, Object?> v3) {
  final json = _cloneMap(v3);
  json['spec'] = 'chara_card_v2';
  json['spec_version'] = '2.0';
  final data = json['data'] as Map<String, Object?>;
  for (final field in const [
    'nickname',
    'creator_notes_multilingual',
    'source',
    'group_only_greetings',
    'creation_date',
    'modification_date',
    'assets',
  ]) {
    data.remove(field);
  }
  final book = data['character_book'];
  if (book is Map<String, Object?>) {
    final entries = book['entries'];
    if (entries is List<Object?>) {
      for (final entry in entries.whereType<Map<String, Object?>>()) {
        entry.remove('use_regex');
        if (entry['content'] case final String content) {
          entry['content'] = content.replaceAll(RegExp(r'^@@[^\r\n]*(?:\r?\n|$)', multiLine: true), '');
        }
      }
    }
  }
  return json;
}

Map<String, Object?> _cloneMap(Map<String, Object?> value) => jsonDecode(jsonEncode(value)) as Map<String, Object?>;
Map<String, Object?> _map(Object? value) => value is Map<String, Object?> ? value : <String, Object?>{};
String _text(Object? value) => value is String ? value : '';
String? _nullableText(Object? value) => value is String ? value : null;
List<String> _strings(Object? value) => value is List<Object?> ? value.whereType<String>().toList() : const [];

int _scriptCount(Object? scripts) {
  if (scripts is! List<Object?>) return 0;
  var count = 0;
  for (final script in scripts.whereType<Map<String, Object?>>()) {
    if (script['type'] == 'folder' || script['scripts'] is List<Object?> || script['children'] is List<Object?>) {
      count += _scriptCount(script['scripts'] ?? script['children']);
    } else {
      count++;
    }
  }
  return count;
}

/// Internal export helper sharing the codec's existing MIME projection.
String cardAssetDataUri(String path, List<int> bytes) =>
    Uri.dataFromBytes(bytes, mimeType: _assetMime(path.split('.').last)).toString();

String _assetMime(String ext) => switch (ext.toLowerCase()) {
  'png' || 'apng' => 'image/png',
  'jpg' || 'jpeg' => 'image/jpeg',
  'webp' => 'image/webp',
  'gif' => 'image/gif',
  'svg' => 'image/svg+xml',
  'avif' => 'image/avif',
  'mp3' => 'audio/mpeg',
  'wav' => 'audio/wav',
  'ogg' => 'audio/ogg',
  'mp4' => 'video/mp4',
  'webm' => 'video/webm',
  'json' => 'application/json',
  'ttf' => 'font/ttf',
  'otf' => 'font/otf',
  _ => 'application/octet-stream',
};

const _pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
bool _startsWith(List<int> value, List<int> prefix) {
  if (value.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (value[i] != prefix[i]) return false;
  }
  return true;
}

class _PngChunk {
  const _PngChunk(this.type, this.data, this.bytes);
  final String type;
  final Uint8List data;
  final Uint8List bytes;

  String? get keyword {
    if (type != 'tEXt') return null;
    final end = data.indexOf(0);
    return end > 0 ? latin1.decode(data.sublist(0, end)) : null;
  }

  String? get text {
    if (keyword == null) return null;
    return latin1.decode(data.sublist(data.indexOf(0) + 1));
  }
}

List<_PngChunk> _pngChunks(Uint8List bytes) {
  if (!_startsWith(bytes, _pngSignature)) throw const FormatException('卡面不是 PNG。');
  final result = <_PngChunk>[];
  final data = ByteData.sublistView(bytes);
  var offset = _pngSignature.length;
  var ended = false;
  while (offset + 12 <= bytes.length) {
    final size = data.getUint32(offset);
    final end = offset + size + 12;
    if (end > bytes.length) throw const FormatException('PNG 数据块不完整。');
    final type = ascii.decode(bytes.sublist(offset + 4, offset + 8));
    final storedCrc = data.getUint32(end - 4);
    if (_crc32(bytes, offset + 4, end - 4) != storedCrc) throw const FormatException('PNG CRC 校验失败。');
    if (result.isEmpty && (type != 'IHDR' || size != 13)) throw const FormatException('PNG 缺少 IHDR。');
    result.add(
      _PngChunk(type, Uint8List.sublistView(bytes, offset + 8, end - 4), Uint8List.sublistView(bytes, offset, end)),
    );
    offset = end;
    if (type == 'IEND') {
      if (size != 0) throw const FormatException('PNG IEND 长度错误。');
      ended = true;
      break;
    }
  }
  if (!ended || offset != bytes.length || !result.any((chunk) => chunk.type == 'IDAT')) {
    throw const FormatException('PNG 不完整或含尾随数据。');
  }
  return result;
}

Uint8List _textChunk(String keyword, String text) {
  final content = [...latin1.encode(keyword), 0, ...latin1.encode(text)];
  final bytes = Uint8List(content.length + 12);
  final data = ByteData.sublistView(bytes)..setUint32(0, content.length);
  bytes.setRange(4, 8, ascii.encode('tEXt'));
  bytes.setRange(8, 8 + content.length, content);
  data.setUint32(bytes.length - 4, _crc32(bytes, 4, bytes.length - 4));
  return bytes;
}

int _crc32(List<int> bytes, int start, int end) {
  var crc = 0xffffffff;
  for (var i = start; i < end; i++) {
    crc ^= bytes[i];
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

Uint8List _blankPng() => Uint8List.fromList(image.encodePng(image.Image(width: 1, height: 1, numChannels: 4)));
