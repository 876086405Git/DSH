import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:image/image.dart' as image;
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

final _at = DateTime.utc(2026, 11, 14, 15);
const _deadline = Duration(seconds: 30);

void main() {
  test('current avatar follows saved candidates and isolated media while explicit copying stays optional', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final oldPng = _png(1);
    final avatar = _png(3);
    final payload = Uint8List.fromList([0, 2, 127, 254, 255]);
    final raw = _card(oldPng);
    final archive = Archive()
      ..addFile(ArchiveFile.string('card.json', jsonEncode(raw)))
      ..addFile(ArchiveFile('assets/opaque.bin', payload.length, payload));
    final original = Uint8List.fromList(ZipEncoder().encode(archive, modified: _at));
    final character = await h.engine.importCard(original, fileName: 'avatar-source.charx');
    final directory = '${h.root.path}/characters/${character.id}';
    final cardFile = File('$directory/card.json');
    final savedCard = await cardFile.readAsBytes();
    final chat = await h.engine.createChat(character.id);
    final context = await h.context(chat);
    final before = await h.bridge.readCharacterAvatar(context.id, character.id);
    expect(before.bytes, oldPng);
    final adopted = await h.bridge.replaceCharacterAvatar(
      context.id,
      character.id,
      avatar,
      expectedVersion: before.version,
    );
    expect(adopted.bytes, avatar);
    expect(await cardFile.readAsBytes(), savedCard);
    expect(await File('$directory/original.charx').readAsBytes(), original);
    expect(await File('$directory/resources/assets/opaque.bin').readAsBytes(), payload);

    final target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: character.id);
    final captured = await h.engine.createAuthoringDraft([target]);
    final draft = await h.engine.editAuthoringDraft(
      captured.id,
      draftRevision: captured.draftRevision,
      changes: [
        TavernAuthoringChange(
          id: 'candidate',
          physicalResourceId: target.physicalResourceId,
          path: '/data/description',
          operation: TavernAuthoringChangeKind.set,
          value: 'Candidate with the captured avatar.',
        ),
      ],
    );
    final previewTask = h.engine.previewAuthoringPrompt(
      TavernAuthoringPromptRequest(
        requestId: 'avatar-candidate-preview',
        draftId: draft.id,
        draftRevision: draft.draftRevision,
        changeIds: const ['candidate'],
        context: TavernAuthoringChatContext(chatId: chat),
        text: 'Read the candidate.',
        at: _at,
        seed: 41,
      ),
    );
    try {
      final preview = await previewTask.result.timeout(_deadline);
      expect(preview.status, TavernAuthoringPreviewStatus.complete);
      expect(preview.assembly, isNotNull);
      expect(await cardFile.readAsBytes(), savedCard);
    } finally {
      await previewTask.cancel();
    }

    final copied = await h.engine.saveAuthoringAsNew(
      draft.id,
      draftRevision: draft.draftRevision,
      physicalResourceId: target.physicalResourceId,
      changeIds: const ['candidate'],
      operationId: 'avatar-current-source',
      media: TavernAuthoringMediaSelection.currentSource,
    );
    expect(copied.committed, isTrue);
    final copiedId = copied.newTarget!.id;
    expect((await h.engine.character(copiedId))!.description, 'Candidate with the captured avatar.');
    expect((await h.bridge.readCharacterAvatar(context.id, copiedId)).bytes, avatar);
    final copiedRoot = '${h.root.path}/characters/$copiedId';
    expect(await File('$copiedRoot/original.charx').readAsBytes(), original);
    expect(await File('$copiedRoot/resources/assets/opaque.bin').readAsBytes(), payload);

    final withoutMedia = await h.engine.saveAuthoringAsNew(
      draft.id,
      draftRevision: draft.draftRevision,
      physicalResourceId: target.physicalResourceId,
      changeIds: const ['candidate'],
      operationId: 'avatar-no-media',
      media: TavernAuthoringMediaSelection.none,
    );
    expect(withoutMedia.committed, isTrue);
    final noMediaId = withoutMedia.newTarget!.id;
    final noMediaIdentity = scriptMap(
      jsonDecode(await File('${h.root.path}/characters/$noMediaId/library.json').readAsString()),
    );
    expect(noMediaIdentity.containsKey('avatar'), isFalse);
    expect(noMediaIdentity['hasPortrait'], isTrue);
    final legacyCapture = await CharacterLibrary(h.root).readAuthoringCapture(noMediaId);
    expect(legacyCapture.media['portrait.png'], oldPng);
    expect(legacyCapture.character!.card.avatar, isNull);
    expect(
      const CardCodec().decode(await h.engine.exportCard(noMediaId, format: TavernCardFormat.json)).iconBytes,
      oldPng,
      reason: 'The original inline icon remains JSON; none does not copy the selected library avatar.',
    );

    for (final format in TavernCardFormat.values) {
      final ordinaryBytes = await h.engine.exportCard(copiedId, format: format);
      _expectAvatar(ordinaryBytes, avatar, format);
      final request = _exportRequest(character.id, format, copy: true);
      final preview = await h.engine.previewGameplayExport(request);
      expect(preview.issues.where((issue) => issue['blocking'] == true), isEmpty);
      final bytes = await h.engine.exportCharacterWithPacks(request, expectedPreviewId: preview.previewId);
      final decoded = _expectAvatar(bytes, avatar, format);
      if (format == TavernCardFormat.charx) {
        expect(decoded.assets['assets/opaque.bin'], payload);
        expect(const CardCodec().decode(ordinaryBytes).assets['assets/opaque.bin'], payload);
      }
    }
    final noCopyRequest = _exportRequest(character.id, TavernCardFormat.json, copy: false);
    final noCopyPreview = await h.engine.previewGameplayExport(noCopyRequest);
    expect(noCopyPreview.issues.where((issue) => issue['blocking'] == true), isEmpty);
    final noCopyBytes = await h.engine.exportCharacterWithPacks(
      noCopyRequest,
      expectedPreviewId: noCopyPreview.previewId,
    );
    expect(const CardCodec().decode(noCopyBytes).iconBytes, oldPng);
    expect(await cardFile.readAsBytes(), savedCard);
    h.expectNoGeneration();

    final identityBytes = await File('$directory/library.json').readAsBytes();
    final liveIdentity = scriptMap(jsonDecode(utf8.decode(identityBytes)));
    final avatarFile = scriptMap(liveIdentity['avatar'])['file']! as String;
    final livePath = (await h.engine.path(chat)).map((message) => (message.nodeId, message.text)).toList();
    await _withTemp((base) async {
      var inspected = false;
      final response = h.reply('The isolated candidate kept its media.');
      response.beforeResponse = () async {
        final root = base.listSync().whereType<Directory>().single;
        final temporary = '${root.path}/characters/${character.id}';
        expect(await File('$temporary/library.json').readAsBytes(), identityBytes);
        expect(await File('$temporary/$avatarFile').readAsBytes(), avatar);
        expect(await File('$temporary/original.charx').readAsBytes(), original);
        expect(await File('$temporary/resources/assets/opaque.bin').readAsBytes(), payload);
        final candidate = scriptMap(jsonDecode(await File('$temporary/card.json').readAsString()));
        expect(scriptMap(candidate['data'])['description'], 'Candidate with the captured avatar.');
        inspected = true;
      };
      final task = h.engine.simulateAuthoringDraft(
        TavernAuthoringSimulationRequest(
          requestId: 'avatar-isolated-simulation',
          draftId: draft.id,
          draftRevision: draft.draftRevision,
          changeIds: const ['candidate'],
          context: TavernAuthoringSampleContext(characterResourceId: target.physicalResourceId),
          userInputs: const ['Read the captured candidate.'],
          at: _at,
          seed: 31,
        ),
      );
      try {
        final result = await task.result.timeout(_deadline);
        expect(result.status, TavernAuthoringSimulationStatus.completed);
        expect(result.cleanup, {'rootCreated': true, 'closeConfirmed': true, 'removed': true});
        expect(inspected, isTrue);
        expect(base.listSync(), isEmpty);
      } finally {
        await task.cancel();
      }
    });
    expect(h.requests, hasLength(1));
    expect(await cardFile.readAsBytes(), savedCard);
    expect(await File('$directory/library.json').readAsBytes(), identityBytes);
    expect((await h.engine.path(chat)).map((message) => (message.nodeId, message.text)).toList(), livePath);

    final staleRequest = _exportRequest(character.id, TavernCardFormat.json, copy: true);
    final stalePreview = await h.engine.previewGameplayExport(staleRequest);
    final current = await h.bridge.readCharacterAvatar(context.id, character.id);
    await h.bridge.replaceCharacterAvatar(context.id, character.id, _png(2), expectedVersion: current.version);
    await expectLater(
      h.engine.exportCharacterWithPacks(staleRequest, expectedPreviewId: stalePreview.previewId),
      throwsA(isA<TavernGameplayException>().having((error) => error.code, 'code', 'export_preview_conflict')),
    );
    await expectLater(
      h.engine.saveAuthoringAsNew(
        draft.id,
        draftRevision: draft.draftRevision,
        physicalResourceId: target.physicalResourceId,
        changeIds: const ['candidate'],
        operationId: 'avatar-stale-current-source',
        media: TavernAuthoringMediaSelection.currentSource,
      ),
      throwsA(isA<TavernAuthoringException>().having((error) => error.code, 'code', 'authority_conflict')),
    );
    expect((await h.bridge.readCharacterAvatar(context.id, copiedId)).bytes, avatar);

    final invalidAssets = <String, Object?>{
      ...scriptMap(scriptMap(jsonDecode(utf8.decode(savedCard)))['data']),
      'assets': 42,
    };
    await h.bridge.replaceCharacterData(context.id, character.id, invalidAssets);
    final blocked = await h.engine.previewGameplayExport(staleRequest);
    expect(scriptMap(blocked.mergedRaw['data'])['assets'], 42);
    expect(
      blocked.issues.any(
        (issue) =>
            issue['code'] == 'export_avatar_assets_shape' &&
            issue['path'] == '/data/assets' &&
            issue['blocking'] == true,
      ),
      isTrue,
    );
    await expectLater(
      h.engine.exportCharacterWithPacks(staleRequest, expectedPreviewId: blocked.previewId),
      throwsA(isA<TavernGameplayException>().having((error) => error.code, 'code', 'export_conflict')),
    );
  });
}

Uint8List _png(int width) => Uint8List.fromList(image.encodePng(image.Image(width: width, height: 1, numChannels: 4)));

Map<String, Object?> _card(Uint8List icon) => {
  'spec': 'chara_card_v3',
  'spec_version': '3.0',
  'vendor': {
    'keep': [1, null],
  },
  'data': <String, Object?>{
    'name': 'Avatar media',
    'description': 'Stored original.',
    'personality': '',
    'scenario': '',
    'first_mes': 'Hello.',
    'mes_example': '',
    'creator_notes': '',
    'system_prompt': '',
    'post_history_instructions': '',
    'alternate_greetings': <String>[],
    'tags': <String>[],
    'creator': '',
    'character_version': '',
    'extensions': <String, Object?>{},
    'assets': [
      {
        'type': 'icon',
        'name': 'main',
        'ext': 'png',
        'uri': Uri.dataFromBytes(icon, mimeType: 'image/png').toString(),
        'vendor': {
          'retain': [null, 'main'],
        },
      },
      {'type': 'other', 'name': 'remote', 'ext': 'bin', 'uri': 'https://avatar.invalid/opaque', 'vendor': true},
    ],
  },
};

TavernGameplayExportRequest _exportRequest(String characterId, TavernCardFormat format, {required bool copy}) =>
    TavernGameplayExportRequest.character(
      context: TavernGameplayContext(characterId: characterId),
      format: format,
      at: _at,
      packResources: const [],
      copyCardMedia: copy,
    );

TavernCard _expectAvatar(Uint8List bytes, Uint8List avatar, TavernCardFormat format) {
  final decoded = const CardCodec().decode(bytes);
  expect(decoded.iconBytes, avatar);
  final assets = (decoded.data['assets']! as List<Object?>).map(scriptMap).toList();
  final main = assets.singleWhere((asset) => asset['type'] == 'icon' && asset['name'] == 'main');
  expect(main['ext'], 'png');
  expect(main['vendor'], {
    'retain': [null, 'main'],
  });
  expect(UriData.parse(main['uri']! as String).contentAsBytes(), avatar);
  expect(assets.singleWhere((asset) => asset['name'] == 'remote'), {
    'type': 'other',
    'name': 'remote',
    'ext': 'bin',
    'uri': 'https://avatar.invalid/opaque',
    'vendor': true,
  });
  expect(decoded.json['vendor'], {
    'keep': [1, null],
  });
  if (format == TavernCardFormat.png) {
    expect(image.decodeImage(bytes)!.width, 3, reason: 'The PNG cover also uses the selected avatar.');
  }
  return decoded;
}

Future<void> _withTemp(Future<void> Function(Directory) body) async {
  final base = await Directory.systemTemp.createTemp('dsh-avatar-simulation-test-');
  try {
    await IOOverrides.runZoned(() => body(base), getSystemTempDirectory: () => base);
  } finally {
    if (await base.exists()) {
      await base.delete(recursive: true);
    }
  }
}
