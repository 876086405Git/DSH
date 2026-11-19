// Uses the staging/rename and serialized-operation approach of
// app/lib/pets/pet_library.dart at dsh-Go 1c5b220093295f8d069f6bfb06d8b4fc97b9e9c2.
// Pure Dart: the Flutter provider and image work stay outside the UI isolate.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../api.dart';
import '../authoring.dart';
import '../authoring_authority.dart';
import '../authoring_seed.dart';
import '../import_report.dart';
import '../io/authoring_text.dart';
import '../io/card_codec.dart';
import '../regex_library.dart';
import '../worldinfo/world_info.dart';

/// Detached media supplied by a seed or read under the current source queue.
final class AuthoringCardMedia {
  const AuthoringCardMedia({
    required this.sourceFormat,
    required this.originalBytes,
    this.assets = const {},
    this.png,
    this.avatar,
    this.fileName,
  });
  final TavernCardFormat sourceFormat;
  final Uint8List originalBytes;
  final Map<String, Uint8List> assets;
  final Uint8List? png;
  final Uint8List? avatar;
  final String? fileName;
}

/// The selected avatar declaration without reading image bytes or observing
/// an authority revision. A missing character remains distinct from no avatar.
final class CharacterAvatarMetadata {
  const CharacterAvatarMetadata({required this.snapshot, this.file, this.sha256});
  final AuthoringResourceSnapshot snapshot;
  final String? file;
  final String? sha256;
  bool get hasAvatar => file != null;
}

/// Owned bytes of the image selected by [metadata], or explicit absence.
final class CharacterAvatarCapture {
  const CharacterAvatarCapture({required this.metadata, this.bytes});
  final CharacterAvatarMetadata metadata;
  final Uint8List? bytes;
}

/// A queued, read-only preview dependency. [snapshot] is what the files said;
/// [ledger] is the separately recorded authority evidence, if an owner exists.
final class AuthoringCharacterCapture {
  const AuthoringCharacterCapture({
    required this.snapshot,
    this.document,
    this.character,
    this.mediaRefs = const [],
    this.media = const {},
    this.ledger,
  });

  final AuthoringResourceSnapshot snapshot;
  final Map<String, Object?>? document;
  final StoredCharacter? character;
  final List<String> mediaRefs;
  final Map<String, Uint8List> media;
  final AuthoringResourceVersion? ledger;
}

class StoredCharacter {
  const StoredCharacter({
    required this.id,
    required this.card,
    required this.importedAt,
    this.avatarPath,
    this.directoryPath,
  });

  final String id;
  final TavernCard card;
  final DateTime importedAt;
  final String? avatarPath;

  /// The published character directory, used only for runtime asset paths.
  /// It is never written into the card, library metadata or summary index.
  final String? directoryPath;

  TavernCharacter toCharacter({
    int chatCount = 0,
    DateTime? lastChatAt,
    String? language,
    List<TavernRegexDiagnostic> regexDiagnostics = const [],
  }) => card.toCharacter(
    id,
    importedAt: importedAt,
    avatarPath: avatarPath,
    resolveAssetPath: _resolveAssetPath,
    chatCount: chatCount,
    lastChatAt: lastChatAt,
    language: language,
    regexDiagnostics: regexDiagnostics,
  );

  String? _resolveAssetPath(String uri) {
    final directory = directoryPath;
    if (directory == null) {
      return null;
    }
    if (uri == 'ccdefault:') {
      return card.png == null ? null : '$directory/source.png';
    }
    final path = embeddedCardAssetPath(uri) ?? (isSafeCardAssetPath(uri) ? uri : null);
    if (path == null || !card.assets.containsKey(path)) {
      return null;
    }
    return '$directory/resources/$path';
  }
}

/// The small, immutable projection used by character lists. Full card text,
/// original bytes, resource bytes and compatibility reports are read on demand.
class StoredCharacterSummary {
  StoredCharacterSummary({
    required this.id,
    required this.name,
    required List<String> tags,
    required this.importedAt,
    required this.regexCount,
    required this.scriptCount,
    required this.hasLorebook,
    this.nickname,
    this.creator,
    this.avatarPath,
  }) : tags = List.unmodifiable(tags);

  final String id;
  final String name;
  final String? nickname;
  final String? creator;
  final List<String> tags;
  final String? avatarPath;
  final DateTime importedAt;
  final int regexCount;
  final int scriptCount;
  final bool hasLorebook;

  /// Detail-only fields keep their empty defaults; use [CharacterLibrary.read]
  /// for description, greetings, creator notes, theme or declared assets.
  TavernCharacter toCharacter({int chatCount = 0, DateTime? lastChatAt}) => TavernCharacter(
    id: id,
    name: name,
    nickname: nickname,
    creator: creator,
    tags: tags,
    avatarPath: avatarPath,
    importedAt: importedAt,
    regexCount: regexCount,
    scriptCount: scriptCount,
    hasLorebook: hasLorebook,
    chatCount: chatCount,
    lastChatAt: lastChatAt,
  );
}

/// File-backed character library. [root] is `<app support>/tavern`.
///
/// Each import creates a new id. A complete directory is published by rename,
/// so interrupted writes never become visible as a half-imported character.
/// Only one instance should own a root, just as one Tavern owns the app store.
class CharacterLibrary {
  CharacterLibrary(this.root, {DateTime Function()? now, this.authority}) : _now = now ?? DateTime.now {
    if (authority != null && !authority!.ownsRoot(root)) {
      throw ArgumentError('The character library must use its root authority.');
    }
  }

  /// Allows nullable facade lookups to reject unknown identifiers without
  /// opening paths. Strict file operations still call [_requireId].
  static bool isValidId(String id) => _idPattern.hasMatch(id);

  final Directory root;
  final AuthoringAuthority? authority;
  final DateTime Function() _now;
  static const _runtimeCacheCapacity = 8;
  Future<void> _queue = Future.value();
  final _runtimeAuthority = <String, ({_CharacterFileVersion version, Map<String, Object?> data})>{};
  final _runtimeAvatars =
      <String, ({_CharacterFileVersion card, _CharacterFileVersion identity, CharacterAvatarMetadata metadata})>{};

  /// Internal synchronous notification of the authoritative card-file commit.
  /// The observer must not throw, write, await, or depend on the derived index.
  void Function(String id, Map<String, Object?> data)? cardCommitted;
  void Function(String id)? cardRemoved;

  Directory get _characters => Directory('${root.path}/characters');
  Directory get _indexes => Directory('${root.path}/character-index');
  File _indexFile(String id) => File('${_indexes.path}/$id.json');

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final run = _queue.then((_) => action());
    _queue = run.then((_) {}, onError: (Object _, StackTrace _) {});
    return run;
  }

  void _checkManagedWriter([String? id]) {
    if (authority == null && AuthoringAuthority.inspectRootReadOnly(root).domainId != null) {
      throw TavernAuthoringException(
        'managed_writer_required',
        'This character library must be written through its TavernEngine.',
        physicalResourceId: id == null ? null : 'character:$id',
      );
    }
    if (id != null) authority?.checkWritable('character:$id');
  }

  Set<String>? _protectedArtifacts() {
    try {
      return (authority?.pendingState() ?? AuthoringAuthority.inspectRootReadOnly(root)).protectedArtifacts;
    } catch (_) {
      // A failed ledger probe cannot authorize removal of recovery evidence.
      return null;
    }
  }

  Future<AuthoringResourceSnapshot> _readAuthoringResource(String id) async {
    final directory = Directory('${_characters.path}/$id');
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      try {
        await FileSystemEntity.identical(directory.path, directory.path);
      } on PathNotFoundException catch (error) {
        final code = error.osError?.errorCode;
        if ((code == 2 || (Platform.isWindows && code == 3)) &&
            await FileSystemEntity.type(directory.path, followLinks: false) == FileSystemEntityType.notFound) {
          return const AuthoringResourceSnapshot(present: false);
        }
        rethrow;
      }
      throw FileSystemException('The character folder could not be identified as absent.', directory.path);
    }
    if (type != FileSystemEntityType.directory) throw const FileSystemException('Character folder is not a directory');
    final raw = await readAuthoringText(File('${directory.path}/card.json'));
    final identity = await readAuthoringText(File('${directory.path}/library.json'));
    return AuthoringResourceSnapshot(present: true, rawText: raw.rawText, identityText: identity.rawText);
  }

  /// Reads only raw card/identity text and the selected image declaration.
  /// It neither tidies files nor creates an authoring observation.
  Future<CharacterAvatarMetadata> readAvatarMetadata(String id) => _exclusive(() async {
    _requireId(id);
    return _avatarMetadata(await _readAuthoringResource(id));
  });

  /// Runtime-only projection. Authoring and avatar CAS continue using fresh
  /// reads; unchanged runtime callers can reuse the same metadata object.
  Future<CharacterAvatarMetadata> readRuntimeAvatarMetadata(String id) => _exclusive(() async {
    _requireId(id);
    final path = '${_characters.path}/$id';
    if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.directory) {
      _runtimeAvatars.remove(id);
      return _avatarMetadata(await _readAuthoringResource(id));
    }
    final cardVersion = _characterFileVersion(await File('$path/card.json').stat());
    final identityVersion = _characterFileVersion(await File('$path/library.json').stat());
    final cached = _runtimeAvatars.remove(id);
    if (cached != null && cached.card == cardVersion && cached.identity == identityVersion) {
      _runtimeAvatars[id] = cached;
      return cached.metadata;
    }
    final metadata = _avatarMetadata(await _readAuthoringResource(id));
    _runtimeAvatars[id] = (card: cardVersion, identity: identityVersion, metadata: metadata);
    if (_runtimeAvatars.length > _runtimeCacheCapacity) _runtimeAvatars.remove(_runtimeAvatars.keys.first);
    return metadata;
  });

  void _invalidateRuntimeCharacter(String id) {
    _runtimeAuthority.remove(id);
    _runtimeAvatars.remove(id);
  }

  /// Reads only the actual selected avatar, without loading original imports
  /// or walking the resource manifest. The returned bytes belong to this read.
  Future<CharacterAvatarCapture> readAvatar(String id) => _exclusive(() async {
    _requireId(id);
    return _readAvatar(id);
  });

  Future<CharacterAvatarCapture> _readAvatar(String id) async {
    final metadata = _avatarMetadata(await _readAuthoringResource(id));
    final file = metadata.file;
    return CharacterAvatarCapture(
      metadata: metadata,
      bytes: file == null ? null : await _readAvatarFile('${_characters.path}/$id', file, metadata.sha256),
    );
  }

  Future<bool> _avatarStillCurrent(String id, CharacterAvatarCapture before) async {
    try {
      if (!(await _readAuthoringResource(id)).sameAs(before.metadata.snapshot)) {
        return false;
      }
      final file = before.metadata.file;
      if (file == null) {
        return true;
      }
      final actual = await File('${_characters.path}/$id/$file').readAsBytes();
      return _sameAuthoringCaptureBytes(before.bytes!, actual);
    } on PathNotFoundException catch (error) {
      final code = error.osError?.errorCode;
      if (code == 2 || (Platform.isWindows && code == 3)) {
        return false;
      }
      rethrow;
    }
  }

  /// [png] is the caller's detached, validated PNG. [prepare] checks its
  /// expected token once against the fresh physical capture in this queue.
  /// Notifications are synchronous; callers wait for host/cache work outside.
  Future<CharacterAvatarCapture> replaceAvatar(
    String id,
    Uint8List png, {
    required void Function(CharacterAvatarCapture current) prepare,
    void Function()? check,
    void Function(CharacterAvatarCapture adopted)? onCommitted,
  }) => _exclusive(() async {
    _requireId(id);
    _checkManagedWriter(id);
    final before = await _readAvatar(id);
    check?.call();
    prepare(before);
    if (!before.metadata.snapshot.present) {
      throw const TavernImportError('角色不存在。');
    }
    final digest = crypto.sha256.convert(png).toString();
    final avatarFile = 'avatar-$digest.png';
    if (before.metadata.file == avatarFile &&
        before.metadata.sha256 == digest &&
        _sameAuthoringCaptureBytes(before.bytes!, png)) {
      return before;
    }
    final original = before.metadata.snapshot;
    final metadata = jsonDecode(decodeAuthoringText(utf8.encode(original.identityText!)).text) as Map<String, Object?>;
    metadata['avatar'] = {'file': avatarFile, 'sha256': digest};
    final after = AuthoringResourceSnapshot(
      present: true,
      rawText: original.rawText,
      identityText: jsonEncode(metadata),
    );
    final adopted = CharacterAvatarCapture(
      metadata: CharacterAvatarMetadata(snapshot: after, file: avatarFile, sha256: digest),
      bytes: png,
    );
    final document = const CardCodec().decodeAuthority(Uint8List.fromList(utf8.encode(original.rawText!)));
    final importedAtValue = metadata['importedAt'];
    final importedAt = importedAtValue is String ? DateTime.tryParse(importedAtValue) : null;
    if (importedAt == null) {
      throw const TavernImportError('资料库导入时间无效。');
    }
    final directory = '${_characters.path}/$id';
    final pending = File('$directory/library.json.writing');
    final summary = _summarize(
      StoredCharacter(
        id: id,
        importedAt: importedAt,
        avatarPath: '$directory/$avatarFile',
        card: TavernCard(json: document, avatar: png),
      ),
    );
    final owner = authority;
    final ticket = owner == null
        ? null
        : AuthoringWriteTicket(
            request: owner.newRequest('character:$id', {'method': 'replaceCharacterAvatar', 'after': after.toJson()}),
            before: original,
            after: after,
            artifacts: ['characters/$id/$avatarFile', 'characters/$id/library.json.writing'],
          );
    try {
      await _writeImmutableAvatar(File('$directory/$avatarFile'), png);
      if (!await _avatarStillCurrent(id, before)) {
        throw TavernAuthoringException(
          'authority_conflict',
          'The captured character avatar changed.',
          physicalResourceId: 'character:$id',
        );
      }
      check?.call();
      if (ticket != null) {
        owner!.prepare(ticket, check: check);
      }
      // A readable summary must not describe the old avatar after adoption.
      await _invalidateSummary(id);
      await pending.writeAsString(after.identityText!, flush: true);
      if (!await _avatarStillCurrent(id, before)) {
        throw TavernAuthoringException(
          'authority_conflict',
          'The captured character avatar changed.',
          physicalResourceId: 'character:$id',
        );
      }
      check?.call();
      ticket?.enteredEffect = true;
      await pending.rename('$directory/library.json');
      ticket?.knownAdopted = true;
      try {
        _invalidateRuntimeCharacter(id);
        cardCommitted?.call(id, document['data']! as Map<String, Object?>);
      } finally {
        onCommitted?.call(adopted);
      }
      if (ticket != null) {
        owner!.adopted(ticket);
      }
      await _writeSummary(summary);
      if (ticket != null) {
        owner!.publish(ticket);
      }
      return adopted;
    } catch (error, stack) {
      if (ticket != null) {
        owner!.fail(ticket, error, stack);
      }
      rethrow;
    }
    // Keep immutable bytes and any pending metadata as real recovery evidence.
    // Neither a failed notification nor an unconfirmed rename restores a pointer.
  });

  Future<void> _observeCharacter(String id) async {
    final owner = authority;
    if (owner != null) owner.observe('character:$id', await _readAuthoringResource(id));
  }

  Future<StoredCharacter> importCard(
    Uint8List bytes, {
    String? fileName,
    Future<void> Function(TavernCard card)? beforeSave,
    Future<TavernImportReport> Function(TavernCard card)? inspect,
  }) => _exclusive(() async {
    _checkManagedWriter();
    await _tidy();
    // Decode/ZIP inflate/portrait conversion cannot stall Flutter's isolate.
    final decoded = await _decodeImport(bytes);
    final (card, portrait) = decoded;
    await beforeSave?.call(card);
    final report = await inspect?.call(card);
    final importedAt = _now().toUtc();
    final id = _newId();
    final saved = await _importPrepared(id, card, portrait, importedAt, fileName: fileName, report: report);
    return saved.record;
  });

  /// Creates a new card in this same physical queue. Current-source media is
  /// read only after its saved authority and raw identity still match.
  Future<TavernAuthoringSaveAsReceipt> importAuthoringEnvelope(
    String rawText, {
    required String domainId,
    required String operationId,
    required Map<String, Object?> parameters,
    required TavernAuthoringMediaSelection media,
    required List<String> mediaRefs,
    required String sourceFormat,
    AuthoringCardMedia? seedMedia,
    ({String id, AuthoringExpectation expected})? currentSource,
    ({String id, AuthoringExpectation expected})? requiredSource,
    void Function()? check,
    Future<TavernImportReport> Function(TavernCard card)? inspect,
  }) => _exclusive(() async {
    _checkManagedWriter();
    final owner = authority;
    if (owner == null) {
      throw StateError('Authoring requires the managed character authority.');
    }
    final replayed = replayAuthoringSaveAs(owner, domainId, operationId, parameters);
    if (replayed != null) {
      return replayed;
    }
    if (domainId != owner.domainId) {
      throw const TavernAuthoringException('authority_conflict', 'The operation domain changed.');
    }
    await _tidy();
    final bytes = Uint8List.fromList(utf8.encode(rawText));
    final (document, projection) = await _decodeAuthoringImport(bytes);
    final AuthoringCardMedia selected;
    switch (media) {
      case TavernAuthoringMediaSelection.none:
        selected = AuthoringCardMedia(sourceFormat: TavernCardFormat.json, originalBytes: bytes);
      case TavernAuthoringMediaSelection.seedCaptured:
        selected = seedMedia!;
      case TavernAuthoringMediaSelection.currentSource:
        final source = currentSource!;
        _checkManagedWriter(source.id);
        final fresh = await _readAuthoringResource(source.id);
        final revision = owner.observe('character:${source.id}', fresh);
        if (revision != source.expected.revision || !fresh.sameAs(source.expected.before)) {
          throw TavernAuthoringException(
            'authority_conflict',
            'The current media source changed.',
            physicalResourceId: 'character:${source.id}',
          );
        }
        final metadata = jsonDecode(decodeAuthoringText(utf8.encode(fresh.identityText!)).text) as Map<String, Object?>;
        final format = TavernCardFormat.values.byName(metadata['sourceFormat']! as String);
        final sourceDirectory = '${_characters.path}/${source.id}';
        final assets = <String, Uint8List>{};
        for (final path in mediaRefs) {
          if (!isSafeCardAssetPath(path)) {
            throw const TavernImportError('资料库资源路径无效。');
          }
          assets[path] = await File('$sourceDirectory/resources/$path').readAsBytes();
        }
        selected = AuthoringCardMedia(
          sourceFormat: format,
          assets: assets,
          originalBytes: await File('$sourceDirectory/original.${format.name}').readAsBytes(),
          png: metadata['hasPng'] == true ? await File('$sourceDirectory/source.png').readAsBytes() : null,
          avatar: await _readAvatarOverride(sourceDirectory, metadata),
          fileName: metadata['sourceFileName'] is String ? metadata['sourceFileName']! as String : null,
        );
    }
    final card = TavernCard(
      json: projection,
      assets: selected.assets,
      png: selected.png,
      avatar: selected.avatar,
      originalBytes: selected.originalBytes,
      sourceFormat: selected.sourceFormat,
    );
    final portrait = await _authoringPortrait(card);
    final report = await inspect?.call(
      TavernCard(
        json: document,
        assets: selected.assets,
        png: selected.png,
        avatar: selected.avatar,
        originalBytes: selected.originalBytes,
        sourceFormat: selected.sourceFormat,
      ),
    );
    final copied = media == TavernAuthoringMediaSelection.none
        ? <String>[]
        : [
            'original.${selected.sourceFormat.name}',
            if (selected.png != null) 'source.png',
            if (selected.avatar != null) _avatarFileName(selected.avatar!),
            for (final path in selected.assets.keys) 'resources/$path',
          ];
    final missing = <String>{...mediaRefs, if (sourceFormat == 'png') 'ccdefault:'};
    final data = document['data']! as Map<String, Object?>;
    final declared = data['assets'];
    if (declared is List<Object?>) {
      for (final asset in declared.whereType<Map<String, Object?>>()) {
        final uri = asset['uri'];
        if (uri is String && !uri.startsWith('data:')) {
          missing.add(uri);
        }
      }
    }
    missing.removeWhere(
      (reference) => reference == 'ccdefault:'
          ? selected.png != null
          : selected.assets.containsKey(embeddedCardAssetPath(reference) ?? reference),
    );
    final result = <String, Object?>{
      'copiedMedia': copied,
      'issues': [
        for (final reference in missing) {'type': 'media_not_copied', 'message': reference},
      ],
    };
    String id;
    do {
      id = _newId();
    } while (await FileSystemEntity.type('${_characters.path}/$id', followLinks: false) !=
        FileSystemEntityType.notFound);
    final request = AuthoringWriteRequest(
      domainId: domainId,
      operationId: operationId,
      physicalResourceId: 'character:$id',
      parameters: {...parameters, 'saveAsResult': result},
    );
    try {
      final saved = await _importPrepared(
        id,
        card,
        portrait,
        _now().toUtc(),
        fileName: selected.fileName,
        report: report,
        exactText: rawText,
        actualData: data,
        request: request,
        requiredSource: requiredSource,
        check: check,
      );
      return authoringSaveAsReceipt(saved.receipt!, result);
    } on TavernAuthoringException catch (error) {
      final receipt = error.receipt;
      if (error.code != 'resource_write_failed' ||
          receipt == null ||
          receipt.domainId != domainId ||
          receipt.operationId != operationId ||
          receipt.physicalResourceId != request.physicalResourceId) {
        rethrow;
      }
      return authoringSaveAsReceipt(receipt, result);
    }
  });

  Future<({StoredCharacter record, TavernAuthoringReceipt? receipt})> _importPrepared(
    String id,
    TavernCard card,
    Uint8List? portrait,
    DateTime importedAt, {
    String? fileName,
    TavernImportReport? report,
    String? exactText,
    Map<String, Object?>? actualData,
    AuthoringWriteRequest? request,
    ({String id, AuthoringExpectation expected})? requiredSource,
    void Function()? check,
  }) async {
    final rawText = exactText ?? await _encodeCardDocument(card.json);
    final avatar = card.avatar;
    final avatarDigest = avatar == null ? null : crypto.sha256.convert(avatar).toString();
    final avatarFile = avatarDigest == null ? null : 'avatar-$avatarDigest.png';
    final identityText = jsonEncode({
      'version': 1,
      'importedAt': importedAt.toIso8601String(),
      'sourceFormat': card.sourceFormat.name,
      'sourceFileName': fileName,
      'hasPng': card.png != null,
      'hasPortrait': portrait != null,
      if (avatarFile != null) 'avatar': {'file': avatarFile, 'sha256': avatarDigest},
      'resources': card.assets.keys.toList(),
    });
    final staging = await _characters.createTemp('.staging-');
    final destination = Directory('${_characters.path}/$id');
    final owner = authority;
    AuthoringWriteTicket? ticket;
    try {
      await File('${staging.path}/card.json').writeAsString(rawText, flush: true);
      if (report != null) {
        await File('${staging.path}/import-report.json').writeAsString(jsonEncode(report.toJson()), flush: true);
      }
      // Keep the source from this decode, even if the caller reuses its input
      // buffer while the completed card is being inspected or published.
      await File('${staging.path}/original.${card.sourceFormat.name}').writeAsBytes(card.originalBytes!, flush: true);
      if (card.png != null) await File('${staging.path}/source.png').writeAsBytes(card.png!, flush: true);
      if (portrait != null) await File('${staging.path}/portrait.png').writeAsBytes(portrait, flush: true);
      if (avatar != null) {
        await File('${staging.path}/$avatarFile').writeAsBytes(avatar, flush: true);
      }
      for (final entry in card.assets.entries) {
        if (!isSafeCardAssetPath(entry.key)) throw const TavernImportError('角色卡资源路径无效。');
        final file = File('${staging.path}/resources/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }
      await File('${staging.path}/library.json').writeAsString(identityText, flush: true);
      // Never overwrite an existing import, even on a random-id collision.
      if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw const FileSystemException('Character id already exists');
      }
      if (owner != null) {
        final before = await _readAuthoringResource(id);
        if (request != null && before.present) {
          throw TavernAuthoringException(
            'authority_conflict',
            'The new character target is no longer absent.',
            physicalResourceId: 'character:$id',
          );
        }
        if (requiredSource != null) {
          _checkManagedWriter(requiredSource.id);
          final fresh = await _readAuthoringResource(requiredSource.id);
          final revision = owner.observe('character:${requiredSource.id}', fresh);
          if (revision != requiredSource.expected.revision || !fresh.sameAs(requiredSource.expected.before)) {
            throw TavernAuthoringException(
              'authority_conflict',
              'The captured cast source changed.',
              physicalResourceId: 'character:${requiredSource.id}',
            );
          }
        }
        final after = AuthoringResourceSnapshot(present: true, rawText: rawText, identityText: identityText);
        ticket = AuthoringWriteTicket(
          request: request ?? owner.newRequest('character:$id', {'method': 'importCard', 'after': after.toJson()}),
          before: before,
          after: after,
          artifacts: ['characters/${_name(staging)}'],
        );
        final replayed = owner.prepare(ticket, check: check);
        if (replayed != null) {
          final existing = await _read(id);
          if (replayed.committed == true && existing != null) {
            return (record: existing, receipt: replayed);
          }
          throw TavernAuthoringException(
            'resource_write_failed',
            'The import operation is already recorded.',
            physicalResourceId: 'character:$id',
            receipt: replayed,
          );
        }
      }
      // An orphaned derived index must never describe a new import, even if a
      // random id happens to be reused. Invalidate before publishing the card.
      await _invalidateSummary(id);
      ticket?.enteredEffect = true;
      await staging.rename(destination.path);
      ticket?.knownAdopted = true;
      _invalidateRuntimeCharacter(id);
      cardCommitted?.call(id, actualData ?? card.data);
      if (ticket != null) owner!.adopted(ticket);
      final record = StoredCharacter(
        id: id,
        card: card,
        importedAt: importedAt,
        avatarPath: avatarFile != null
            ? '${destination.path}/$avatarFile'
            : portrait == null
            ? null
            : '${destination.path}/portrait.png',
        directoryPath: destination.absolute.path,
      );
      await _writeSummary(_summarize(record));
      return (record: record, receipt: ticket == null ? null : owner!.publish(ticket));
    } catch (error, stack) {
      if (ticket != null) owner!.fail(ticket, error, stack);
      rethrow;
    } finally {
      final protected = _protectedArtifacts();
      if (protected != null && !protected.contains('characters/${_name(staging)}') && await staging.exists()) {
        await _discard(staging);
      }
    }
  }

  Future<StoredCharacter?> read(String id) => _exclusive(() async {
    _requireId(id);
    await _tidy();
    return _read(id);
  });

  Future<TavernImportReport?> readImportReport(String id) => _exclusive(() async {
    _requireId(id);
    await _tidy();
    final directory = Directory('${_characters.path}/$id');
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) throw const FileSystemException('Character folder is not a directory');
    final file = File('${_characters.path}/$id/import-report.json');
    if (!await file.exists()) return null;
    final report = TavernImportReport.fromJson(jsonDecode(await file.readAsString()) as Map<String, Object?>);
    if (report.kind != TavernImportKind.character) throw const FormatException('Invalid character import report.');
    // Staleness needs JSON and the resource manifest, not original/portrait or
    // embedded file bytes. Opening the report must not load every card asset.
    final json = jsonDecode(await File('${directory.path}/card.json').readAsString()) as Map<String, Object?>;
    final metadata = jsonDecode(await File('${directory.path}/library.json').readAsString()) as Map<String, Object?>;
    if (metadata['version'] != 1 || metadata['resources'] is! List<Object?>) {
      throw const TavernImportError('资料库元数据无效。');
    }
    final resources = (metadata['resources']! as List<Object?>).cast<String>();
    return report.withStale(
      report.fingerprint != importFingerprint(TavernImportKind.character, json, embeddedAssetPaths: resources),
    );
  });

  /// The same queue protects edits/deletion and the inspected snapshot, so a
  /// slow compatibility probe cannot publish a report for a newer revision.
  Future<TavernImportReport> recheckImport(String id, Future<TavernImportReport> Function(TavernCard card) inspect) =>
      _exclusive(() async {
        _requireId(id);
        _checkManagedWriter(id);
        await _tidy();
        await _observeCharacter(id);
        final record = await _read(id);
        if (record == null) throw const TavernImportError('角色不存在。');
        final report = await inspect(record.card);
        final file = File('${_characters.path}/$id/import-report.json');
        final pending = File('${file.path}.writing');
        try {
          await pending.writeAsString(jsonEncode(report.toJson()), flush: true);
          await pending.rename(file.path);
        } finally {
          if (await pending.exists()) await pending.delete();
        }
        return report;
      });

  /// Returns the complete V3 `data` object, detached from the stored card.
  /// Unknown and read-only fields stay available to a character editor.
  Future<Map<String, Object?>?> readFields(String id) async {
    final record = await read(id);
    if (record == null) return null;
    return jsonDecode(jsonEncode(record.card.data)) as Map<String, Object?>;
  }

  /// Internal raw bridge read. The synchronous projection runs under the real
  /// character queue so its data and observed target token cannot be mixed
  /// with another adoption. It never opens the import/media for a raw read.
  Future<T?> readAuthority<T>(String id, T Function(Map<String, Object?> data) project) => _exclusive(() async {
    _requireId(id);
    await _tidy();
    final envelope = await _readAuthorityEnvelope(id);
    if (envelope == null) return null;
    return project(envelope['data']! as Map<String, Object?>);
  });

  /// Internal runtime read of the authority JSON. The projection must not
  /// mutate its data: unchanged file revisions share this private parse tree.
  /// Writes and CAS use [readAuthority] or [readAuthoringSnapshot] instead.
  Future<T?> readRuntimeAuthority<T>(String id, T Function(Map<String, Object?> data) project) => _exclusive(() async {
    _requireId(id);
    final directory = '${_characters.path}/$id';
    final type = await FileSystemEntity.type(directory, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      _invalidateRuntimeCharacter(id);
      return null;
    }
    if (type != FileSystemEntityType.directory) throw const FileSystemException('Character folder is not a directory');
    final file = File('$directory/card.json');
    final version = _characterFileVersion(await file.stat());
    final cached = _runtimeAuthority.remove(id);
    if (cached != null && cached.version == version) {
      _runtimeAuthority[id] = cached;
      return project(cached.data);
    }
    final envelope = await _decodeRuntimeAuthority(await file.readAsBytes());
    final data = envelope['data']! as Map<String, Object?>;
    _runtimeAuthority[id] = (version: version, data: data);
    if (_runtimeAuthority.length > _runtimeCacheCapacity) _runtimeAuthority.remove(_runtimeAuthority.keys.first);
    return project(data);
  });

  /// Complete source for a persistent authoring base, without loading or
  /// upgrading original/media bytes. The caller owns the returned JSON.
  Future<
    ({
      Map<String, Object?> document,
      String rawText,
      String identityText,
      String sourceFormat,
      List<String> mediaRefs,
      TavernAuthorityRevision? authorityRevision,
    })?
  >
  readAuthoringSnapshot(String id) => _exclusive(() async {
    _requireId(id);
    authority?.checkWritable('character:$id');
    await _tidy();
    final directory = Directory('${_characters.path}/$id');
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      final owner = authority;
      if (owner != null) owner.observe('character:$id', await _readAuthoringResource(id));
      return null;
    }
    if (type != FileSystemEntityType.directory) throw const FileSystemException('Character folder is not a directory');
    final bytes = await File('${directory.path}/card.json').readAsBytes();
    final rawText = decodeAuthoringText(bytes).rawText;
    final identity = await readAuthoringText(File('${directory.path}/library.json'));
    final revision = authority?.observe(
      'character:$id',
      AuthoringResourceSnapshot(present: true, rawText: rawText, identityText: identity.rawText),
    );
    final document = const CardCodec().decodeAuthority(bytes);
    final metadata = jsonDecode(identity.text);
    if (metadata is! Map<String, Object?> ||
        metadata['version'] != 1 ||
        !const ['png', 'json', 'charx'].contains(metadata['sourceFormat']) ||
        metadata['resources'] is! List<Object?>) {
      throw const TavernImportError('资料库元数据无效。');
    }
    final paths = metadata['resources']! as List<Object?>;
    if (paths.any((path) => path is! String)) throw const TavernImportError('资料库资源目录无效。');
    return (
      document: document,
      rawText: rawText,
      identityText: identity.rawText,
      sourceFormat: metadata['sourceFormat']! as String,
      mediaRefs: paths.cast<String>().toList(),
      authorityRevision: revision,
    );
  });

  /// Reads the complete source and the manifest's actual media once under the
  /// character queue. Unlike a persistent authoring base this neither tidies
  /// artifacts nor observes a new authority revision.
  Future<AuthoringCharacterCapture> readAuthoringCapture(String id) => _exclusive(() async {
    _requireId(id);
    authority?.checkWritable('character:$id');
    final snapshot = await _readAuthoringResource(id);
    if (!snapshot.present) {
      return AuthoringCharacterCapture(snapshot: snapshot, ledger: authority?.peek('character:$id'));
    }
    final bytes = Uint8List.fromList(utf8.encode(snapshot.rawText!));
    final document = const CardCodec().decodeAuthority(bytes);
    final metadata = jsonDecode(decodeAuthoringText(utf8.encode(snapshot.identityText!)).text);
    if (metadata is! Map<String, Object?> ||
        metadata['version'] != 1 ||
        !const ['png', 'json', 'charx'].contains(metadata['sourceFormat']) ||
        metadata['resources'] is! List<Object?>) {
      throw const TavernImportError('资料库元数据无效。');
    }
    final directory = '${_characters.path}/$id';
    final paths = metadata['resources']! as List<Object?>;
    final assets = <String, Uint8List>{};
    final media = <String, Uint8List>{};
    for (final path in paths) {
      if (path is! String || !isSafeCardAssetPath(path)) {
        throw const TavernImportError('资料库资源路径无效。');
      }
      final value = await File('$directory/resources/$path').readAsBytes();
      assets[path] = value;
      media['resources/$path'] = value;
    }
    final parsed = await _decodeStored(bytes);
    final importedAtValue = metadata['importedAt'];
    final importedAt = importedAtValue is String ? DateTime.tryParse(importedAtValue) : null;
    if (importedAt == null) {
      throw const TavernImportError('资料库导入时间无效。');
    }
    final format = TavernCardFormat.values.byName(metadata['sourceFormat']! as String);
    final png = metadata['hasPng'] == true ? await File('$directory/source.png').readAsBytes() : null;
    if (png != null) {
      media['source.png'] = png;
    }
    final original = await File('$directory/original.${format.name}').readAsBytes();
    media['original.${format.name}'] = original;
    final avatarSelection = _avatarSelection(metadata);
    final selectedAvatar = avatarSelection.file == null
        ? null
        : await _readAvatarFile(directory, avatarSelection.file!, avatarSelection.sha256);
    if (selectedAvatar != null) {
      media[avatarSelection.file!] = selectedAvatar;
    }
    return AuthoringCharacterCapture(
      snapshot: snapshot,
      document: document,
      character: StoredCharacter(
        id: id,
        importedAt: importedAt,
        card: TavernCard(
          json: parsed.json,
          assets: assets,
          png: png,
          avatar: avatarSelection.sha256 == null ? null : selectedAvatar,
          originalBytes: original,
          sourceFormat: format,
        ),
      ),
      mediaRefs: paths.cast<String>().toList(),
      media: media,
      ledger: authority?.peek('character:$id'),
    );
  });

  /// Only the files read by this dependency are compared. The engine performs
  /// its final synchronous ledger check after all resource I/O has drained.
  Future<bool> recheckAuthoringCapture(String id, AuthoringCharacterCapture captured) => _exclusive(() async {
    _requireId(id);
    try {
      if (!(await _readAuthoringResource(id)).sameAs(captured.snapshot)) {
        return false;
      }
      for (final entry in captured.media.entries) {
        final fresh = await File('${_characters.path}/$id/${entry.key}').readAsBytes();
        if (!_sameAuthoringCaptureBytes(entry.value, fresh)) {
          return false;
        }
      }
      return true;
    } on PathNotFoundException catch (error) {
      final code = error.osError?.errorCode;
      if (code == 2 || (Platform.isWindows && code == 3)) {
        return false;
      }
      rethrow;
    }
  });

  /// Internal full-data/embedded-book writer. [prepare] is synchronous and is
  /// called once against current authoritative data inside the queue. It owns
  /// expected-version checks; it must neither await nor perform external I/O.
  /// The adopted data is reported immediately after the real rename, before
  /// the fallible derived summary. Original bytes and source format stay put.
  Future<StoredCharacter> updateAuthority(
    String id,
    Map<String, Object?> Function(Map<String, Object?> current) prepare, {
    void Function(Map<String, Object?> actual)? onCommitted,
    void Function()? check,
  }) => _exclusive(() async {
    _requireId(id);
    _checkManagedWriter(id);
    await _tidy();
    final envelope = await _readAuthorityEnvelope(id);
    if (envelope == null) throw const TavernImportError('角色不存在。');
    final next = prepare(envelope['data']! as Map<String, Object?>);
    final json = <String, Object?>{...envelope, 'data': jsonDecode(jsonEncode(next)) as Map<String, Object?>};
    const CardCodec().validateAuthority(json);
    final record = await _read(id);
    if (record == null) throw const TavernImportError('角色不存在。');
    final result = await _publishCard(
      record,
      json,
      runtimeProjection: true,
      check: check,
      onCommitted: () => onCommitted?.call(json['data']! as Map<String, Object?>),
    );
    return result.record;
  });

  /// Internal authoring adoption. The complete validated envelope is written
  /// exactly as supplied; runtime defaults never enter the authoritative file.
  Future<TavernAuthoringReceipt> writeAuthoringEnvelope(
    String id,
    String rawText, {
    required AuthoringWriteRequest request,
    required AuthoringExpectation expected,
    void Function()? check,
  }) => _exclusive(() async {
    _requireId(id);
    _checkManagedWriter();
    final owner = authority;
    if (owner == null) throw StateError('Authoring requires the managed character authority.');
    final replayed = owner.replay(request);
    if (replayed != null) return replayed;
    owner.checkWritable('character:$id');
    await _tidy();
    final Map<String, Object?> document;
    try {
      document = const CardCodec().decodeAuthority(Uint8List.fromList(utf8.encode(rawText)));
    } on FormatException {
      throw TavernAuthoringException(
        'invalid_change',
        'The candidate character envelope is invalid.',
        physicalResourceId: 'character:$id',
      );
    } on TavernImportError {
      throw TavernAuthoringException(
        'invalid_change',
        'The candidate character envelope is invalid.',
        physicalResourceId: 'character:$id',
      );
    }
    final record = await _read(id);
    if (record == null) {
      throw TavernAuthoringException(
        'authority_conflict',
        'The character no longer exists.',
        physicalResourceId: 'character:$id',
      );
    }
    final result = await _publishCard(
      record,
      document,
      runtimeProjection: true,
      rawText: rawText,
      request: request,
      expected: expected,
      check: check,
    );
    return result.receipt!;
  });

  Future<Map<String, Object?>?> _readAuthorityEnvelope(String id) async {
    final directory = Directory('${_characters.path}/$id');
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) {
      throw const FileSystemException('Character folder is not a directory');
    }
    return const CardCodec().decodeAuthority(await File('${directory.path}/card.json').readAsBytes());
  }

  /// Changes only the supplied editable fields. Empty strings/lists clear a
  /// field; null, unknown keys and values of the wrong type are rejected.
  ///
  /// A nonempty patch updates `modification_date` in Unix seconds. An empty
  /// patch reads the existing record without rewriting it. The original
  /// import, portrait, resources, metadata and every other JSON value remain
  /// intact. Publish the complete JSON by rename so an interrupted write
  /// cannot expose a truncated card.
  Future<StoredCharacter> updateFields(String id, Map<String, Object?> fields) async {
    _requireId(id);
    // Snapshot and validate before queueing: callers may reuse their form map.
    final updates = _fieldUpdates(fields);
    return _exclusive(() async {
      _checkManagedWriter(id);
      await _tidy();
      final record = await _read(id);
      if (record == null) throw const TavernImportError('角色不存在。');
      if (updates.isEmpty) {
        await _observeCharacter(id);
        return record;
      }
      final json = jsonDecode(jsonEncode(record.card.json)) as Map<String, Object?>;
      final data = json['data'] as Map<String, Object?>;
      data.addAll(updates);
      return _saveCard(record, json);
    });
  }

  /// Internal bridge persistence: only the two existing helper carriers may
  /// change. Other card extensions, assets, original bytes and identity stay
  /// intact. The engine supplies the latest detached extension document while
  /// owning its character queue; this does not broaden updateFields.
  /// Persist from authority; decoder defaults belong only to the returned
  /// runtime view, including defaults in an unrelated embedded book.
  Future<StoredCharacter> updateScriptStorage(
    String id,
    Map<String, Object?> extensions, {
    void Function()? onCommitted,
  }) {
    _requireId(id);
    final captured = jsonDecode(jsonEncode(extensions)) as Map<String, Object?>;
    return _exclusive(() async {
      _checkManagedWriter(id);
      await _tidy();
      final record = await _read(id);
      if (record == null) {
        throw const TavernImportError('角色不存在。');
      }
      final json = await _readAuthorityEnvelope(id);
      if (json == null) {
        throw const TavernImportError('角色不存在。');
      }
      final data = json['data']! as Map<String, Object?>;
      final previous = data['extensions'];
      if (previous != null && previous is! Map<String, Object?>) {
        throw const FormatException('Character extensions must be an object.');
      }
      final old = previous is Map<String, Object?> ? previous : <String, Object?>{};
      final keys = {...old.keys, ...captured.keys}..removeAll(const {'tavern_helper', 'TavernHelper_scripts'});
      for (final key in keys) {
        if (old.containsKey(key) != captured.containsKey(key) || jsonEncode(old[key]) != jsonEncode(captured[key])) {
          throw ArgumentError('Only helper storage can be changed by this operation.');
        }
      }
      data['extensions'] = captured;
      return _saveCard(record, json, runtimeProjection: true, onCommitted: onCommitted);
    });
  }

  /// Adds one CC book entry, assigning an unused integer id. Input is copied
  /// before queueing. The caller cannot supply `id`; omitted known fields use
  /// ordinary CC defaults. A missing book starts with an empty entries array.
  Future<StoredCharacter> addBookEntry(String id, Map<String, Object?> entry) async {
    _requireId(id);
    final updates = _bookEntryUpdates(entry);
    return _editBook(id, (entries) {
      entries.add({
        'id': _nextBookEntryId(entries),
        'keys': <String>[],
        'secondary_keys': <String>[],
        'content': '',
        'enabled': true,
        'constant': false,
        'selective': false,
        'insertion_order': 100,
        'position': 'before_char',
        'use_regex': false,
        'extensions': <String, Object?>{},
        ...updates,
      });
      return true;
    });
  }

  /// Patches the entry at its stored array [index], not its potentially
  /// duplicate id. Extensions merge recursively; other supplied fields
  /// replace their old value. Unknown omitted JSON values remain intact.
  /// An empty patch validates the target and returns the unchanged character
  /// without writing.
  Future<StoredCharacter> updateBookEntry(String id, int index, Map<String, Object?> fields) async {
    _requireId(id);
    final updates = _bookEntryUpdates(fields);
    return _editBook(id, (entries) {
      _requireBookIndex(index, entries);
      if (updates.isEmpty) {
        return false;
      }
      final entry = entries[index]! as Map<String, Object?>;
      for (final update in updates.entries) {
        final old = entry[update.key];
        entry[update.key] = update.key == 'extensions'
            ? _mergeBookExtensions(old is Map<String, Object?> ? old : {}, update.value! as Map<String, Object?>)
            : update.value;
      }
      return true;
    });
  }

  /// Removes only the addressed array entry. Non-null existing ids, including
  /// duplicates, retain their original order and values. Before a real edit,
  /// missing/null ids are fixed to their old fallback array index so deletion
  /// cannot shift the logical identities of later entries. Normalizing a
  /// stored null can change that entry's native ST timer key and hash.
  Future<StoredCharacter> deleteBookEntry(String id, int index) async {
    _requireId(id);
    return _editBook(id, (entries) {
      _requireBookIndex(index, entries);
      entries.removeAt(index);
      return true;
    });
  }

  Future<StoredCharacter> _editBook(String id, bool Function(List<Object?> entries) edit) => _exclusive(() async {
    _checkManagedWriter(id);
    await _tidy();
    final record = await _read(id);
    if (record == null) {
      throw const TavernImportError('角色不存在。');
    }
    final json = jsonDecode(jsonEncode(record.card.json)) as Map<String, Object?>;
    final data = json['data']! as Map<String, Object?>;
    final book = _editableBook(data['character_book']);
    final entries = book['entries']! as List<Object?>;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index]! as Map<String, Object?>;
      entry['id'] ??= index;
    }
    if (!edit(entries)) {
      await _observeCharacter(id);
      return record;
    }
    data['character_book'] = book;
    return _saveCard(record, json);
  });

  Future<StoredCharacter> _saveCard(
    StoredCharacter record,
    Map<String, Object?> json, {
    bool runtimeProjection = false,
    void Function()? onCommitted,
  }) async {
    (json['data']! as Map<String, Object?>)['modification_date'] = _now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final result = await _publishCard(record, json, runtimeProjection: runtimeProjection, onCommitted: onCommitted);
    return result.record;
  }

  Future<({StoredCharacter record, TavernAuthoringReceipt? receipt})> _publishCard(
    StoredCharacter record,
    Map<String, Object?> json, {
    bool runtimeProjection = false,
    String? rawText,
    AuthoringWriteRequest? request,
    AuthoringExpectation? expected,
    void Function()? check,
    void Function()? onCommitted,
  }) async {
    final text = rawText ?? jsonEncode(json);
    final runtimeJson = runtimeProjection ? const CardCodec().decode(Uint8List.fromList(utf8.encode(text))).json : json;
    final updated = StoredCharacter(
      id: record.id,
      card: TavernCard(
        json: runtimeJson,
        assets: record.card.assets,
        png: record.card.png,
        avatar: record.card.avatar,
        originalBytes: record.card.originalBytes,
        sourceFormat: record.card.sourceFormat,
      ),
      importedAt: record.importedAt,
      avatarPath: record.avatarPath,
      directoryPath: record.directoryPath,
    );
    final summary = _summarize(updated);
    final cardFile = File('${_characters.path}/${record.id}/card.json');
    final pending = File('${cardFile.path}.writing');
    final owner = authority;
    final before = owner == null ? null : await _readAuthoringResource(record.id);
    final after = AuthoringResourceSnapshot(present: true, rawText: text, identityText: before?.identityText);
    final ticket = owner == null
        ? null
        : AuthoringWriteTicket(
            request:
                request ??
                owner.newRequest('character:${record.id}', {'method': 'writeCharacter', 'after': after.toJson()}),
            before: before!,
            after: after,
          );
    try {
      if (ticket != null) {
        if (expected != null && before!.sameAs(after)) {
          return (record: record, receipt: owner!.notAdopted(ticket, noChange: true, expected: expected, check: check));
        }
        final replayed = owner!.prepare(ticket, expected: expected, check: check);
        if (replayed != null) return (record: record, receipt: replayed);
      } else {
        check?.call();
      }
      // No committed source revision may retain a readable older index.
      await _invalidateSummary(record.id);
      if (request == null) check?.call();
      await pending.writeAsString(text, flush: true);
      if (request == null) check?.call();
      ticket?.enteredEffect = true;
      await pending.rename(cardFile.path);
      ticket?.knownAdopted = true;
      try {
        _invalidateRuntimeCharacter(record.id);
        cardCommitted?.call(record.id, json['data']! as Map<String, Object?>);
      } finally {
        onCommitted?.call();
      }
      // fail() also records this known return if either notification throws.
      if (ticket != null) owner!.adopted(ticket);
      await _writeSummary(summary);
      return (record: updated, receipt: ticket == null ? null : owner!.publish(ticket));
    } catch (error, stack) {
      if (ticket != null) owner!.fail(ticket, error, stack);
      rethrow;
    } finally {
      try {
        if (await pending.exists()) {
          await pending.delete();
        }
      } on FileSystemException {
        // The complete JSON candidate is already in the journal; this file
        // does not contain the import/media evidence kept in staging/trash.
      }
    }
  }

  /// Reads only derived summaries for current character directories. Old or
  /// damaged indexes are rebuilt from library.json and card.json, without
  /// opening the original import, images or embedded resource files.
  Future<List<StoredCharacterSummary>> list() => _exclusive(() async {
    await _tidy();
    final records = <StoredCharacterSummary>[];
    await for (final entity in _characters.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = _name(entity);
      if (!_idPattern.hasMatch(id)) continue;
      records.add(await _readSummary(id));
    }
    records.sort((a, b) {
      final byTime = b.importedAt.compareTo(a.importedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return records;
  });

  Future<Uint8List> exportCard(String id, {TavernCardFormat format = TavernCardFormat.png}) => _exclusive(() async {
    _requireId(id);
    await _tidy();
    final record = await _read(id);
    if (record == null) throw const TavernImportError('角色不存在。');
    final modifiedAt = _now().toUtc();
    final card = record.card;
    return _encodeCard(card, format, modifiedAt);
  });

  /// The Tavern layer deletes this character's chats as part of its operation.
  /// This method owns only the files; it cannot reach an unrelated character.
  Future<void> delete(String id) => _exclusive(() async {
    _requireId(id);
    _checkManagedWriter(id);
    await _tidy();
    if (authority != null) {
      await _deleteManaged(id);
      return;
    }
    final directory = Directory('${_characters.path}/$id');
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      try {
        // type() also hides lookup errors. Only confirmed absence may let the
        // facade remove this character's chats without renaming its directory.
        await FileSystemEntity.identical(directory.path, directory.path);
      } on PathNotFoundException catch (error) {
        final code = error.osError?.errorCode;
        if (code != 2 && !(Platform.isWindows && code == 3)) {
          rethrow;
        }
        if (await FileSystemEntity.type(directory.path, followLinks: false) != FileSystemEntityType.notFound) {
          rethrow;
        }
        await _discardSummary(id);
        return;
      }
      throw FileSystemException('The character folder could not be identified as absent.', directory.path);
    }
    if (type != FileSystemEntityType.directory) throw const FileSystemException('Character folder is not a directory');
    final trash = await directory.rename('${_characters.path}/.trash-${_newId()}');
    await _discard(trash);
    await _discardSummary(id);
  });

  Future<void> _deleteManaged(String id) async {
    final owner = authority!;
    // Deletion records source text without asking a JSON codec to accept it.
    // An unreadable/missing carrier is not a fabricated empty before-image.
    final before = await _readAuthoringResource(id);
    final trash = Directory('${_characters.path}/.trash-${_newId()}');
    final ticket = AuthoringWriteTicket(
      request: owner.newRequest('character:$id', {'method': 'deleteCharacter'}),
      before: before,
      after: const AuthoringResourceSnapshot(present: false),
      artifacts: before.present ? ['characters/${_name(trash)}'] : const [],
    );
    try {
      if (!before.present) {
        owner.notAdopted(ticket, noChange: true);
        _invalidateRuntimeCharacter(id);
        cardRemoved?.call(id);
        await _discardSummary(id);
        return;
      }
      if (owner.prepare(ticket) != null) return;
      ticket.enteredEffect = true;
      await Directory('${_characters.path}/$id').rename(trash.path);
      ticket.knownAdopted = true;
      _invalidateRuntimeCharacter(id);
      cardRemoved?.call(id);
      owner.adopted(ticket);
      await _discard(trash);
      await _discardSummary(id);
      owner.publish(ticket);
    } catch (error, stack) {
      owner.fail(ticket, error, stack);
    }
  }

  Future<StoredCharacterSummary> _readSummary(String id) async {
    final directory = Directory('${_characters.path}/$id');
    try {
      // A cache is optional. Ignore links and non-files rather than following
      // them or recursively removing something that is not our index file.
      if (await FileSystemEntity.type(_indexes.path, followLinks: false) == FileSystemEntityType.directory) {
        final file = _indexFile(id);
        if (await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.file) {
          return _summaryFromJson(jsonDecode(await file.readAsString()), id, directory.path);
        }
      }
    } on FileSystemException {
      // Source JSON below remains authoritative when the cache is unreadable.
    } on FormatException {
      // Includes invalid JSON/UTF-8, wrong versions and wrong summary types.
    }

    // Validate the same stored metadata contract as _read, but do not load
    // any file named in the resource manifest or the original/image flags.
    final value = jsonDecode(await File('${directory.path}/library.json').readAsString());
    if (value is! Map<String, Object?> || value['version'] != 1) {
      throw const TavernImportError('资料库元数据版本无效。');
    }
    if (!const {'png', 'json', 'charx'}.contains(value['sourceFormat'])) {
      throw const TavernImportError('资料库原件格式无效。');
    }
    final resources = value['resources'];
    if (resources is! List<Object?>) throw const TavernImportError('资料库资源目录无效。');
    for (final path in resources) {
      if (path is! String || !isSafeCardAssetPath(path)) throw const TavernImportError('资料库资源路径无效。');
    }
    final importedAtValue = value['importedAt'];
    if (importedAtValue is! String) throw const TavernImportError('资料库导入时间无效。');
    final importedAt = DateTime.tryParse(importedAtValue);
    if (importedAt == null) throw const TavernImportError('资料库导入时间无效。');
    final card = await _decodeStored(await File('${directory.path}/card.json').readAsBytes());
    final avatarFile = _avatarSelection(value).file;
    final summary = _summarize(
      StoredCharacter(
        id: id,
        card: card,
        importedAt: importedAt,
        avatarPath: avatarFile == null ? null : '${directory.path}/$avatarFile',
      ),
    );
    await _writeSummary(summary);
    return summary;
  }

  Future<void> _invalidateSummary(String id) async {
    final parentType = await FileSystemEntity.type(_indexes.path, followLinks: false);
    if (parentType != FileSystemEntityType.directory && parentType != FileSystemEntityType.notFound) return;
    final file = _indexFile(id);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      if (type != FileSystemEntityType.notFound) return;
      // type also reports lookup errors as notFound. On Linux, delete can
      // remap the same error to ENOENT, so probe with a read-only open first.
      final RandomAccessFile probe;
      try {
        probe = await file.open(mode: FileMode.read);
      } on PathNotFoundException catch (error) {
        final code = error.osError?.errorCode;
        // Accept only ENOENT / Windows file-or-path-not-found. Other Windows
        // PathNotFoundException codes include unavailable network paths.
        if (code == 2 || (Platform.isWindows && code == 3)) return;
        rethrow;
      }
      await probe.close();
    }
    // A readable index must be removed before source publication. Close and
    // delete failures must not be mistaken for absence by the open catch.
    await file.delete();
  }

  Future<void> _discardSummary(String id) async {
    try {
      await _invalidateSummary(id);
    } on FileSystemException {
      // Membership comes from committed card directories, so an orphaned
      // derived file cannot resurrect a deleted character.
    }
  }

  Future<void> _writeSummary(StoredCharacterSummary summary) async {
    final file = _indexFile(summary.id);
    final pending = File('${file.path}.writing');
    var cleanPending = false;
    try {
      final type = await FileSystemEntity.type(_indexes.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await _indexes.create(recursive: true);
      } else if (type != FileSystemEntityType.directory) {
        return;
      }
      final pendingType = await FileSystemEntity.type(pending.path, followLinks: false);
      if (pendingType != FileSystemEntityType.notFound && pendingType != FileSystemEntityType.file) return;
      cleanPending = true;
      await pending.writeAsString(jsonEncode(_summaryJson(summary)), flush: true);
      await pending.rename(file.path);
    } on FileSystemException {
      // Derived-cache failure cannot undo a successfully committed card or
      // turn a successful source-JSON read into a failed list operation.
    } finally {
      try {
        if (cleanPending &&
            await FileSystemEntity.type(pending.path, followLinks: false) == FileSystemEntityType.file) {
          await pending.delete();
        }
      } on FileSystemException {
        // A later write can replace a leftover uncommitted regular file.
      }
    }
  }

  Future<StoredCharacter?> _read(String id) async {
    final directory = Directory('${_characters.path}/$id');
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) throw const FileSystemException('Character folder is not a directory');
    final metadataValue = jsonDecode(await File('${directory.path}/library.json').readAsString());
    if (metadataValue is! Map<String, Object?> || metadataValue['version'] != 1) {
      throw const TavernImportError('资料库元数据版本无效。');
    }
    final formatValue = metadataValue['sourceFormat'];
    final sourceFormat = switch (formatValue) {
      'png' => TavernCardFormat.png,
      'json' => TavernCardFormat.json,
      'charx' => TavernCardFormat.charx,
      _ => throw const TavernImportError('资料库原件格式无效。'),
    };
    final resourcePaths = metadataValue['resources'];
    if (resourcePaths is! List<Object?>) throw const TavernImportError('资料库资源目录无效。');
    final assets = <String, Uint8List>{};
    for (final path in resourcePaths) {
      if (path is! String || !isSafeCardAssetPath(path)) throw const TavernImportError('资料库资源路径无效。');
      assets[path] = await File('${directory.path}/resources/$path').readAsBytes();
    }
    final cardJson = await File('${directory.path}/card.json').readAsBytes();
    final parsed = await _decodeStored(cardJson);
    final importedAtValue = metadataValue['importedAt'];
    if (importedAtValue is! String) throw const TavernImportError('资料库导入时间无效。');
    final importedAt = DateTime.tryParse(importedAtValue);
    if (importedAt == null) throw const TavernImportError('资料库导入时间无效。');
    final avatarSelection = _avatarSelection(metadataValue);
    final card = TavernCard(
      json: parsed.json,
      assets: assets,
      png: metadataValue['hasPng'] == true ? await File('${directory.path}/source.png').readAsBytes() : null,
      avatar: await _readAvatarOverride(directory.path, metadataValue),
      originalBytes: await File('${directory.path}/original.${sourceFormat.name}').readAsBytes(),
      sourceFormat: sourceFormat,
    );
    return StoredCharacter(
      id: id,
      card: card,
      importedAt: importedAt,
      avatarPath: avatarSelection.file == null ? null : '${directory.path}/${avatarSelection.file}',
      directoryPath: directory.absolute.path,
    );
  }

  Future<void> _tidy() async {
    final protected = _protectedArtifacts();
    if (protected == null) return;
    await _characters.create(recursive: true);
    await for (final entity in _characters.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = _name(entity);
      if ((name.startsWith('.staging-') || name.startsWith('.trash-')) && !protected.contains('characters/$name')) {
        await _discard(entity);
      }
    }
  }
}

final _avatarFilePattern = RegExp(r'^avatar-[0-9a-f]{64}\.png$');
final _avatarDigestPattern = RegExp(r'^[0-9a-f]{64}$');

typedef _CharacterFileVersion = ({FileSystemEntityType type, int size, DateTime modified, DateTime changed});

_CharacterFileVersion _characterFileVersion(FileStat stat) =>
    (type: stat.type, size: stat.size, modified: stat.modified, changed: stat.changed);

({String? file, String? sha256}) _avatarSelection(Map<String, Object?> metadata) {
  if (!metadata.containsKey('avatar')) {
    return (file: metadata['hasPortrait'] == true ? 'portrait.png' : null, sha256: null);
  }
  final avatar = metadata['avatar'];
  if (avatar is! Map<String, Object?>) {
    throw const TavernImportError('资料库头像元数据无效。');
  }
  final file = avatar['file'];
  final digest = avatar['sha256'];
  if (file is! String ||
      !_avatarFilePattern.hasMatch(file) ||
      digest is! String ||
      !_avatarDigestPattern.hasMatch(digest) ||
      file != 'avatar-$digest.png') {
    throw const TavernImportError('资料库头像元数据无效。');
  }
  return (file: file, sha256: digest);
}

CharacterAvatarMetadata _avatarMetadata(AuthoringResourceSnapshot snapshot) {
  if (!snapshot.present) {
    return CharacterAvatarMetadata(snapshot: snapshot);
  }
  final metadata = jsonDecode(decodeAuthoringText(utf8.encode(snapshot.identityText!)).text);
  if (metadata is! Map<String, Object?> || metadata['version'] != 1) {
    throw const TavernImportError('资料库元数据版本无效。');
  }
  final selected = _avatarSelection(metadata);
  return CharacterAvatarMetadata(snapshot: snapshot, file: selected.file, sha256: selected.sha256);
}

Future<Uint8List> _readAvatarFile(String directory, String file, String? digest) async {
  final bytes = await File('$directory/$file').readAsBytes();
  if (digest != null && crypto.sha256.convert(bytes).toString() != digest) {
    throw const TavernImportError('资料库头像内容摘要不匹配。');
  }
  return bytes;
}

Future<Uint8List?> _readAvatarOverride(String directory, Map<String, Object?> metadata) async {
  final selected = _avatarSelection(metadata);
  if (selected.sha256 == null) {
    return null;
  }
  return _readAvatarFile(directory, selected.file!, selected.sha256);
}

String _avatarFileName(Uint8List bytes) => 'avatar-${crypto.sha256.convert(bytes)}.png';

Future<void> _writeImmutableAvatar(File file, Uint8List bytes) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.file) {
    if (!_sameAuthoringCaptureBytes(await file.readAsBytes(), bytes)) {
      throw FileSystemException('An immutable avatar path already contains different bytes.', file.path);
    }
    return;
  }
  if (type != FileSystemEntityType.notFound) {
    throw FileSystemException('The immutable avatar path is not a regular file.', file.path);
  }
  final pending = File('${file.path}.${_newId()}.writing');
  await pending.create(exclusive: true);
  await pending.writeAsBytes(bytes, flush: true);
  // Do not expose a partially written content-addressed filename. A failed
  // staging write remains unreferenced and cannot poison a later retry.
  final current = await FileSystemEntity.type(file.path, followLinks: false);
  if (current == FileSystemEntityType.file) {
    if (!_sameAuthoringCaptureBytes(await file.readAsBytes(), bytes)) {
      throw FileSystemException('An immutable avatar path already contains different bytes.', file.path);
    }
    await pending.delete();
    return;
  }
  if (current != FileSystemEntityType.notFound) {
    throw FileSystemException('The immutable avatar path is not a regular file.', file.path);
  }
  await pending.rename(file.path);
}

bool _sameAuthoringCaptureBytes(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

StoredCharacterSummary _summarize(StoredCharacter record) {
  // Project only list fields. Do not clone theme, greetings or asset DTOs just
  // to discard them while recovering an old library's missing summary index.
  final card = record.card;
  final data = card.data;
  final tags = data['tags'];
  return StoredCharacterSummary(
    id: record.id,
    name: card.name,
    nickname: data['nickname'] is String ? data['nickname'] as String : null,
    creator: data['creator'] is String ? data['creator'] as String : null,
    tags: tags is List<Object?> ? tags.whereType<String>().toList() : const [],
    avatarPath: record.avatarPath,
    importedAt: record.importedAt,
    regexCount: card.regexCount,
    scriptCount: card.scriptCount,
    hasLorebook: data['character_book'] is Map<String, Object?>,
  );
}

Map<String, Object?> _summaryJson(StoredCharacterSummary summary) => {
  'version': 1,
  'id': summary.id,
  'name': summary.name,
  'nickname': summary.nickname,
  'creator': summary.creator,
  'tags': summary.tags,
  'importedAt': summary.importedAt.toIso8601String(),
  // Derive the path from the current root when loading, so moving a complete
  // library does not leave absolute paths pointing at its previous location.
  'hasPortrait': summary.avatarPath != null,
  if (summary.avatarPath != null && _name(File(summary.avatarPath!)) != 'portrait.png')
    'avatarFile': _name(File(summary.avatarPath!)),
  'regexCount': summary.regexCount,
  'scriptCount': summary.scriptCount,
  'hasLorebook': summary.hasLorebook,
};

StoredCharacterSummary _summaryFromJson(Object? value, String id, String directoryPath) {
  const fields = {
    'version',
    'id',
    'name',
    'nickname',
    'creator',
    'tags',
    'importedAt',
    'hasPortrait',
    'regexCount',
    'scriptCount',
    'hasLorebook',
  };
  if (value is! Map<String, Object?> ||
      !value.keys.toSet().containsAll(fields) ||
      value['version'] is! int ||
      value['version'] != 1 ||
      value['id'] != id) {
    throw const FormatException('Invalid character summary index.');
  }
  final name = value['name'];
  final nickname = value['nickname'];
  final creator = value['creator'];
  final tags = value['tags'];
  final importedAtValue = value['importedAt'];
  final hasPortrait = value['hasPortrait'];
  final regexCount = value['regexCount'];
  final scriptCount = value['scriptCount'];
  final hasLorebook = value['hasLorebook'];
  if (name is! String ||
      (nickname != null && nickname is! String) ||
      (creator != null && creator is! String) ||
      tags is! List<Object?> ||
      tags.any((tag) => tag is! String) ||
      importedAtValue is! String ||
      hasPortrait is! bool ||
      hasLorebook is! bool ||
      regexCount is! int ||
      regexCount < 0 ||
      scriptCount is! int ||
      scriptCount < 0) {
    throw const FormatException('Invalid character summary fields.');
  }
  final importedAt = DateTime.tryParse(importedAtValue);
  if (importedAt == null) throw const FormatException('Invalid character summary time.');
  final avatarFile = value['avatarFile'];
  if (value.containsKey('avatarFile') &&
      (avatarFile is! String || !_avatarFilePattern.hasMatch(avatarFile) || !hasPortrait)) {
    throw const FormatException('Invalid character summary avatar.');
  }
  return StoredCharacterSummary(
    id: id,
    name: name,
    nickname: nickname as String?,
    creator: creator as String?,
    tags: List<String>.from(tags),
    importedAt: importedAt,
    avatarPath: hasPortrait ? '$directoryPath/${avatarFile ?? 'portrait.png'}' : null,
    regexCount: regexCount,
    scriptCount: scriptCount,
    hasLorebook: hasLorebook,
  );
}

final _idPattern = RegExp(r'^card-[0-9a-f]{32}$');

const _editableTextFields = {
  'name',
  'nickname',
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
};
const _editableListFields = {'alternate_greetings', 'tags'};

Map<String, Object?> _fieldUpdates(Map<String, Object?> fields) {
  final updates = <String, Object?>{};
  for (final entry in fields.entries) {
    final value = entry.value;
    if (_editableTextFields.contains(entry.key)) {
      if (value is! String) throw ArgumentError.value(value, entry.key, 'Expected a string');
      updates[entry.key] = value;
    } else if (_editableListFields.contains(entry.key)) {
      if (value is! List<Object?> || value.any((item) => item is! String)) {
        throw ArgumentError.value(value, entry.key, 'Expected a list of strings');
      }
      updates[entry.key] = List<String>.from(value);
    } else {
      throw ArgumentError.value(entry.key, 'fields', 'This character field is read-only or unknown');
    }
  }
  return updates;
}

Map<String, Object?> _editableBook(Object? value) {
  if (value == null) {
    return {'extensions': <String, Object?>{}, 'entries': <Object?>[]};
  }
  if (value is! Map<String, Object?>) {
    throw ArgumentError.value(value, 'character_book', 'Expected a CC book object');
  }
  final entries = value['entries'];
  if (entries == null) {
    value['entries'] = <Object?>[];
  } else if (entries is! List<Object?> || entries.any((entry) => entry is! Map<String, Object?>)) {
    // Native ST maps remain readable by WorldInfoBook. This editor addresses
    // CC array indices and must not silently convert or drop a native map.
    throw ArgumentError.value(entries, 'entries', 'Book editing requires an array of entry objects');
  }
  return value;
}

void _requireBookIndex(int index, List<Object?> entries) {
  if (index < 0 || index >= entries.length) {
    throw RangeError.index(index, entries, 'index');
  }
}

int _nextBookEntryId(List<Object?> entries) {
  // Use the same JS-string identity as T6, including numeric 1.0 == 1 and
  // existing unusual ids. Never write the normalized execution view back.
  final occupied = WorldInfoBook.fromJson(
    id: 'library-edit',
    source: WorldInfoSource.character,
    json: {'entries': entries},
  ).entries.map((entry) => entry.uid).toSet();
  var id = 0;
  while (occupied.contains('$id')) {
    id++;
  }
  return id;
}

Map<String, Object?> _bookEntryUpdates(Map<String, Object?> fields) {
  if (fields.containsKey('id')) {
    throw ArgumentError.value(fields['id'], 'id', 'Entry ids cannot be edited');
  }
  final Map<String, Object?> updates;
  try {
    updates = jsonDecode(jsonEncode(fields)) as Map<String, Object?>;
  } on JsonUnsupportedObjectError {
    throw ArgumentError.value(fields, 'fields', 'Expected JSON entry fields');
  }
  for (final field in updates.entries) {
    final value = field.value;
    if (const {'keys', 'secondary_keys'}.contains(field.key)) {
      if (value is! List<Object?> || value.any((item) => item is! String)) {
        throw ArgumentError.value(value, field.key, 'Expected a list of strings');
      }
    } else if (const {'enabled', 'constant', 'selective', 'use_regex'}.contains(field.key)) {
      if (value is! bool) {
        throw ArgumentError.value(value, field.key, 'Expected a boolean');
      }
    } else if (const {'content', 'comment', 'name', 'position'}.contains(field.key)) {
      if (value is! String) {
        throw ArgumentError.value(value, field.key, 'Expected a string');
      }
    } else if (field.key == 'insertion_order') {
      if (value is! num || !value.isFinite) {
        throw ArgumentError.value(value, field.key, 'Expected a finite number');
      }
    } else if (field.key == 'extensions') {
      if (value is! Map<String, Object?>) {
        throw ArgumentError.value(value, field.key, 'Expected an object');
      }
      _validateBookExtensions(value);
    }
  }
  return updates;
}

void _validateBookExtensions(Map<String, Object?> fields) {
  for (final field in fields.entries) {
    final value = field.value;
    if (const {'selectiveLogic', 'position', 'depth', 'role'}.contains(field.key)) {
      if (value is! num || !value.isFinite || value != value.truncateToDouble()) {
        throw ArgumentError.value(value, 'extensions.${field.key}', 'Expected a finite integer');
      }
    } else if (const {'probability', 'group_weight'}.contains(field.key)) {
      if (value is! num || !value.isFinite) {
        throw ArgumentError.value(value, 'extensions.${field.key}', 'Expected a finite number');
      }
    } else if (const {'useProbability', 'group_override', 'use_group_scoring'}.contains(field.key)) {
      if (value is! bool) {
        throw ArgumentError.value(value, 'extensions.${field.key}', 'Expected a boolean');
      }
    } else if (const {'group', 'outlet_name'}.contains(field.key)) {
      if (value is! String) {
        throw ArgumentError.value(value, 'extensions.${field.key}', 'Expected a string');
      }
    }
  }
}

Map<String, Object?> _mergeBookExtensions(Map<String, Object?> current, Map<String, Object?> updates) => {
  ...current,
  for (final entry in updates.entries)
    entry.key: current[entry.key] is Map<String, Object?> && entry.value is Map<String, Object?>
        ? _mergeBookExtensions(current[entry.key]! as Map<String, Object?>, entry.value! as Map<String, Object?>)
        : entry.value,
};

// Top-level helpers keep an isolate callback from capturing the library's
// operation queue (and its unsendable Futures) through a surrounding closure.
Future<(Map<String, Object?>, Map<String, Object?>)> _decodeAuthoringImport(Uint8List bytes) => Isolate.run(() {
  const codec = CardCodec();
  try {
    return (codec.decodeAuthority(bytes), codec.decode(bytes).json);
  } on FormatException {
    throw const TavernAuthoringException('invalid_change', 'The candidate character envelope is invalid.');
  } on TavernImportError {
    throw const TavernAuthoringException('invalid_change', 'The candidate character envelope is invalid.');
  }
});

Future<Uint8List?> _authoringPortrait(TavernCard card) => Isolate.run(() => const CardCodec().portraitPng(card));

Future<(TavernCard, Uint8List?)> _decodeImport(Uint8List bytes) => Isolate.run(() {
  const codec = CardCodec();
  final card = codec.decode(bytes);
  return (card, codec.portraitPng(card));
});

Future<String> _encodeCardDocument(Map<String, Object?> json) => Isolate.run(() => jsonEncode(json));

Future<Map<String, Object?>> _decodeRuntimeAuthority(Uint8List bytes) =>
    Isolate.run(() => const CardCodec().decodeAuthority(bytes));

Future<TavernCard> _decodeStored(Uint8List bytes) => Isolate.run(() => const CardCodec().decode(bytes));

Future<Uint8List> _encodeCard(TavernCard card, TavernCardFormat format, DateTime modifiedAt) =>
    Isolate.run(() => const CardCodec().encode(card, format: format, modifiedAt: modifiedAt));

String _newId() {
  final random = Random.secure();
  return 'card-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

void _requireId(String id) {
  if (!CharacterLibrary.isValidId(id)) throw ArgumentError.value(id, 'id', 'Invalid character id');
}

String _name(FileSystemEntity entity) => entity.uri.pathSegments.lastWhere((part) => part.isNotEmpty);

Future<void> _discard(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } on FileSystemException {
    // The rename already made deletion final. Retry residual cleanup on the
    // next operation; never restore a character the user deleted.
  }
}

/// Reuses only prepared result metadata. Caller parameters must still pass the
/// authority's ordinary operation-id comparison before any result is decoded.
TavernAuthoringSaveAsReceipt? replayAuthoringSaveAs(
  AuthoringAuthority authority,
  String domainId,
  String operationId,
  Map<String, Object?> parameters,
) {
  final saved = authority.recordedRequest(domainId, operationId);
  if (saved == null) {
    return null;
  }
  final request = AuthoringWriteRequest(
    domainId: domainId,
    operationId: operationId,
    physicalResourceId: saved.physicalResourceId,
    parameters: {...parameters, 'saveAsResult': saved.parameters['saveAsResult']},
  );
  final receipt = authority.replay(request)!;
  return authoringSaveAsReceipt(receipt, saved.parameters['saveAsResult']! as Map<String, Object?>);
}

TavernAuthoringSaveAsReceipt authoringSaveAsReceipt(TavernAuthoringReceipt outcome, Map<String, Object?> result) {
  final character = outcome.physicalResourceId.startsWith('character:');
  return TavernAuthoringSaveAsReceipt(
    outcome: outcome,
    newTarget: TavernAuthoringTarget(
      kind: character ? TavernAuthoringTargetKind.character : TavernAuthoringTargetKind.lorebook,
      id: outcome.physicalResourceId.substring(character ? 10 : 9),
    ),
    copiedMedia: List.unmodifiable((result['copiedMedia']! as List<Object?>).cast<String>()),
    issues: List.unmodifiable([
      for (final item in (result['issues']! as List<Object?>).cast<Map<String, Object?>>())
        TavernAuthoringIssue(type: item['type']! as String, message: item['message']! as String),
    ]),
  );
}
