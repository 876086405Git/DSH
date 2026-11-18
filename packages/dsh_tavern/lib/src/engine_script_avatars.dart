part of 'engine.dart';

// Keep the isolate closure separate from engine/context callbacks.
Future<Uint8List> _scriptAvatarPng(Uint8List bytes) => Isolate.run(() => CardCodec.avatarPng(bytes));

class _ScriptCharacterAvatarView {
  const _ScriptCharacterAvatarView({
    required this.characterId,
    required this.version,
    required this.hasAvatar,
    required this.cardRevision,
  });

  final String characterId;
  final String version;
  final bool hasAvatar;
  final int cardRevision;

  Map<String, Object?> toJson() => {'characterId': characterId, 'version': version, 'hasAvatar': hasAvatar};
}

extension _ScriptCharacterAvatars on _ScriptCoordinator {
  String _scriptAvatarMetadataVersion(String characterId, CharacterAvatarMetadata metadata) => _resourceVersion(
    'characterAvatarMetadata:$characterId',
    {'rawText': metadata.snapshot.rawText, 'identityText': metadata.snapshot.identityText},
    present: metadata.snapshot.present,
  );

  String _scriptAvatarVersion(String characterId, CharacterAvatarCapture captured) {
    final bytes = captured.bytes;
    return _resourceVersion('characterAvatar:$characterId', {
      'rawText': captured.metadata.snapshot.rawText,
      'identityText': captured.metadata.snapshot.identityText,
      'bytesSha256': bytes == null ? null : crypto.sha256.convert(bytes).toString(),
    }, present: captured.metadata.snapshot.present);
  }

  TavernScriptCharacterAvatarSnapshot _scriptAvatarSnapshot(String characterId, CharacterAvatarCapture captured) =>
      TavernScriptCharacterAvatarSnapshot(
        characterId: characterId,
        version: _scriptAvatarVersion(characterId, captured),
        bytes: captured.bytes,
      );

  Future<_ScriptCharacterAvatarView> _scriptCharacterAvatarView(String characterId) =>
      engine._libraryOperation(() async {
        final revision = engine._directors._cardRevisions[characterId] ?? 0;
        final metadata = await engine._library.readRuntimeAvatarMetadata(characterId);
        final cached = scriptResources.avatarViews[metadata];
        if (cached != null && _scriptCharacterAvatarViewCurrent(cached)) return cached;
        return scriptResources.avatarViews[metadata] = _ScriptCharacterAvatarView(
          characterId: characterId,
          version: _scriptAvatarMetadataVersion(characterId, metadata),
          hasAvatar: metadata.hasAvatar,
          cardRevision: revision,
        );
      });

  bool _scriptCharacterAvatarViewCurrent(_ScriptCharacterAvatarView view) {
    final key = 'characterAvatarMetadata:${view.characterId}';
    final observed = scriptResources.observations[key];
    return view.cardRevision == (engine._directors._cardRevisions[view.characterId] ?? 0) &&
        observed != null &&
        view.version == '$epoch:resource:$key:${observed.revision}';
  }

  Future<TavernScriptCharacterAvatarSnapshot> _readScriptCharacterAvatar(String contextId, String characterId) {
    _context(contextId);
    return engine._libraryOperation(() async {
      final captured = await engine._library.readAvatar(characterId);
      _context(contextId);
      if (!captured.metadata.snapshot.present) {
        throw _scriptError(
          TavernScriptErrorCode.notFound,
          'readCharacterAvatar',
          'The character does not exist.',
          contextId: contextId,
        );
      }
      return _scriptAvatarSnapshot(characterId, captured);
    });
  }

  Future<TavernScriptCharacterAvatarSnapshot> _replaceScriptCharacterAvatar(
    String contextId,
    String characterId,
    Uint8List bytes, {
    required String expectedVersion,
  }) async {
    final context = _context(contextId);
    final captured = Uint8List.fromList(bytes);
    void check() {
      if (!identical(_context(contextId), context)) {
        throw _scriptError(
          TavernScriptErrorCode.closedContext,
          'replaceCharacterAvatar',
          'The context instance changed.',
          contextId: contextId,
        );
      }
      if (engine._deletingCharacters.contains(characterId)) {
        throw _scriptError(
          TavernScriptErrorCode.busy,
          'replaceCharacterAvatar',
          'Character deletion is active.',
          contextId: contextId,
        );
      }
    }

    final Uint8List png;
    try {
      png = await _scriptAvatarPng(captured);
    } on FormatException {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'replaceCharacterAvatar',
        'The avatar is not a decodable image.',
        contextId: contextId,
        fieldPath: 'bytes',
      );
    }
    check();
    var adopted = false;
    TavernScriptCharacterAvatarSnapshot? result;
    try {
      await engine._libraryOperation(() async {
        final actual = await engine._library.replaceAvatar(
          characterId,
          png,
          prepare: (current) {
            check();
            if (!current.metadata.snapshot.present) {
              throw _scriptError(
                TavernScriptErrorCode.notFound,
                'replaceCharacterAvatar',
                'The character does not exist.',
                contextId: contextId,
              );
            }
            _resourceExpected(expectedVersion, _scriptAvatarVersion(characterId, current), 'replaceCharacterAvatar');
          },
          check: check,
          onCommitted: (actual) {
            adopted = true;
            _scriptAvatarMetadataVersion(characterId, actual.metadata);
            result = _scriptAvatarSnapshot(characterId, actual);
          },
        );
        result ??= _scriptAvatarSnapshot(characterId, actual);
      });
      await _refreshHelperResourceContexts();
      return result!;
    } catch (error, stack) {
      if (!adopted) {
        rethrow;
      }
      Error.throwWithStackTrace(
        _resourcePartial(error, 'replaceCharacterAvatar', contextId, {
          'targetKind': 'characterAvatar',
          'characterId': characterId,
          'version': ?result?.version,
        }),
        stack,
      );
    }
  }
}
